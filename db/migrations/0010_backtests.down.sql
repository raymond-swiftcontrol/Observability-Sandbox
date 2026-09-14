DROP TABLE IF EXISTS research.monte_carlo_result, research.walk_forward_fold,
  research.walk_forward, research.sweep_trial, research.parameter_sweep,
  research.backtest_trade CASCADE;
DROP TABLE IF EXISTS research.backtest_equity CASCADE;
DROP TABLE IF EXISTS research.backtest_metrics, research.backtest CASCADE;
DROP TYPE IF EXISTS research.slippage_model, research.sample_designation,
  research.backtest_status;
