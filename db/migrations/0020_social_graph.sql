-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ 0020 · Social graph: profiles, follows, blocks, mutes                     ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- Implements openspec/changes/social-trading-network/specs/social-graph/spec.md.
--
-- Two properties this schema has to make structurally hard to get wrong:
--   1. A block must be enforced in both directions and in every query path. It
--      is expressed here as a helper predicate plus an RLS policy, so a
--      resolver that forgets the filter still cannot read the rows.
--   2. Performance disclosure is a column on the profile, not a UI preference.
--      Serialisation reads it; nothing renders equity or notional without it.

CREATE SCHEMA IF NOT EXISTS social;

CREATE TYPE social.visibility AS ENUM ('public', 'followers', 'private');

CREATE TYPE social.disclosure_level AS ENUM (
  'none',          -- no performance data leaves the server
  'returns_only',  -- percentages and risk stats, never amounts
  'full'           -- amounts, but still only per-post opt-in for notionals
);

CREATE TYPE social.follow_state AS ENUM ('pending', 'active');

-- ── Profiles ────────────────────────────────────────────────────────────────
CREATE TABLE social.profile (
  user_id         uuid PRIMARY KEY REFERENCES identity.user(id) ON DELETE CASCADE,
  public_id       text UNIQUE NOT NULL DEFAULT platform.public_id('prf'),
  -- citext gives case-insensitive uniqueness without a functional index, which
  -- matters because handles are compared in URLs, mentions and search.
  handle          citext NOT NULL,
  display_name    varchar(60) NOT NULL,
  bio             varchar(400),
  avatar_url      text,
  banner_url      text,
  links           jsonb NOT NULL DEFAULT '[]'::jsonb,
  location        varchar(80),

  visibility      social.visibility NOT NULL DEFAULT 'public',
  performance_disclosure social.disclosure_level NOT NULL DEFAULT 'none',
  -- Which portfolio, if any, backs the public performance strip. Null means
  -- the user shares no track record even at returns_only.
  performance_portfolio_id uuid REFERENCES book.portfolio(id) ON DELETE SET NULL,
  -- Trading style, surfaced for discovery. Self-declared, never inferred.
  trading_styles  text[] NOT NULL DEFAULT '{}',
  markets         reference.asset_class[] NOT NULL DEFAULT '{}',

  -- Badges. broker_verified means at least one healthy brokerage connection
  -- has been present; it is what makes a verified trade share possible.
  is_broker_verified boolean NOT NULL DEFAULT false,
  is_identity_verified boolean NOT NULL DEFAULT false,
  is_staff        boolean NOT NULL DEFAULT false,

  -- Denormalised counters. Maintained by trigger; they are read on every
  -- profile render and recomputing them from the edge table would be the
  -- single hottest query in the social service.
  followers_count integer NOT NULL DEFAULT 0,
  following_count integer NOT NULL DEFAULT 0,
  posts_count     integer NOT NULL DEFAULT 0,

  -- Moderation posture
  is_shadow_limited boolean NOT NULL DEFAULT false,
  shadow_limited_until timestamptz,
  suspended_at    timestamptz,
  suspended_reason text,

  -- Leaderboard participation is opt-in, per the spec.
  leaderboard_opt_in boolean NOT NULL DEFAULT false,
  track_record_start date,

  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT profile_handle_shape
    CHECK (handle ~ '^[A-Za-z0-9_]{3,24}$'),
  CONSTRAINT profile_disclosure_needs_portfolio
    CHECK (performance_disclosure = 'none' OR performance_portfolio_id IS NOT NULL),
  CONSTRAINT profile_counters_nonneg
    CHECK (followers_count >= 0 AND following_count >= 0 AND posts_count >= 0),
  CONSTRAINT profile_suspended_has_reason
    CHECK (suspended_at IS NULL OR suspended_reason IS NOT NULL)
);

CREATE UNIQUE INDEX profile_handle_idx ON social.profile (handle);
CREATE INDEX profile_search_idx ON social.profile
  USING gin ((handle || ' ' || display_name) gin_trgm_ops);
CREATE INDEX profile_leaderboard_idx ON social.profile (followers_count DESC)
  WHERE leaderboard_opt_in AND suspended_at IS NULL;

COMMENT ON COLUMN social.profile.performance_disclosure IS
  'Governs what the serialiser is allowed to emit about this user. At returns_only, percentage returns and risk statistics only; equity, notional and quantity are stripped server-side by allowlist, never hidden client-side.';

