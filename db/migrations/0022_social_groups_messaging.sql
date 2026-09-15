-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ 0022 · Groups and direct messaging                                        ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- DMs are where harassment lives, so the schema encodes the defence: a
-- conversation with a non-follower lands in a request inbox and carries no
-- notification until accepted, and a block makes the conversation unreachable
-- from both sides without deleting either party's history.

CREATE TYPE social.group_visibility AS ENUM ('open', 'request', 'invite_only');
CREATE TYPE social.group_role AS ENUM ('owner', 'moderator', 'member');
CREATE TYPE social.conversation_state AS ENUM ('requested', 'accepted', 'declined', 'archived');

-- ── Groups ──────────────────────────────────────────────────────────────────
CREATE TABLE social.group (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id       text UNIQUE NOT NULL DEFAULT platform.public_id('grp'),
  slug            citext UNIQUE NOT NULL,
  name            varchar(80) NOT NULL,
  description     varchar(600),
  avatar_url      text,
  visibility      social.group_visibility NOT NULL DEFAULT 'open',
  created_by      uuid NOT NULL REFERENCES identity.user(id) ON DELETE RESTRICT,
  -- Topic scoping so a group feed can be pre-filtered and so discovery can
  -- match a group to a user's declared markets.
  markets         reference.asset_class[] NOT NULL DEFAULT '{}',
  tags            text[] NOT NULL DEFAULT '{}',
  -- Posting can be restricted to moderators, which is the difference between
  -- a community and a broadcast channel.
  members_can_post boolean NOT NULL DEFAULT true,
  requires_broker_verified boolean NOT NULL DEFAULT false,
  member_count    integer NOT NULL DEFAULT 0,
  post_count      integer NOT NULL DEFAULT 0,
  archived_at     timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT group_slug_shape CHECK (slug ~ '^[a-z0-9][a-z0-9_-]{2,39}$'),
  CONSTRAINT group_counts_nonneg CHECK (member_count >= 0 AND post_count >= 0)
);

CREATE INDEX group_discovery_idx ON social.group (member_count DESC)
  WHERE archived_at IS NULL AND visibility <> 'invite_only';
CREATE INDEX group_tags_idx ON social.group USING gin (tags);

ALTER TABLE social.post
  ADD CONSTRAINT post_group_fk
  FOREIGN KEY (group_id) REFERENCES social.group(id) ON DELETE CASCADE;

CREATE TABLE social.group_member (
  group_id        uuid NOT NULL REFERENCES social.group(id) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  role            social.group_role NOT NULL DEFAULT 'member',
  state           varchar(16) NOT NULL DEFAULT 'active',  -- active|pending|banned
  invited_by      uuid REFERENCES identity.user(id) ON DELETE SET NULL,
  joined_at       timestamptz NOT NULL DEFAULT now(),
  muted_until     timestamptz,
  banned_reason   text,
  PRIMARY KEY (group_id, user_id),
  CONSTRAINT group_member_banned_has_reason
    CHECK (state <> 'banned' OR banned_reason IS NOT NULL)
);

CREATE INDEX group_member_user_idx ON social.group_member (user_id)
  WHERE state = 'active';
CREATE INDEX group_member_pending_idx ON social.group_member (group_id, joined_at)
  WHERE state = 'pending';
-- A group must always retain an owner; the service enforces transfer before
-- an owner may leave, and this index makes that check a single lookup.
CREATE INDEX group_owner_idx ON social.group_member (group_id)
  WHERE role = 'owner' AND state = 'active';

CREATE OR REPLACE FUNCTION social.sync_group_member_count() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' AND NEW.state = 'active' THEN
    UPDATE social.group SET member_count = member_count + 1 WHERE id = NEW.group_id;
  ELSIF TG_OP = 'DELETE' AND OLD.state = 'active' THEN
    UPDATE social.group SET member_count = greatest(member_count - 1, 0) WHERE id = OLD.group_id;
  ELSIF TG_OP = 'UPDATE' AND OLD.state IS DISTINCT FROM NEW.state THEN
    UPDATE social.group
       SET member_count = CASE WHEN NEW.state = 'active' THEN member_count + 1
                               ELSE greatest(member_count - 1, 0) END
     WHERE id = NEW.group_id;
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;

CREATE TRIGGER trg_group_member_count
  AFTER INSERT OR UPDATE OR DELETE ON social.group_member
  FOR EACH ROW EXECUTE FUNCTION social.sync_group_member_count();

