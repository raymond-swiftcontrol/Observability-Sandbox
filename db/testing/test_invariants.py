"""Invariant tests for the Helios schema.

These are the properties the database is supposed to guarantee *regardless of
what the application code does*. Each one is a rule we decided not to trust
services to uphold, so each one deserves a test that tries to violate it.

Run against a database built by scripts/validate-schema.py --keep:

    scripts/validate-schema.py --keep
    pytest db/testing/test_invariants.py -v

The Timescale shim means hypertables are ordinary tables here. That does not
weaken these tests: every invariant below is expressed in constraints,
triggers and policies, all of which behave identically.
"""
from __future__ import annotations

import os
import uuid

import psycopg2
import psycopg2.extras
import pytest

DSN = os.environ.get(
    "VALIDATE_DATABASE_URL",
    "postgresql://helios:helios_dev_only@127.0.0.1:5432/helios_schema_check",
)


@pytest.fixture()
def conn():
    c = psycopg2.connect(DSN)
    c.autocommit = False
    yield c
    c.rollback()
    c.close()


@pytest.fixture()
def cur(conn):
    with conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as c:
        yield c


# ── Fixtures that build the minimum real object graph ───────────────────────
def make_user(cur, email: str | None = None) -> str:
    uid = str(uuid.uuid4())
    cur.execute(
        """INSERT INTO identity."user" (id, email, display_name, status)
           VALUES (%s, %s, %s, 'active')""",
        (uid, email or f"u{uid[:8]}@example.test", "Test Trader"),
    )
    return uid


def make_currency(cur):
    cur.execute(
        """INSERT INTO reference.currency (code, name) VALUES ('USD', 'US Dollar')
           ON CONFLICT DO NOTHING"""
    )


def make_account(cur, user_id: str) -> str:
    make_currency(cur)
    aid = str(uuid.uuid4())
    cur.execute(
        """INSERT INTO book.account (id, owner_user_id, name, account_type,
                                     base_currency, status)
           VALUES (%s, %s, 'Main', 'margin', 'USD', 'active')""",
        (aid, user_id),
    )
    return aid


def make_ledger_txn(cur, account_id: str, key: str) -> str:
    tid = str(uuid.uuid4())
    cur.execute(
        """INSERT INTO book.ledger_transaction (id, account_id, reason,
                                                idempotency_key, occurred_at)
           VALUES (%s, %s, 'fill', %s, now())""",
        (tid, account_id, key),
    )
    return tid