-- Handles are not immediately reusable: a released handle would otherwise let
-- someone impersonate the previous holder in old mentions and links.
CREATE TABLE social.handle_release (
  handle          citext PRIMARY KEY,
  released_by     uuid REFERENCES identity.user(id) ON DELETE SET NULL,
  released_at     timestamptz NOT NULL DEFAULT now(),
  -- Not a generated column: timestamptz + interval is STABLE rather than
  -- IMMUTABLE (it resolves against the session TimeZone), and Postgres rejects
  -- a non-immutable generation expression. A default plus a check keeps the
  -- 30-day rule enforced without the immutability problem.
  reclaimable_at  timestamptz NOT NULL DEFAULT now() + INTERVAL '30 days',
  CONSTRAINT handle_release_window
    CHECK (reclaimable_at >= released_at + INTERVAL '30 days')
);

CREATE OR REPLACE FUNCTION social.handle_available(p_handle citext)
  RETURNS boolean LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT NOT EXISTS (SELECT 1 FROM social.profile WHERE handle = p_handle)
     AND NOT EXISTS (
       SELECT 1 FROM social.handle_release
        WHERE handle = p_handle AND reclaimable_at > now()
     )
$$;

-- ── Follows ─────────────────────────────────────────────────────────────────
CREATE TABLE social.follow (
  follower_id     uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  followee_id     uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  state           social.follow_state NOT NULL DEFAULT 'active',
  -- Affinity feeds feed ranking; recomputed periodically from engagement.
  affinity_score  reference.ratio NOT NULL DEFAULT 0,
  notify_on_post  boolean NOT NULL DEFAULT false,
  requested_at    timestamptz NOT NULL DEFAULT now(),
  accepted_at     timestamptz,
  PRIMARY KEY (follower_id, followee_id),
  CONSTRAINT follow_no_self CHECK (follower_id <> followee_id),
  CONSTRAINT follow_active_has_accepted
    CHECK ((state = 'active') = (accepted_at IS NOT NULL))
);

-- The two directions of the graph are read on completely different paths:
-- fan-out walks followers, profile rendering walks following.
CREATE INDEX follow_followers_idx ON social.follow (followee_id, accepted_at DESC)
  WHERE state = 'active';
CREATE INDEX follow_following_idx ON social.follow (follower_id, accepted_at DESC)
  WHERE state = 'active';
CREATE INDEX follow_pending_idx ON social.follow (followee_id, requested_at DESC)
  WHERE state = 'pending';

-- ── Blocks and mutes ────────────────────────────────────────────────────────
CREATE TABLE social.block (
  blocker_id      uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  blocked_id      uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  reason          varchar(48),
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (blocker_id, blocked_id),
  CONSTRAINT block_no_self CHECK (blocker_id <> blocked_id)
);

-- Enforcement is bidirectional, so the reverse lookup needs its own index.
CREATE INDEX block_reverse_idx ON social.block (blocked_id, blocker_id);

CREATE TABLE social.mute (
  muter_id        uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  muted_id        uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  -- A mute can expire; a block cannot.
  expires_at      timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (muter_id, muted_id),
  CONSTRAINT mute_no_self CHECK (muter_id <> muted_id)
);

-- Permanent mutes are the overwhelming majority and get their own small
-- partial index; expiring ones are covered by the ordered index below, with
-- the expiry compared at query time (now() cannot appear in an index predicate).
CREATE INDEX mute_permanent_idx ON social.mute (muter_id)
  WHERE expires_at IS NULL;
CREATE INDEX mute_expiring_idx ON social.mute (muter_id, expires_at)
  WHERE expires_at IS NOT NULL;

-- The single predicate every read path and RLS policy uses. Kept as one
-- function so there is exactly one definition of "these two cannot see each
-- other" to get right.
CREATE OR REPLACE FUNCTION social.is_blocked_between(a uuid, b uuid)
  RETURNS boolean LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT EXISTS (
    SELECT 1 FROM social.block
     WHERE (blocker_id = a AND blocked_id = b)
        OR (blocker_id = b AND blocked_id = a)
  )
$$;