-- ── Conversations ───────────────────────────────────────────────────────────
CREATE TABLE social.conversation (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id       text UNIQUE NOT NULL DEFAULT platform.public_id('cnv'),
  is_group        boolean NOT NULL DEFAULT false,
  title           varchar(80),
  created_by      uuid NOT NULL REFERENCES identity.user(id) ON DELETE RESTRICT,
  -- A 1:1 conversation between the same two people must be found, not
  -- recreated. participant_key is a deterministic hash of the sorted member
  -- ids, letting a unique index express that.
  participant_key text,
  state           social.conversation_state NOT NULL DEFAULT 'accepted',
  last_message_at timestamptz,
  message_count   integer NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT conversation_group_has_title
    CHECK (NOT is_group OR title IS NOT NULL),
  CONSTRAINT conversation_direct_has_key
    CHECK (is_group OR participant_key IS NOT NULL)
);

CREATE UNIQUE INDEX conversation_direct_unique_idx
  ON social.conversation (participant_key) WHERE NOT is_group;
CREATE INDEX conversation_recent_idx ON social.conversation (last_message_at DESC NULLS LAST);

CREATE TABLE social.conversation_member (
  conversation_id uuid NOT NULL REFERENCES social.conversation(id) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  -- The request inbox: a conversation opened by a non-follower is pending for
  -- the recipient until they accept, and produces no notification meanwhile.
  is_request      boolean NOT NULL DEFAULT false,
  accepted_at     timestamptz,
  last_read_at    timestamptz,
  unread_count    integer NOT NULL DEFAULT 0,
  is_muted        boolean NOT NULL DEFAULT false,
  left_at         timestamptz,
  joined_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (conversation_id, user_id),
  CONSTRAINT conversation_member_unread_nonneg CHECK (unread_count >= 0)
);

CREATE INDEX conversation_member_inbox_idx
  ON social.conversation_member (user_id, is_request)
  WHERE left_at IS NULL;
CREATE INDEX conversation_member_unread_idx
  ON social.conversation_member (user_id) WHERE unread_count > 0 AND left_at IS NULL;

-- ── Messages ────────────────────────────────────────────────────────────────
-- A hypertable: message volume is time-series shaped, old threads are rarely
-- read, and they compress extremely well.
CREATE TABLE social.message (
  ts              timestamptz NOT NULL DEFAULT now(),
  id              uuid NOT NULL DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL,
  sender_id       uuid NOT NULL,
  body            varchar(4000),
  -- A message may carry the same attachment kinds a post can, with the same
  -- disclosure rules applied by the serialiser.
  attachment_kind social.attachment_kind,
  attachment_ref  uuid,
  media_key       text,
  reply_to_id     uuid,
  edited_at       timestamptz,
  deleted_at      timestamptz,
  CONSTRAINT message_has_content
    CHECK (body IS NOT NULL OR attachment_kind IS NOT NULL OR media_key IS NOT NULL)
);

SELECT create_hypertable('social.message', 'ts',
  partitioning_column => 'conversation_id',
  number_partitions   => 8,
  chunk_time_interval => INTERVAL '30 days',
  create_default_indexes => false);

CREATE UNIQUE INDEX message_pk_idx ON social.message (id, ts);
CREATE INDEX message_conversation_idx ON social.message (conversation_id, ts DESC);

ALTER TABLE social.message SET (
  timescaledb.compress = true,
  timescaledb.compress_segmentby = 'conversation_id',
  timescaledb.compress_orderby   = 'ts DESC'
);
SELECT add_compression_policy('social.message', INTERVAL '90 days');

COMMENT ON TABLE social.message IS
  'Hypertable. Retention is deliberately unbounded — a user deleting a message soft-deletes it, but we do not silently drop conversation history on a schedule.';

-- ── Leaderboard ─────────────────────────────────────────────────────────────
-- Materialised per period rather than computed on read: the ordering is
-- expensive and must be stable for everyone looking at the same board.
CREATE TABLE social.leaderboard_entry (
  period          varchar(16) NOT NULL,     -- 30d | 90d | 1y | all
  as_of           date NOT NULL,
  rank            integer NOT NULL,
  user_id         uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  -- Ranked on risk-adjusted return, not raw return: ranking on raw return is
  -- an incentive to take uncompensated risk.
  sharpe          reference.ratio,
  return_pct      reference.ratio,
  max_drawdown    reference.ratio,
  track_record_days integer NOT NULL,
  trades_count    integer NOT NULL DEFAULT 0,
  computed_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (period, as_of, rank),
  CONSTRAINT leaderboard_minimum_track_record CHECK (track_record_days >= 180)
);

CREATE INDEX leaderboard_user_idx ON social.leaderboard_entry (user_id, as_of DESC);

COMMENT ON CONSTRAINT leaderboard_minimum_track_record ON social.leaderboard_entry IS
  'The spec''s minimum track record, enforced in the schema so a bug in the ranking job cannot put a one-month wonder at the top of the board.';

SELECT platform.attach_touch_triggers('social');
