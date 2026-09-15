-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ 0021 · Posts, cashtags, attachments, engagement                           ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- Implements the trade-sharing and feed specs. The load-bearing decision here
-- is that a trade attachment's verification verdict is RESOLVED AT ATTACH TIME
-- AND STORED. Recomputing it on read would make read latency depend on broker
-- availability and would let history change under the reader — a post that was
-- verified yesterday must not quietly become unverified because a sync is down.

CREATE TYPE social.post_kind AS ENUM (
  'text', 'trade', 'portfolio', 'backtest', 'watchlist', 'repost'
);

CREATE TYPE social.attachment_kind AS ENUM (
  'fill', 'position', 'portfolio_snapshot', 'backtest', 'watchlist', 'image', 'chart'
);

CREATE TYPE social.verification AS ENUM (
  'verified',      -- backed by a Helios-routed order or a healthy broker sync
  'unverified',    -- manually entered, or verification timed out
  'revoked'        -- later broker data contradicted the claim
);

CREATE TYPE social.moderation_state AS ENUM (
  'ok', 'pending_review', 'shadow_limited', 'removed'
);

CREATE TYPE social.reaction_kind AS ENUM (
  'like', 'insightful', 'agree', 'disagree', 'curious'
);

-- ── Posts ───────────────────────────────────────────────────────────────────
CREATE TABLE social.post (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id       text UNIQUE NOT NULL DEFAULT platform.public_id('pst'),
  author_id       uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  kind            social.post_kind NOT NULL DEFAULT 'text',
  body            varchar(2000),
  -- Threading is one level deep by design: deep trees are a moderation and
  -- ranking problem out of proportion to their value here.
  parent_post_id  uuid REFERENCES social.post(id) ON DELETE CASCADE,
  root_post_id    uuid REFERENCES social.post(id) ON DELETE CASCADE,
  repost_of_id    uuid REFERENCES social.post(id) ON DELETE SET NULL,
  group_id        uuid,
  visibility      social.visibility NOT NULL DEFAULT 'public',

  -- Disclosure opt-in for THIS post. Even a full-disclosure profile withholds
  -- notionals unless the post asks for it, per the spec.
  reveal_notional boolean NOT NULL DEFAULT false,
  -- Written rationale beyond the attached artefact is rewarded by ranking, so
  -- it is measured rather than inferred from body length at query time.
  rationale_chars integer NOT NULL DEFAULT 0,

  language        char(2),
  moderation_state social.moderation_state NOT NULL DEFAULT 'ok',
  moderation_reason varchar(48),

  -- Denormalised engagement counters, maintained by trigger. Ranking reads
  -- these on every candidate post; a COUNT(*) per candidate is not viable.
  reply_count     integer NOT NULL DEFAULT 0,
  repost_count    integer NOT NULL DEFAULT 0,
  reaction_count  integer NOT NULL DEFAULT 0,
  bookmark_count  integer NOT NULL DEFAULT 0,
  view_count      integer NOT NULL DEFAULT 0,
  report_count    integer NOT NULL DEFAULT 0,

  -- Ranking inputs cached at write time; refreshed by the stats job.
  ranking_score   double precision NOT NULL DEFAULT 0,

  edited_at       timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz,

  CONSTRAINT post_body_or_attachment
    CHECK (kind <> 'text' OR (body IS NOT NULL AND length(btrim(body)) > 0)),
  CONSTRAINT post_repost_has_target
    CHECK ((kind = 'repost') = (repost_of_id IS NOT NULL)),
  CONSTRAINT post_reply_has_root
    CHECK (parent_post_id IS NULL OR root_post_id IS NOT NULL),
  CONSTRAINT post_no_self_parent CHECK (parent_post_id IS DISTINCT FROM id),
  CONSTRAINT post_counters_nonneg CHECK (
    reply_count >= 0 AND repost_count >= 0 AND reaction_count >= 0
    AND bookmark_count >= 0 AND report_count >= 0
  )
);

-- Author timeline: the profile page and the read-time merge path for
-- high-follower authors both scan this.
CREATE INDEX post_author_time_idx ON social.post (author_id, created_at DESC)
  WHERE deleted_at IS NULL AND parent_post_id IS NULL;
-- Reply thread fetch.
CREATE INDEX post_thread_idx ON social.post (root_post_id, created_at)
  WHERE deleted_at IS NULL AND parent_post_id IS NOT NULL;
CREATE INDEX post_group_idx ON social.post (group_id, created_at DESC)
  WHERE group_id IS NOT NULL AND deleted_at IS NULL;
-- Feed candidate scan, and the moderation queue.
CREATE INDEX post_ranking_idx ON social.post (created_at DESC, ranking_score DESC)
  WHERE deleted_at IS NULL AND moderation_state = 'ok' AND visibility = 'public';
CREATE INDEX post_moderation_queue_idx ON social.post (created_at)
  WHERE moderation_state IN ('pending_review', 'shadow_limited');