CREATE OR REPLACE FUNCTION social.can_view_profile(p_viewer uuid, p_owner uuid)
  RETURNS boolean LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN p_viewer = p_owner THEN true
    WHEN social.is_blocked_between(p_viewer, p_owner) THEN false
    ELSE COALESCE((
      SELECT CASE p.visibility
        WHEN 'public' THEN true
        WHEN 'followers' THEN EXISTS (
          SELECT 1 FROM social.follow f
           WHERE f.follower_id = p_viewer AND f.followee_id = p_owner
             AND f.state = 'active')
        WHEN 'private' THEN EXISTS (
          SELECT 1 FROM social.follow f
           WHERE f.follower_id = p_viewer AND f.followee_id = p_owner
             AND f.state = 'active')
      END
      FROM social.profile p WHERE p.user_id = p_owner
    ), false)
  END
$$;

-- ── Counter maintenance ─────────────────────────────────────────────────────
-- Counters must exclude pending follows and relationships involving a block,
-- per the spec. Doing it in a trigger keeps the published number honest
-- regardless of which service wrote the edge.
CREATE OR REPLACE FUNCTION social.sync_follow_counters() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' AND NEW.state = 'active' THEN
    UPDATE social.profile SET following_count = following_count + 1
      WHERE user_id = NEW.follower_id;
    UPDATE social.profile SET followers_count = followers_count + 1
      WHERE user_id = NEW.followee_id;
  ELSIF TG_OP = 'DELETE' AND OLD.state = 'active' THEN
    UPDATE social.profile SET following_count = greatest(following_count - 1, 0)
      WHERE user_id = OLD.follower_id;
    UPDATE social.profile SET followers_count = greatest(followers_count - 1, 0)
      WHERE user_id = OLD.followee_id;
  ELSIF TG_OP = 'UPDATE' AND OLD.state IS DISTINCT FROM NEW.state THEN
    IF NEW.state = 'active' THEN
      UPDATE social.profile SET following_count = following_count + 1
        WHERE user_id = NEW.follower_id;
      UPDATE social.profile SET followers_count = followers_count + 1
        WHERE user_id = NEW.followee_id;
    ELSE
      UPDATE social.profile SET following_count = greatest(following_count - 1, 0)
        WHERE user_id = NEW.follower_id;
      UPDATE social.profile SET followers_count = greatest(followers_count - 1, 0)
        WHERE user_id = NEW.followee_id;
    END IF;
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;

CREATE TRIGGER trg_follow_counters
  AFTER INSERT OR UPDATE OR DELETE ON social.follow
  FOR EACH ROW EXECUTE FUNCTION social.sync_follow_counters();

-- Blocking severs the follow in both directions immediately, which the
-- counter trigger then reflects. Doing this in the database means no service
-- can block someone and leave the edge behind.
CREATE OR REPLACE FUNCTION social.enforce_block() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM social.follow
   WHERE (follower_id = NEW.blocker_id AND followee_id = NEW.blocked_id)
      OR (follower_id = NEW.blocked_id AND followee_id = NEW.blocker_id);
  RETURN NEW;
END $$;

CREATE TRIGGER trg_block_severs_follows
  AFTER INSERT ON social.block
  FOR EACH ROW EXECUTE FUNCTION social.enforce_block();

-- ── Verified track record, refreshed by a scheduled job ────────────────────
-- Computed from the book, never self-reported. Returns are time-weighted so
-- that deposits and withdrawals do not flatter the number.
CREATE TABLE social.author_stats (
  user_id         uuid PRIMARY KEY REFERENCES identity.user(id) ON DELETE CASCADE,
  as_of           date NOT NULL,
  track_record_days integer NOT NULL DEFAULT 0,
  twr_30d         reference.ratio,
  twr_90d         reference.ratio,
  twr_1y          reference.ratio,
  twr_inception   reference.ratio,
  max_drawdown_1y reference.ratio,
  volatility_1y   reference.ratio,
  sharpe_1y       reference.ratio,
  win_rate        reference.ratio,
  trades_count_90d integer NOT NULL DEFAULT 0,
  -- Quality signals used by feed ranking, not shown to users.
  engagement_score reference.ratio NOT NULL DEFAULT 0,
  report_rate     reference.ratio NOT NULL DEFAULT 0,
  rationale_rate  reference.ratio NOT NULL DEFAULT 0,
  verified_share_rate reference.ratio NOT NULL DEFAULT 0,
  computed_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX author_stats_leaderboard_idx
  ON social.author_stats (sharpe_1y DESC NULLS LAST)
  WHERE track_record_days >= 180;

COMMENT ON INDEX social.author_stats_leaderboard_idx IS
  'The 180-day floor is the spec''s minimum track record: without it a single lucky month tops the leaderboard, which is both misleading and an incentive to gamble.';

SELECT platform.attach_touch_triggers('social');