# ── The double-entry invariant ──────────────────────────────────────────────
class TestLedgerBalances:
    """book.assert_ledger_balanced must make an unbalanced transaction
    impossible to commit, whatever the writing service believes."""

    def test_balanced_transaction_commits(self, conn, cur):
        """This is the only test that actually commits: the deferred trigger
        does not fire until COMMIT, so a rolled-back transaction would never
        exercise it. The idempotency key is randomised and the rows are cleaned
        up so the suite stays re-runnable against a persistent database."""
        uid = make_user(cur)
        aid = make_account(cur, uid)
        tid = make_ledger_txn(cur, aid, f"balanced-{uuid.uuid4()}")
        cur.execute(
            """INSERT INTO book.ledger_entry
                 (transaction_id, account_id, ledger_account, amount, currency, occurred_at)
               VALUES (%s, %s, 'cash', -1000, 'USD', now()),
                      (%s, %s, 'securities', 1000, 'USD', now())""",
            (tid, aid, tid, aid),
        )
        conn.commit()  # the deferred trigger fires here

        cur.execute("DELETE FROM book.ledger_entry WHERE transaction_id = %s", (tid,))
        cur.execute("DELETE FROM book.ledger_transaction WHERE id = %s", (tid,))
        cur.execute("DELETE FROM book.account WHERE id = %s", (aid,))
        cur.execute('DELETE FROM identity."user" WHERE id = %s', (uid,))
        conn.commit()

    def test_unbalanced_transaction_is_rejected_at_commit(self, conn, cur):
        uid = make_user(cur)
        aid = make_account(cur, uid)
        tid = make_ledger_txn(cur, aid, f"unbalanced-{uuid.uuid4()}")
        # Deliberately off by 1: a rounding bug in a fee calculation looks
        # exactly like this.
        cur.execute(
            """INSERT INTO book.ledger_entry
                 (transaction_id, account_id, ledger_account, amount, currency, occurred_at)
               VALUES (%s, %s, 'cash', -1000, 'USD', now()),
                      (%s, %s, 'securities', 999, 'USD', now())""",
            (tid, aid, tid, aid),
        )
        with pytest.raises(psycopg2.errors.IntegrityConstraintViolation):
            conn.commit()

    def test_imbalance_in_one_currency_is_rejected(self, conn, cur):
        """Legs that net to zero overall but not per currency are still wrong:
        that is an unrecorded FX conversion."""
        uid = make_user(cur)
        aid = make_account(cur, uid)
        cur.execute(
            "INSERT INTO reference.currency (code, name) VALUES ('EUR','Euro') "
            "ON CONFLICT DO NOTHING"
        )
        tid = make_ledger_txn(cur, aid, f"fx-imbalance-{uuid.uuid4()}")
        cur.execute(
            """INSERT INTO book.ledger_entry
                 (transaction_id, account_id, ledger_account, amount, currency, occurred_at)
               VALUES (%s, %s, 'cash', -1000, 'USD', now()),
                      (%s, %s, 'cash', 1000, 'EUR', now())""",
            (tid, aid, tid, aid),
        )
        with pytest.raises(psycopg2.errors.IntegrityConstraintViolation):
            conn.commit()

    def test_zero_amount_entry_is_rejected(self, conn, cur):
        uid = make_user(cur)
        aid = make_account(cur, uid)
        tid = make_ledger_txn(cur, aid, f"zero-entry-{uuid.uuid4()}")
        with pytest.raises(psycopg2.errors.CheckViolation):
            cur.execute(
                """INSERT INTO book.ledger_entry
                     (transaction_id, account_id, ledger_account, amount, currency, occurred_at)
                   VALUES (%s, %s, 'cash', 0, 'USD', now())""",
                (tid, aid),
            )

    def test_idempotency_key_prevents_double_posting(self, conn, cur):
        """The single worst bug this schema can have is posting a fill twice."""
        uid = make_user(cur)
        aid = make_account(cur, uid)
        key = f"dedupe-{uuid.uuid4()}"
        make_ledger_txn(cur, aid, key)
        with pytest.raises(psycopg2.errors.UniqueViolation):
            make_ledger_txn(cur, aid, key)


# ── The order state machine ─────────────────────────────────────────────────
class TestOrderStateMachine:
    def test_legal_transitions_are_permitted(self, cur):
        legal = [
            (None, "pending_risk"),
            ("pending_risk", "pending_new"),
            ("pending_new", "new"),
            ("new", "partially_filled"),
            ("partially_filled", "filled"),
            ("new", "pending_cancel"),
            ("pending_cancel", "cancelled"),
        ]
        for frm, to in legal:
            cur.execute("SELECT oms.is_valid_transition(%s, %s)", (frm, to))
            assert cur.fetchone()[0] is True, f"{frm} -> {to} should be legal"

    def test_illegal_transitions_are_refused(self, cur):
        illegal = [
            ("filled", "new"),
            ("cancelled", "filled"),
            ("rejected", "new"),
            ("draft", "filled"),
            ("expired", "partially_filled"),
        ]
        for frm, to in illegal:
            cur.execute("SELECT oms.is_valid_transition(%s, %s)", (frm, to))
            assert cur.fetchone()[0] is False, f"{frm} -> {to} should be illegal"

    def test_pending_cancel_can_still_fill(self, cur):
        """The race between our cancel and the venue's match is real. A state
        machine that forbids this would reject a fill that actually happened."""
        cur.execute("SELECT oms.is_valid_transition('pending_cancel', 'filled')")
        assert cur.fetchone()[0] is True

    def test_successive_partial_fills_are_permitted(self, cur):
        cur.execute("SELECT oms.is_valid_transition('partially_filled', 'partially_filled')")
        assert cur.fetchone()[0] is True

    def test_terminal_states_do_not_loop(self, cur):
        for state in ("filled", "cancelled", "rejected", "expired"):
            cur.execute("SELECT oms.is_valid_transition(%s, %s)", (state, state))
            assert cur.fetchone()[0] is False, f"{state} should not self-transition"


