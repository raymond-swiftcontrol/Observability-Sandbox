DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'identity.user', 'identity.credential', 'identity.user_role', 'identity.api_key',
    'book.account', 'book.portfolio', 'book.broker_connection', 'book.transfer',
    'oms.order', 'research.deployment', 'risk.limit_rule', 'risk.kill_switch',
    'platform.feature_flag'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_audit_change ON %s', t);
  END LOOP;
END $$;
DROP FUNCTION IF EXISTS audit.record(varchar, varchar, text, text, jsonb, varchar, boolean);
DROP FUNCTION IF EXISTS audit.capture_change();
DROP TABLE IF EXISTS audit.change CASCADE;
DROP TABLE IF EXISTS audit.event CASCADE;
DROP TYPE IF EXISTS audit.actor_kind;
