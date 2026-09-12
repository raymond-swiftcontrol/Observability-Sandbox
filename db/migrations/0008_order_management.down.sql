DROP TABLE IF EXISTS oms.execution_quality_daily, oms.rejection, oms.algo_slice,
  oms.algo_execution, oms.route_decision CASCADE;
DROP TRIGGER IF EXISTS trg_fill_updates_order ON oms.fill;
DROP FUNCTION IF EXISTS oms.recompute_order_fill_state();
ALTER TABLE book.position_lot DROP CONSTRAINT IF EXISTS position_lot_opening_fill_fk;
DROP TABLE IF EXISTS oms.fill CASCADE;
DROP FUNCTION IF EXISTS oms.apply_order_event(uuid, oms.event_type, oms.order_status,
  reference.quantity, reference.price, text, jsonb, varchar, varchar);
DROP FUNCTION IF EXISTS oms.is_valid_transition(oms.order_status, oms.order_status);
DROP TABLE IF EXISTS oms.order_event CASCADE;
DROP TYPE IF EXISTS oms.event_type;
DROP TABLE IF EXISTS oms.order CASCADE;
DROP TYPE IF EXISTS oms.order_source, oms.execution_algo, oms.order_status,
  oms.time_in_force, oms.order_type;