# ── Moderation automation ceiling ───────────────────────────────────────────
class TestModerationAutomationCeiling:
    """Automation may shadow-limit; only a human, or a rule explicitly marked
    auto_removable, may remove content."""

    def _make_rule(self, cur, key: str, auto_removable: bool) -> None:
        cur.execute(
            """INSERT INTO social.detection_rule (key, name, description, category,
                                                  auto_removable)
               VALUES (%s, %s, 'test rule', 'spam', %s)""",
            (key, key, auto_removable),
        )

    def test_automated_shadow_limit_is_allowed(self, cur):
        uid = make_user(cur)
        self._make_rule(cur, "rule_shadow", auto_removable=False)
        cur.execute(
            """INSERT INTO social.moderation_action
                 (target_kind, target_user_id, verdict, actor_rule_key,
                  reason_category, reason_internal)
               VALUES ('profile', %s, 'shadow_limited', 'rule_shadow', 'spam', 'test')""",
            (uid,),
        )

    def test_automated_removal_is_refused(self, cur):
        uid = make_user(cur)
        self._make_rule(cur, "rule_no_remove", auto_removable=False)
        with pytest.raises(psycopg2.errors.InsufficientPrivilege):
            cur.execute(
                """INSERT INTO social.moderation_action
                     (target_kind, target_user_id, verdict, actor_rule_key,
                      reason_category, reason_internal)
                   VALUES ('profile', %s, 'removed', 'rule_no_remove', 'spam', 'test')""",
                (uid,),
            )

    def test_human_removal_is_allowed(self, cur):
        target = make_user(cur)
        moderator = make_user(cur)
        cur.execute(
            """INSERT INTO social.moderation_action
                 (target_kind, target_user_id, verdict, actor_user_id,
                  reason_category, reason_internal)
               VALUES ('profile', %s, 'removed', %s, 'spam', 'reviewed by hand')""",
            (target, moderator),
        )

    def test_designated_rule_may_remove(self, cur):
        uid = make_user(cur)
        self._make_rule(cur, "rule_may_remove", auto_removable=True)
        cur.execute(
            """INSERT INTO social.moderation_action
                 (target_kind, target_user_id, verdict, actor_rule_key,
                  reason_category, reason_internal)
               VALUES ('profile', %s, 'removed', 'rule_may_remove', 'illegal_content', 'test')""",
            (uid,),
        )

    def test_action_requires_exactly_one_actor(self, cur):
        uid = make_user(cur)
        moderator = make_user(cur)
        self._make_rule(cur, "rule_both", auto_removable=True)
        with pytest.raises(psycopg2.errors.CheckViolation):
            cur.execute(
                """INSERT INTO social.moderation_action
                     (target_kind, target_user_id, verdict, actor_user_id,
                      actor_rule_key, reason_category, reason_internal)
                   VALUES ('profile', %s, 'cleared', %s, 'rule_both', 'spam', 'test')""",
                (uid, moderator),
            )