COMMENT ON COLUMN social.post.reveal_notional IS
  'Per-post opt-in. A full-disclosure profile is necessary but not sufficient: the author must also choose to reveal notionals on this specific post.';

-- ── Cashtags ────────────────────────────────────────────────────────────────
-- Resolved at write time through reference.resolve_symbol against the post's
-- creation date, so a 2023 post tagging $FB maps to the instrument now called
-- META and still appears in that instrument's feed.
CREATE TABLE social.post_instrument (
  post_id         uuid NOT NULL REFERENCES social.post(id) ON DELETE CASCADE,
  instrument_id   uuid NOT NULL REFERENCES reference.instrument(id) ON DELETE CASCADE,
  -- The literal text the author typed, kept so the post renders as written
  -- even after a ticker change.
  raw_cashtag     varchar(32) NOT NULL,
  PRIMARY KEY (post_id, instrument_id)
);

CREATE INDEX post_instrument_feed_idx ON social.post_instrument (instrument_id, post_id DESC);

-- Unresolvable cashtags are recorded rather than dropped: a spike in one
-- unresolved symbol usually means a listing we are missing.
CREATE TABLE social.unresolved_cashtag (
  post_id         uuid NOT NULL REFERENCES social.post(id) ON DELETE CASCADE,
  raw_cashtag     varchar(32) NOT NULL,
  seen_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (post_id, raw_cashtag)
);

CREATE INDEX unresolved_cashtag_trend_idx
  ON social.unresolved_cashtag (raw_cashtag, seen_at DESC);

-- ── Mentions ────────────────────────────────────────────────────────────────
CREATE TABLE social.post_mention (
  post_id         uuid NOT NULL REFERENCES social.post(id) ON DELETE CASCADE,
  mentioned_user_id uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  PRIMARY KEY (post_id, mentioned_user_id)
);

CREATE INDEX post_mention_user_idx ON social.post_mention (mentioned_user_id, post_id DESC);

-- ── Attachments ─────────────────────────────────────────────────────────────
CREATE TABLE social.post_attachment (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id         uuid NOT NULL REFERENCES social.post(id) ON DELETE CASCADE,
  kind            social.attachment_kind NOT NULL,
  display_order   smallint NOT NULL DEFAULT 0,

  -- Source references. Exactly one is set, matched to kind by the check below.
  fill_id         uuid REFERENCES oms.fill(id) ON DELETE SET NULL,
  position_id     uuid REFERENCES book.position(id) ON DELETE SET NULL,
  portfolio_id    uuid REFERENCES book.portfolio(id) ON DELETE SET NULL,
  backtest_id     uuid REFERENCES research.backtest(id) ON DELETE SET NULL,
  watchlist_id    uuid REFERENCES notify.watchlist(id) ON DELETE SET NULL,
  media_key       text,

  -- ── Verification verdict, resolved once at attach time ──────────────────
  verification    social.verification NOT NULL DEFAULT 'unverified',
  verification_method varchar(32),      -- helios_routed | broker_sync | manual
  verified_at     timestamptz,
  revoked_at      timestamptz,
  revocation_reason text,

  -- ── Echoed trade facts ──────────────────────────────────────────────────
  -- Copied from the fill so the claim is self-contained and auditable, and so
  -- a later amendment can be detected by comparison rather than by trust.
  instrument_id   uuid REFERENCES reference.instrument(id) ON DELETE SET NULL,
  side            reference.side,
  entry_price     reference.price,
  exit_price      reference.price,
  executed_at     timestamptz,
  -- Return is computed server-side and is the only performance number the
  -- serialiser may emit at returns_only disclosure.
  return_pct      reference.ratio,
  holding_period  interval,

  -- ── Withheld by default ─────────────────────────────────────────────────
  -- Stored because the author can see their own post, stripped by the
  -- serialiser for everyone else unless full disclosure AND reveal_notional.
  quantity        reference.quantity,
  notional        reference.money,

  -- Immutable snapshot payload for portfolio and backtest shares. Frozen at
  -- share time: a shared portfolio must keep showing what it showed then.
  snapshot        jsonb,
  snapshot_as_of  timestamptz,

  created_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT attachment_source_matches_kind CHECK (
    (kind = 'fill'               AND fill_id      IS NOT NULL) OR
    (kind = 'position'           AND position_id  IS NOT NULL) OR
    (kind = 'portfolio_snapshot' AND portfolio_id IS NOT NULL AND snapshot IS NOT NULL) OR
    (kind = 'backtest'           AND backtest_id  IS NOT NULL) OR
    (kind = 'watchlist'          AND watchlist_id IS NOT NULL) OR
    (kind IN ('image', 'chart')  AND media_key    IS NOT NULL)
  ),
  CONSTRAINT attachment_verified_has_method_and_time
    CHECK (verification <> 'verified' OR (verification_method IS NOT NULL AND verified_at IS NOT NULL)),
  CONSTRAINT attachment_revoked_has_reason
    CHECK (verification <> 'revoked' OR (revoked_at IS NOT NULL AND revocation_reason IS NOT NULL)),
  CONSTRAINT attachment_snapshot_has_asof
    CHECK (snapshot IS NULL OR snapshot_as_of IS NOT NULL)
);

