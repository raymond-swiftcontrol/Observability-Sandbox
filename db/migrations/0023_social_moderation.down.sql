DROP VIEW IF EXISTS social.moderation_queue_health;
DROP TRIGGER IF EXISTS trg_automation_ceiling ON social.moderation_action;
DROP FUNCTION IF EXISTS social.enforce_automation_ceiling();
DROP TABLE IF EXISTS social.appeal, social.moderation_action,
  social.detection_signal, social.detection_rule CASCADE;
DROP TRIGGER IF EXISTS trg_report_counter ON social.report;
DROP FUNCTION IF EXISTS social.sync_report_counter();
DROP TABLE IF EXISTS social.report CASCADE;
DROP TYPE IF EXISTS social.target_kind, social.moderation_verdict,
  social.report_status, social.report_category;