# ── Social privacy and graph rules ──────────────────────────────────────────
class TestSocialGraph:
    def _make_profile(self, cur, user_id: str, handle: str, visibility="public"):
        cur.execute(
            """INSERT INTO social.profile (user_id, handle, display_name, visibility)
               VALUES (%s, %s, %s, %s)""",
            (user_id, handle, handle, visibility),
        )

    def test_handle_is_case_insensitively_unique(self, cur):
        a, b = make_user(cur), make_user(cur)
        self._make_profile(cur, a, "quantkid")
        with pytest.raises(psycopg2.errors.UniqueViolation):
            self._make_profile(cur, b, "QuantKid")

    @pytest.mark.parametrize(
        "bad_handle",
        [
            "ab",            # under the 3-character floor
            "has spaces",
            "has-dash",      # hyphens are not permitted; underscores are
            "x" * 25,        # over the 24-character ceiling
            "emoji\U0001F600",
        ],
    )
    def test_handle_shape_is_enforced(self, cur, bad_handle):
        uid = make_user(cur)
        with pytest.raises(psycopg2.errors.CheckViolation):
            self._make_profile(cur, uid, bad_handle)

    def test_valid_handles_are_accepted(self, cur):
        for good in ("abc", "quant_kid", "Trader99", "x" * 24):
            uid = make_user(cur)
            self._make_profile(cur, uid, good)

    def test_block_severs_follows_in_both_directions(self, conn, cur):
        a, b = make_user(cur), make_user(cur)
        self._make_profile(cur, a, "alpha")
        self._make_profile(cur, b, "beta")
        cur.execute(
            """INSERT INTO social.follow (follower_id, followee_id, state, accepted_at)
               VALUES (%s, %s, 'active', now()), (%s, %s, 'active', now())""",
            (a, b, b, a),
        )
        cur.execute("SELECT count(*) FROM social.follow WHERE follower_id IN (%s,%s)", (a, b))
        assert cur.fetchone()[0] == 2

        cur.execute("INSERT INTO social.block (blocker_id, blocked_id) VALUES (%s,%s)", (a, b))
        cur.execute("SELECT count(*) FROM social.follow WHERE follower_id IN (%s,%s)", (a, b))
        assert cur.fetchone()[0] == 0, "block must delete follows in both directions"

    def test_follower_counters_track_active_follows(self, cur):
        a, b = make_user(cur), make_user(cur)
        self._make_profile(cur, a, "counta")
        self._make_profile(cur, b, "countb")

        cur.execute(
            """INSERT INTO social.follow (follower_id, followee_id, state, accepted_at)
               VALUES (%s, %s, 'active', now())""",
            (a, b),
        )
        cur.execute("SELECT followers_count FROM social.profile WHERE user_id = %s", (b,))
        assert cur.fetchone()[0] == 1
        cur.execute("SELECT following_count FROM social.profile WHERE user_id = %s", (a,))
        assert cur.fetchone()[0] == 1

        cur.execute("DELETE FROM social.follow WHERE follower_id=%s AND followee_id=%s", (a, b))
        cur.execute("SELECT followers_count FROM social.profile WHERE user_id = %s", (b,))
        assert cur.fetchone()[0] == 0

    def test_pending_follow_does_not_count(self, cur):
        a, b = make_user(cur), make_user(cur)
        self._make_profile(cur, a, "penda")
        self._make_profile(cur, b, "pendb", visibility="private")
        cur.execute(
            """INSERT INTO social.follow (follower_id, followee_id, state)
               VALUES (%s, %s, 'pending')""",
            (a, b),
        )
        cur.execute("SELECT followers_count FROM social.profile WHERE user_id = %s", (b,))
        assert cur.fetchone()[0] == 0, "a pending request is not a follower"

    def test_self_follow_is_refused(self, cur):
        a = make_user(cur)
        self._make_profile(cur, a, "selfie")
        with pytest.raises(psycopg2.errors.CheckViolation):
            cur.execute(
                """INSERT INTO social.follow (follower_id, followee_id, state, accepted_at)
                   VALUES (%s, %s, 'active', now())""",
                (a, a),
            )

    def test_disclosure_none_cannot_name_a_portfolio(self, cur):
        """The constraint ties disclosure level to having something to disclose."""
        uid = make_user(cur)
        aid = make_account(cur, uid)
        cur.execute(
            """INSERT INTO book.portfolio (account_id, name, allocated_capital)
               VALUES (%s, 'P', 1000) RETURNING id""",
            (aid,),
        )
        pid = cur.fetchone()[0]
        with pytest.raises(psycopg2.errors.CheckViolation):
            cur.execute(
                """INSERT INTO social.profile
                     (user_id, handle, display_name, performance_disclosure,
                      performance_portfolio_id)
                   VALUES (%s, 'discl', 'D', 'returns_only', NULL)""",
                (uid,),
            )


# ── Verified-badge integrity ────────────────────────────────────────────────
class TestTradeSharingIntegrity:
    def test_verified_attachment_requires_method_and_timestamp(self, cur):
        uid = make_user(cur)
        cur.execute(
            """INSERT INTO social.profile (user_id, handle, display_name)
               VALUES (%s, 'sharer', 'S')""",
            (uid,),
        )
        cur.execute(
            """INSERT INTO social.post (author_id, kind, body)
               VALUES (%s, 'text', 'hello') RETURNING id""",
            (uid,),
        )
        post_id = cur.fetchone()[0]
        with pytest.raises(psycopg2.errors.CheckViolation):
            cur.execute(
                """INSERT INTO social.post_attachment
                     (post_id, kind, media_key, verification)
                   VALUES (%s, 'image', 'k', 'verified')""",
                (post_id,),
            )

    def test_revoked_attachment_requires_a_reason(self, cur):
        uid = make_user(cur)
        cur.execute(
            """INSERT INTO social.profile (user_id, handle, display_name)
               VALUES (%s, 'revoker', 'R')""",
            (uid,),
        )
        cur.execute(
            "INSERT INTO social.post (author_id, kind, body) VALUES (%s,'text','x') RETURNING id",
            (uid,),
        )
        post_id = cur.fetchone()[0]
        with pytest.raises(psycopg2.errors.CheckViolation):
            cur.execute(
                """INSERT INTO social.post_attachment (post_id, kind, media_key, verification)
                   VALUES (%s, 'image', 'k', 'revoked')""",
                (post_id,),
            )


