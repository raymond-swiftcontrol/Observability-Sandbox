DROP TABLE IF EXISTS platform.service_heartbeat, platform.rate_limit_violation CASCADE;
DROP FUNCTION IF EXISTS platform.flag_enabled(varchar, uuid, uuid);
DROP TABLE IF EXISTS platform.feature_flag CASCADE;
DROP FUNCTION IF EXISTS platform.reap_expired_leases();
DROP FUNCTION IF EXISTS platform.claim_job(varchar, varchar, integer);
DROP TABLE IF EXISTS platform.job, platform.idempotency_key, platform.outbox CASCADE;
