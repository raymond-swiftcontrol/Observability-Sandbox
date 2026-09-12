DROP FUNCTION IF EXISTS platform.interval_to_duration(reference.bar_interval);
DROP FUNCTION IF EXISTS platform.periods_per_year(reference.bar_interval);
DROP FUNCTION IF EXISTS platform.pct_change(numeric, numeric);
DROP FUNCTION IF EXISTS platform.safe_div(numeric, numeric);
DROP FUNCTION IF EXISTS platform.public_id(text);
DROP FUNCTION IF EXISTS platform.attach_touch_triggers(text);
DROP FUNCTION IF EXISTS platform.touch_updated_at();
DROP FUNCTION IF EXISTS platform.is_service_role();
DROP FUNCTION IF EXISTS platform.current_request_id();
DROP FUNCTION IF EXISTS platform.current_account_id();
DROP FUNCTION IF EXISTS platform.current_user_id();
DROP TYPE IF EXISTS reference.data_quality;
DROP TYPE IF EXISTS reference.position_side;
DROP TYPE IF EXISTS reference.side;
DROP TYPE IF EXISTS reference.bar_interval;
DROP TYPE IF EXISTS reference.asset_class;
DROP DOMAIN IF EXISTS reference.email, reference.ticker, reference.currency_code,
  reference.weight, reference.ratio, reference.bps, reference.money,
  reference.quantity, reference.signed_px, reference.price;
DROP SCHEMA IF EXISTS audit, platform, notify, risk, research, oms, book,
  fundamental, market, reference, identity CASCADE;