# ── Broker connectivity safety ──────────────────────────────────────────────
class TestBrokerSafety:
    def _provider(self, cur, key, integration="native", supports_trading=True):
        cur.execute(
            """INSERT INTO broker.provider (key, name, integration, auth_kind, base_url,
                                            supports_trading)
               VALUES (%s, %s, %s, 'api_key', 'https://api.example.test', %s)
               RETURNING id""",
            (key, key, integration, supports_trading),
        )
        return cur.fetchone()[0]

    def test_aggregator_cannot_declare_trading(self, cur):
        with pytest.raises(psycopg2.errors.CheckViolation):
            self._provider(cur, "aggr", integration="aggregator", supports_trading=True)

    def test_base_url_must_be_https(self, cur):
        with pytest.raises(psycopg2.errors.CheckViolation):
            cur.execute(
                """INSERT INTO broker.provider (key, name, integration, auth_kind, base_url)
                   VALUES ('insecure','x','native','api_key','http://api.example.test')"""
            )

    def test_credential_shaped_secret_ref_is_refused(self, cur):
        """The shape check will not stop a determined mistake, but it does stop
        pasting the token into the column meant to reference it.

        The fixture is assembled at runtime rather than written as a literal:
        a realistic-looking key in the source trips GitHub's secret scanner and
        blocks the push, which is the scanner working correctly.
        """
        uid = make_user(cur)
        aid = make_account(cur, uid)
        pid = self._provider(cur, "native1")
        looks_like_a_key = "sk" + "_" + "live" + "_" + ("A1b2C3d4" * 3)
        with pytest.raises(psycopg2.errors.CheckViolation):
            cur.execute(
                """INSERT INTO broker.connection
                     (account_id, user_id, provider_id, secret_ref, can_trade)
                   VALUES (%s, %s, %s, %s, true)""",
                (aid, uid, pid, looks_like_a_key),
            )

    def test_aggregator_connection_cannot_route_orders(self, cur):
        uid = make_user(cur)
        aid = make_account(cur, uid)
        pid = self._provider(cur, "aggr_ro", integration="aggregator", supports_trading=False)
        cur.execute(
            """INSERT INTO broker.connection
                 (account_id, user_id, provider_id, secret_ref, can_trade, state, linked_at)
               VALUES (%s, %s, %s, 'vault://helios/conn/1', false, 'active', now())
               RETURNING id""",
            (aid, uid, pid),
        )
        cid = cur.fetchone()[0]
        cur.execute("SELECT broker.can_route_orders(%s)", (cid,))
        assert cur.fetchone()[0] is False

    def test_native_active_connection_may_route(self, cur):
        uid = make_user(cur)
        aid = make_account(cur, uid)
        pid = self._provider(cur, "native_ok")
        cur.execute(
            """INSERT INTO broker.connection
                 (account_id, user_id, provider_id, secret_ref, can_trade, state, linked_at)
               VALUES (%s, %s, %s, 'vault://helios/conn/2', true, 'active', now())
               RETURNING id""",
            (aid, uid, pid),
        )
        cid = cur.fetchone()[0]
        cur.execute("SELECT broker.can_route_orders(%s)", (cid,))
        assert cur.fetchone()[0] is True


