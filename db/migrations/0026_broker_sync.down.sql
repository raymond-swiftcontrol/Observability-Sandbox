DROP INDEX IF EXISTS book.position_lot_estimated_basis_idx;
ALTER TABLE book.position_lot
  DROP COLUMN IF EXISTS basis_note,
  DROP COLUMN IF EXISTS source_connection_id,
  DROP COLUMN IF EXISTS basis_quality;
DROP TABLE IF EXISTS broker.reconciliation_break, broker.reconciliation,
  broker.sync_gap, broker.external_balance, broker.external_position,
  broker.external_transaction, broker.sync_run, broker.sync_cursor CASCADE;
DROP TYPE IF EXISTS broker.break_kind, broker.basis_quality, broker.sync_outcome;
