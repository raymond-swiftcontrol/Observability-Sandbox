-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ 0023 · Reports, detection signals, moderation actions, appeals            ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- Implements the social-moderation spec. Two properties the schema enforces
-- rather than leaving to the service:
--   • Reporter identity is never reachable from the reported user's view — it
--     lives on a table the reported party has no policy granting access to.
--   • Automated detection cannot irreversibly remove content. Only an action
--     with a human actor, or a rule explicitly flagged auto_removable, may set
--     the removed state; everything else shadow-limits and queues for review.

CREATE TYPE social.report_category AS ENUM (
  'market_manipulation', 'pump_and_dump', 'spam', 'misleading_performance',
  'harassment', 'hate_speech', 'impersonation', 'unlicensed_advice',
  'self_harm', 'illegal_content', 'other'
);

CREATE TYPE social.report_status AS ENUM (
  'open', 'triaged', 'actioned', 'dismissed', 'duplicate'
);

CREATE TYPE social.moderation_verdict AS ENUM (
  'cleared', 'shadow_limited', 'removed', 'account_suspended', 'warning_issued'
);

CREATE TYPE social.target_kind AS ENUM ('post', 'profile', 'message', 'group');

-- ── Reports ─────────────────────────────────────────────────────────────────
CREATE TABLE social.report (
  id              bigserial PRIMARY KEY,
  target_kind     social.target_kind NOT NULL,
  target_post_id  uuid REFERENCES social.post(id) ON DELETE CASCADE,
  target_user_id  uuid REFERENCES identity.user(id) ON DELETE CASCADE,
  target_message_id uuid,
  target_group_id uuid REFERENCES social.group(id) ON DELETE CASCADE,

  reporter_id     uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  category        social.report_category NOT NULL,
  detail          varchar(1000),

  status          social.report_status NOT NULL DEFAULT 'open',
  -- Priority is derived at intake from category and the target's history, so
  -- the queue orders itself without a reviewer triaging every row by hand.
  priority        smallint NOT NULL DEFAULT 50,
  duplicate_of_id bigint REFERENCES social.report(id) ON DELETE SET NULL,

  reviewed_by     uuid REFERENCES identity.user(id) ON DELETE SET NULL,
  reviewed_at     timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT report_target_matches_kind CHECK (
    (target_kind = 'post'    AND target_post_id    IS NOT NULL) OR
    (target_kind = 'profile' AND target_user_id    IS NOT NULL) OR
    (target_kind = 'message' AND target_message_id IS NOT NULL) OR
    (target_kind = 'group'   AND target_group_id   IS NOT NULL)
  ),
  CONSTRAINT report_priority_bounded CHECK (priority BETWEEN 0 AND 100)
);

-- One report per reporter per target: re-reporting is deduplicated at intake
-- rather than inflating the queue.
CREATE UNIQUE INDEX report_dedupe_post_idx
  ON social.report (reporter_id, target_post_id) WHERE target_post_id IS NOT NULL;
CREATE UNIQUE INDEX report_dedupe_profile_idx
  ON social.report (reporter_id, target_user_id) WHERE target_user_id IS NOT NULL;

-- The reviewer queue: oldest-highest-priority first.
CREATE INDEX report_queue_idx ON social.report (priority DESC, created_at)
  WHERE status IN ('open', 'triaged');
CREATE INDEX report_target_post_idx ON social.report (target_post_id)
  WHERE target_post_id IS NOT NULL;
CREATE INDEX report_target_user_idx ON social.report (target_user_id)
  WHERE target_user_id IS NOT NULL;

COMMENT ON TABLE social.report IS
  'Reporter identity lives here and only here. No RLS policy grants a reported user access to this table, so "who reported me" is unanswerable from the product surface.';

-- Report count on the post drives ranking pressure; maintained by trigger so
-- it cannot drift from the report table.
CREATE OR REPLACE FUNCTION social.sync_report_counter() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' AND NEW.target_post_id IS NOT NULL THEN
    PERFORM social.bump_post_counter(NEW.target_post_id, 'report_count', 1);
  ELSIF TG_OP = 'DELETE' AND OLD.target_post_id IS NOT NULL THEN
    PERFORM social.bump_post_counter(OLD.target_post_id, 'report_count', -1);
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;

