DROP FUNCTION IF EXISTS reference.adjustment_factor(uuid, date, date);
DROP FUNCTION IF EXISTS reference.resolve_symbol(text, date);
DROP FUNCTION IF EXISTS reference.is_market_open(smallint, timestamptz, boolean);
DROP TABLE IF EXISTS reference.trading_halt, reference.corporate_action,
  reference.index_constituent, reference.future_contract, reference.option_contract,
  reference.instrument_vendor_map, reference.instrument_symbol, reference.instrument,
  reference.sector, reference.trading_session, reference.calendar_exception,
  reference.calendar_weekly_schedule, reference.calendar, reference.venue,
  reference.currency CASCADE;
DROP TYPE IF EXISTS reference.corporate_action_type, reference.settlement_type,
  reference.exercise_style, reference.option_type, reference.instrument_status,
  reference.venue_kind;
