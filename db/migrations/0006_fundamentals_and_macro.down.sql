DROP VIEW IF EXISTS fundamental.macro_first_print;
DROP TABLE IF EXISTS fundamental.macro_observation, fundamental.macro_series,
  fundamental.institutional_holding, fundamental.short_interest,
  fundamental.corporate_event, fundamental.estimate,
  fundamental.company_snapshot, fundamental.statement_item,
  fundamental.metric_definition, fundamental.filing CASCADE;
DROP TYPE IF EXISTS fundamental.event_type, fundamental.restatement,
  fundamental.fiscal_period, fundamental.statement_type;
