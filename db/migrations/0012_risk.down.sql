DROP TABLE IF EXISTS risk.stress_result, risk.stress_scenario,
  risk.factor_exposure, risk.var_backtest CASCADE;
DROP TABLE IF EXISTS risk.portfolio_snapshot CASCADE;
DROP FUNCTION IF EXISTS risk.is_trading_halted(uuid, uuid);
DROP TABLE IF EXISTS risk.kill_switch, risk.breach,
  risk.assessment_rule_result, risk.assessment, risk.limit_rule CASCADE;
DROP TYPE IF EXISTS risk.decision, risk.enforcement, risk.limit_kind, risk.limit_scope;
