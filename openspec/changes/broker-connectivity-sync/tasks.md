# Tasks — Broker Connectivity and Portfolio Import

## 1. Schema

- [ ] 1.1 Migration `0025_broker_providers.sql`: `broker.provider` catalogue with capability
      matrix, auth kind, rate limits; seed the supported provider list.
- [ ] 1.2 Migration `0026_broker_connections.sql`: `broker.connection`,
      `broker.sync_cursor`, `broker.sync_run`; constraint that a read-only connection
      cannot be referenced by an order.
- [ ] 1.3 Migration `0027_broker_transactions.sql`: `broker.external_transaction` with
      `(connection_id, external_id)` uniqueness and supersession chain;
      `broker.sync_gap`.
- [ ] 1.4 Migration `0028_portfolio_import.sql`: `broker.import_batch`,
      `broker.import_row`, `broker.format_profile`; add `basis_quality` and
      `source_connection_id` to `book.position_lot`.
- [ ] 1.5 RLS policies for every new table, scoped by owning account.

## 2. Adapter layer

- [ ] 2.1 Define `ReadOnlyBrokerAdapter` and `TradingBrokerAdapter` in
      `packages/shared-types`, plus the normalised `TransactionRecord` /
      `PositionSnapshot` / `BalanceSnapshot` contracts with Zod schemas.
- [ ] 2.2 Adapter registry with provider catalogue lookup and capability enforcement.
- [ ] 2.3 Alpaca adapter (full: balances, positions, transactions, orders).
- [ ] 2.4 Interactive Brokers adapter (flex queries + gateway).
- [ ] 2.5 Binance and Coinbase adapters (crypto: no lots, derive from trade history).
- [ ] 2.6 Tradier and tastytrade adapters.
- [ ] 2.7 Aggregator adapter for the long tail, typed read-only, provider pluggable.
- [ ] 2.8 Response schema validation producing typed `contract_violation` failures.
- [ ] 2.9 Per-provider Redis token-bucket limiter honouring `Retry-After`, plus circuit breaker.

## 3. broker-sync service

- [ ] 3.1 Scaffold `apps/broker-sync` (NestJS + BullMQ, OTel, health endpoints, Dockerfile).
- [ ] 3.2 Link flow: OAuth start/callback, API-key submission, capability snapshot,
      credential write to the secret store with a redaction-tested error path.
- [ ] 3.3 Balance and position sync jobs with per-resource cursors.
- [ ] 3.4 Transaction sync with idempotent upsert, supersession, and reversing ledger entries.
- [ ] 3.5 Lot reconstruction engine with the three basis-quality paths and the
      replay-must-reconcile rule.
- [ ] 3.6 Gap detection and `broker.sync_gap` recording.
- [ ] 3.7 Reconciliation pass with typed breaks and corporate-action auto-resolution.
- [ ] 3.8 Revocation: stop jobs, delete credential, optional data deletion.
- [ ] 3.9 Emit `broker.sync.v1` and `broker.breaks.v1`.

## 4. Import and manual entry

- [ ] 4.1 Format detection over a fixture corpus of real-world broker exports.
- [ ] 4.2 Preview engine: persisted per-row outcomes, duplicate detection against both
      imports and synced transactions.
- [ ] 4.3 Idempotent batch commit that reproduces the preview exactly.
- [ ] 4.4 Learned `format_profile` reuse per user.
- [ ] 4.5 Manual position entry with instrument resolution and multi-lot support.
- [ ] 4.6 File-handling hardening: size cap, content-type validation, memory-bounded
      parsing, CSV injection neutralisation on export.

## 5. Gateway and mobile

- [ ] 5.1 GraphQL/REST surface: providers, connections, sync status, breaks, imports.
- [ ] 5.2 Mobile connect flow with provider picker and OAuth web view.
- [ ] 5.3 Sync status screen: per-resource last success, staleness, actionable errors.
- [ ] 5.4 Break review screen with accept/adjust/ignore actions.
- [ ] 5.5 Import wizard: upload, mapping correction, preview, confirm.
- [ ] 5.6 Manual entry screen with lot editor.
- [ ] 5.7 Estimated-basis indicator everywhere cost basis or P&L is displayed.

## 6. Verification

- [ ] 6.1 Unit tests for every spec scenario; adapter tests against recorded fixtures.
- [ ] 6.2 Idempotency test: replay an entire transaction history twice, assert the ledger
      is unchanged and balances still reconcile.
- [ ] 6.3 Lot-reconstruction golden tests including splits, spin-offs and wash sales.
- [ ] 6.4 Credential-leak test: force adapter errors that echo secrets, assert nothing
      sensitive reaches the database, logs or spans.
- [ ] 6.5 Security review: SSRF on provider URLs, IDOR on connections/breaks/batches,
      RLS bypass, upload handling, OAuth state and PKCE verification.
- [ ] 6.6 Grafana dashboard, staleness SLO and break-age alerts.
- [ ] 6.7 ADR on the two-interface read-only design and on not overwriting the book from
      broker data.