CREATE TRIGGER trg_report_counter
  AFTER INSERT OR DELETE ON social.report
  FOR EACH ROW EXECUTE FUNCTION social.sync_report_counter();

-- ── Automated detection ─────────────────────────────────────────────────────
CREATE TABLE social.detection_rule (
  key             varchar(48) PRIMARY KEY,
  name            varchar(120) NOT NULL,
  description     text NOT NULL,
  category        social.report_category NOT NULL,
  -- Thresholds live in the row, not in code, so tuning a noisy rule does not
  -- require a deploy.
  parameters      jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- The escalation ceiling for this rule. Only a rule explicitly marked
  -- auto_removable may remove content without a human; everything else
  -- shadow-limits at most, per the spec.
  auto_removable  boolean NOT NULL DEFAULT false,
  is_active       boolean NOT NULL DEFAULT true,
  -- Measured, so a rule whose precision collapses can be found and fixed
  -- rather than quietly punishing users.
  true_positive_count integer NOT NULL DEFAULT 0,
  false_positive_count integer NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE social.detection_signal (
  id              bigserial PRIMARY KEY,
  rule_key        varchar(48) NOT NULL REFERENCES social.detection_rule(key) ON DELETE CASCADE,
  target_kind     social.target_kind NOT NULL,
  target_post_id  uuid REFERENCES social.post(id) ON DELETE CASCADE,
  target_user_id  uuid REFERENCES identity.user(id) ON DELETE CASCADE,
  score           reference.ratio NOT NULL,
  -- The evidence that fired the rule. A moderator cannot fairly review a
  -- flag they cannot see the basis for.
  evidence        jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- Coordinated behaviour is detected across accounts, so a signal can name
  -- the cluster it belongs to.
  cluster_id      uuid,
  action_taken    varchar(24) NOT NULL DEFAULT 'queued',
  detected_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT detection_score_bounded CHECK (score BETWEEN 0 AND 1)
);

CREATE INDEX detection_signal_post_idx ON social.detection_signal (target_post_id)
  WHERE target_post_id IS NOT NULL;
CREATE INDEX detection_signal_cluster_idx ON social.detection_signal (cluster_id, detected_at)
  WHERE cluster_id IS NOT NULL;
CREATE INDEX detection_signal_recent_idx ON social.detection_signal (rule_key, detected_at DESC);

-- ── Actions ─────────────────────────────────────────────────────────────────
CREATE TABLE social.moderation_action (
  id              bigserial PRIMARY KEY,
  target_kind     social.target_kind NOT NULL,
  target_post_id  uuid REFERENCES social.post(id) ON DELETE CASCADE,
  target_user_id  uuid REFERENCES identity.user(id) ON DELETE CASCADE,
  target_group_id uuid REFERENCES social.group(id) ON DELETE CASCADE,

  verdict         social.moderation_verdict NOT NULL,
  -- Exactly one of these: a human reviewer, or the rule that fired.
  actor_user_id   uuid REFERENCES identity.user(id) ON DELETE SET NULL,
  actor_rule_key  varchar(48) REFERENCES social.detection_rule(key) ON DELETE SET NULL,
  -- Category shown to the affected user; the free-text reason is internal.
  reason_category social.report_category NOT NULL,
  reason_internal text NOT NULL,
  report_id       bigint REFERENCES social.report(id) ON DELETE SET NULL,
  detection_signal_id bigint REFERENCES social.detection_signal(id) ON DELETE SET NULL,

  -- Shadow limits expire; removals and suspensions do not.
  expires_at      timestamptz,
  reversed_at     timestamptz,
  reversed_by     uuid REFERENCES identity.user(id) ON DELETE SET NULL,
  reversal_reason text,
  user_notified_at timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT action_has_exactly_one_actor
    CHECK ((actor_user_id IS NOT NULL) <> (actor_rule_key IS NOT NULL)),
  CONSTRAINT action_reversal_has_reason
    CHECK (reversed_at IS NULL OR reversal_reason IS NOT NULL)
  -- The "automation may not remove" guarantee is enforced by the trigger
  -- below rather than a CHECK: it depends on social.detection_rule, and a
  -- CHECK constraint may not contain a subquery.
);

-- The central guarantee of the moderation design: an automated rule may
-- shadow-limit, warn or clear, but only a human — or a rule explicitly
-- designated auto_removable — may remove content or suspend an account.
-- Irreversible punishment without a person in the loop is the failure mode
-- worth spending a trigger to prevent.
CREATE OR REPLACE FUNCTION social.enforce_automation_ceiling() RETURNS trigger
  LANGUAGE plpgsql AS $$
DECLARE
  rule_allows_removal boolean;
BEGIN
  IF NEW.actor_user_id IS NOT NULL THEN
    RETURN NEW;  -- a human is accountable for this action
  END IF;

  IF NEW.verdict IN ('cleared', 'shadow_limited', 'warning_issued') THEN
    RETURN NEW;  -- reversible, within the automation ceiling
  END IF;

  SELECT r.auto_removable INTO rule_allows_removal
    FROM social.detection_rule r WHERE r.key = NEW.actor_rule_key;

  IF NOT COALESCE(rule_allows_removal, false) THEN
    RAISE EXCEPTION
      'detection rule % may not issue verdict % without a human reviewer',
      NEW.actor_rule_key, NEW.verdict
      USING ERRCODE = 'insufficient_privilege',
            HINT = 'Shadow-limit and queue for review, or mark the rule auto_removable.';
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER trg_automation_ceiling
  BEFORE INSERT OR UPDATE OF verdict, actor_user_id, actor_rule_key
  ON social.moderation_action
  FOR EACH ROW EXECUTE FUNCTION social.enforce_automation_ceiling();

CREATE INDEX moderation_action_target_post_idx
  ON social.moderation_action (target_post_id, created_at DESC)
  WHERE target_post_id IS NOT NULL;
CREATE INDEX moderation_action_target_user_idx
  ON social.moderation_action (target_user_id, created_at DESC)
  WHERE target_user_id IS NOT NULL;
CREATE INDEX moderation_action_expiring_idx ON social.moderation_action (expires_at)
  WHERE expires_at IS NOT NULL AND reversed_at IS NULL;
CREATE INDEX moderation_action_unnotified_idx ON social.moderation_action (created_at)
  WHERE user_notified_at IS NULL;

-- ── Appeals ─────────────────────────────────────────────────────────────────
CREATE TABLE social.appeal (
  id              bigserial PRIMARY KEY,
  -- One appeal per action, enforced by the primary-key-adjacent unique index
  -- below rather than by the service remembering to check.
  moderation_action_id bigint NOT NULL REFERENCES social.moderation_action(id) ON DELETE CASCADE,
  appellant_id    uuid NOT NULL REFERENCES identity.user(id) ON DELETE CASCADE,
  statement       varchar(2000) NOT NULL,
  status          varchar(16) NOT NULL DEFAULT 'open',   -- open|upheld|overturned
  reviewed_by     uuid REFERENCES identity.user(id) ON DELETE SET NULL,
  reviewed_at     timestamptz,
  decision_note   text,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX appeal_one_per_action_idx
  ON social.appeal (moderation_action_id);
CREATE INDEX appeal_queue_idx ON social.appeal (created_at) WHERE status = 'open';

COMMENT ON INDEX social.appeal_one_per_action_idx IS
  'The spec allows exactly one appeal per action. Enforcing it here means a second submission fails loudly instead of creating a second queue item.';

-- ── Queue health ────────────────────────────────────────────────────────────
-- The spec ties automated threshold tightening to queue age, so the age has to
-- be cheap to read. This view is what the metric exporter scrapes.
CREATE OR REPLACE VIEW social.moderation_queue_health AS
SELECT count(*)                                            AS open_reports,
       count(*) FILTER (WHERE priority >= 80)               AS high_priority_open,
       coalesce(extract(epoch FROM now() - min(created_at)), 0)::bigint
                                                            AS oldest_open_seconds,
       coalesce(avg(extract(epoch FROM now() - created_at)), 0)::bigint
                                                            AS mean_age_seconds
  FROM social.report
 WHERE status IN ('open', 'triaged');

SELECT platform.attach_touch_triggers('social');