CREATE INDEX attachment_post_idx ON social.post_attachment (post_id, display_order);
-- The re-verification sweep after a broker amendment walks fills.
CREATE INDEX attachment_fill_idx ON social.post_attachment (fill_id)
  WHERE fill_id IS NOT NULL;
CREATE INDEX attachment_instrument_idx ON social.post_attachment (instrument_id)
  WHERE instrument_id IS NOT NULL;

COMMENT ON COLUMN social.post_attachment.verification IS
  'Resolved at attach time and stored. A verification timeout yields unverified and a background job may later upgrade it; it must never yield verified on a timeout.';

-- ── Engagement ──────────────────────────────────────────────────────────────
CREATE TABLE social.reaction (
  post_id         uuid NOT NULL REFERENCES social.post(id) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  kind            social.reaction_kind NOT NULL DEFAULT 'like',
  created_at      timestamptz NOT NULL DEFAULT now(),
  -- One reaction per user per post: the kind is updated, not stacked.
  PRIMARY KEY (post_id, user_id)
);

CREATE INDEX reaction_user_idx ON social.reaction (user_id, created_at DESC);

CREATE TABLE social.bookmark (
  user_id         uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  post_id         uuid NOT NULL REFERENCES social.post(id) ON DELETE CASCADE,
  folder          varchar(48),
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, post_id)
);

CREATE INDEX bookmark_user_time_idx ON social.bookmark (user_id, created_at DESC);

-- ── Counter maintenance ─────────────────────────────────────────────────────
-- In the database rather than the service, so the number a user sees cannot
-- drift because one write path forgot to increment.
CREATE OR REPLACE FUNCTION social.bump_post_counter(
  p_post_id uuid, p_column text, p_delta integer
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  -- format with %I on a caller-supplied identifier is safe here because every
  -- caller is a trigger in this file passing a literal column name.
  EXECUTE format(
    'UPDATE social.post SET %I = greatest(%I + $1, 0) WHERE id = $2', p_column, p_column
  ) USING p_delta, p_post_id;
END $$;

CREATE OR REPLACE FUNCTION social.sync_reaction_counter() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM social.bump_post_counter(NEW.post_id, 'reaction_count', 1);
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM social.bump_post_counter(OLD.post_id, 'reaction_count', -1);
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;

CREATE TRIGGER trg_reaction_counter
  AFTER INSERT OR DELETE ON social.reaction
  FOR EACH ROW EXECUTE FUNCTION social.sync_reaction_counter();

CREATE OR REPLACE FUNCTION social.sync_bookmark_counter() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM social.bump_post_counter(NEW.post_id, 'bookmark_count', 1);
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM social.bump_post_counter(OLD.post_id, 'bookmark_count', -1);
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;

CREATE TRIGGER trg_bookmark_counter
  AFTER INSERT OR DELETE ON social.bookmark
  FOR EACH ROW EXECUTE FUNCTION social.sync_bookmark_counter();

-- Replies and reposts update their target, and the author's post count.
CREATE OR REPLACE FUNCTION social.sync_post_relations() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.parent_post_id IS NOT NULL THEN
      PERFORM social.bump_post_counter(NEW.parent_post_id, 'reply_count', 1);
    END IF;
    IF NEW.repost_of_id IS NOT NULL THEN
      PERFORM social.bump_post_counter(NEW.repost_of_id, 'repost_count', 1);
    END IF;
    UPDATE social.profile SET posts_count = posts_count + 1 WHERE user_id = NEW.author_id;

  ELSIF TG_OP = 'UPDATE' AND OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
    -- Soft delete decrements exactly once; the guard above is what makes it
    -- idempotent under repeated updates to an already-deleted post.
    IF NEW.parent_post_id IS NOT NULL THEN
      PERFORM social.bump_post_counter(NEW.parent_post_id, 'reply_count', -1);
    END IF;
    IF NEW.repost_of_id IS NOT NULL THEN
      PERFORM social.bump_post_counter(NEW.repost_of_id, 'repost_count', -1);
    END IF;
    UPDATE social.profile SET posts_count = greatest(posts_count - 1, 0)
      WHERE user_id = NEW.author_id;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_post_relations
  AFTER INSERT OR UPDATE ON social.post
  FOR EACH ROW EXECUTE FUNCTION social.sync_post_relations();

-- Rationale length is measured once at write time, because ranking reads it on
-- every candidate and length() over 2000-char bodies at feed-scan time is waste.
CREATE OR REPLACE FUNCTION social.measure_rationale() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  NEW.rationale_chars := coalesce(length(btrim(NEW.body)), 0);
  RETURN NEW;
END $$;

CREATE TRIGGER trg_post_rationale
  BEFORE INSERT OR UPDATE OF body ON social.post
  FOR EACH ROW EXECUTE FUNCTION social.measure_rationale();

SELECT platform.attach_touch_triggers('social');