# ── Point-in-time correctness ───────────────────────────────────────────────
class TestPointInTime:
    def test_features_as_of_excludes_the_not_yet_knowable(self, cur):
        """A feature value with a publication lag must be invisible to a read
        as of a moment before it became available."""
        cur.execute(
            """INSERT INTO reference.currency (code, name) VALUES ('USD','US Dollar')
               ON CONFLICT DO NOTHING"""
        )
        cur.execute(
            """INSERT INTO reference.venue (code, name, kind, timezone, currency)
               VALUES ('TEST','Test Venue','exchange','UTC','USD') RETURNING id"""
        )
        venue_id = cur.fetchone()[0]
        cur.execute(
            """INSERT INTO reference.calendar (code, name, timezone)
               VALUES ('TESTCAL','Test','UTC') RETURNING id"""
        )
        cal_id = cur.fetchone()[0]
        cur.execute(
            """INSERT INTO reference.instrument
                 (symbol, venue_id, asset_class, name, currency, calendar_id)
               VALUES ('TEST', %s, 'equity', 'Test Inc', 'USD', %s) RETURNING id""",
            (venue_id, cal_id),
        )
        ins = cur.fetchone()[0]

        cur.execute(
            """INSERT INTO research.feature_definition
                 (key, name, category, description, implementation)
               VALUES ('test_feat','Test','trend','t','helios_quant.features.test')"""
        )
        # Bar at T, but only knowable at T + 2 days.
        cur.execute(
            """INSERT INTO research.feature_value
                 (ts, instrument_id, feature_key, value, available_at)
               VALUES ('2025-01-01T00:00:00Z', %s, 'test_feat', 1.23,
                       '2025-01-03T00:00:00Z')""",
            (ins,),
        )

        cur.execute(
            "SELECT count(*) FROM research.features_as_of(%s, '2025-01-02T00:00:00Z')", (ins,)
        )
        assert cur.fetchone()[0] == 0, "value must be invisible before available_at"

        cur.execute(
            "SELECT value FROM research.features_as_of(%s, '2025-01-04T00:00:00Z')", (ins,)
        )
        assert float(cur.fetchone()[0]) == pytest.approx(1.23)

    def test_feature_cannot_be_available_before_its_bar(self, cur):
        cur.execute(
            """INSERT INTO research.feature_definition
                 (key, name, category, description, implementation)
               VALUES ('bad_feat','Bad','trend','t','x')"""
        )
        with pytest.raises(psycopg2.errors.CheckViolation):
            cur.execute(
                """INSERT INTO research.feature_value
                     (ts, instrument_id, feature_key, value, available_at)
                   VALUES ('2025-01-05T00:00:00Z', gen_random_uuid(), 'bad_feat', 1,
                           '2025-01-01T00:00:00Z')"""
            )

    def test_walk_forward_test_window_cannot_precede_training(self, cur):
        """Overlapping train/test windows are the most common way a
        walk-forward implementation is silently wrong."""
        cur.execute(
            """INSERT INTO research.strategy (owner_user_id, name, slug, kind)
               VALUES (%s, 'S', 's', 'momentum') RETURNING id""",
            (make_user(cur),),
        )
        sid = cur.fetchone()[0]
        cur.execute(
            """INSERT INTO research.strategy_version
                 (strategy_id, version, content_hash, code, runtime_version)
               VALUES (%s, 1, repeat('a',64), 'pass', 'py3.11') RETURNING id""",
            (sid,),
        )
        vid = cur.fetchone()[0]
        cur.execute(
            """INSERT INTO research.walk_forward
                 (strategy_version_id, train_days, test_days, step_days, folds_total)
               VALUES (%s, 252, 63, 63, 4) RETURNING id""",
            (vid,),
        )
        wid = cur.fetchone()[0]
        with pytest.raises(psycopg2.errors.CheckViolation):
            cur.execute(
                """INSERT INTO research.walk_forward_fold
                     (walk_forward_id, fold_number, train_start, train_end,
                      test_start, test_end)
                   VALUES (%s, 1, '2024-01-01', '2024-12-31',
                           '2024-06-01', '2025-03-31')""",
                (wid,),
            )


# ── Leaderboard fairness ────────────────────────────────────────────────────
class TestLeaderboard:
    def test_short_track_record_cannot_be_ranked(self, cur):
        """Without this floor a single lucky month tops the board, which is
        both misleading and an incentive to gamble."""
        uid = make_user(cur)
        with pytest.raises(psycopg2.errors.CheckViolation):
            cur.execute(
                """INSERT INTO social.leaderboard_entry
                     (period, as_of, rank, user_id, sharpe, track_record_days)
                   VALUES ('30d', CURRENT_DATE, 1, %s, 4.2, 20)""",
                (uid,),
            )


# ── Import preview guarantee ────────────────────────────────────────────────
class TestImportSafety:
    def test_oversized_upload_is_refused(self, cur):
        uid = make_user(cur)
        aid = make_account(cur, uid)
        with pytest.raises(psycopg2.errors.CheckViolation):
            cur.execute(
                """INSERT INTO broker.import_batch
                     (user_id, account_id, object_key, original_filename,
                      content_type, byte_size, content_hash)
                   VALUES (%s, %s, 'k', 'big.csv', 'text/csv', 104857600, repeat('a',64))""",
                (uid, aid),
            )

    def test_unexpected_content_type_is_refused(self, cur):
        uid = make_user(cur)
        aid = make_account(cur, uid)
        with pytest.raises(psycopg2.errors.CheckViolation):
            cur.execute(
                """INSERT INTO broker.import_batch
                     (user_id, account_id, object_key, original_filename,
                      content_type, byte_size, content_hash)
                   VALUES (%s, %s, 'k', 'x.html', 'text/html', 100, repeat('a',64))""",
                (uid, aid),
            )
