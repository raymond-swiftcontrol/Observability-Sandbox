DROP TABLE IF EXISTS research.deployment_performance_daily, research.deployment_run CASCADE;
DROP TABLE IF EXISTS research.signal CASCADE;
ALTER TABLE book.position DROP CONSTRAINT IF EXISTS position_strategy_fk;
ALTER TABLE oms.order DROP CONSTRAINT IF EXISTS order_strategy_fk;
DROP TABLE IF EXISTS research.deployment, research.strategy_parameter,
  research.strategy_version, research.strategy CASCADE;
DROP TYPE IF EXISTS research.signal_action, research.strategy_status, research.strategy_kind;
