# Design — Broker Connectivity and Portfolio Import

## Services and ownership

A new service `apps/broker-sync` (TypeScript/NestJS + BullMQ) owns the `broker` schema and
every outbound call to a brokerage or aggregator. It is deliberately separate from
`execution-gateway`: that service is latency-critical and on the order path, while this one
is throughput-oriented, runs long retrying jobs, and must be able to back off for minutes
without affecting trading.

```
mobile ─▶ api-gateway ─▶ broker-sync ─▶ adapter registry
                             │              ├─ native: alpaca · ibkr · tradier · tastytrade
                             │              │          binance · coinbase · oanda
                             │              └─ aggregator: one adapter, provider behind it
                             ├─▶ secret store (credential refs only)
                             ├─▶ broker schema + book schema (positions, lots, ledger)
                             └─▶ Kafka broker.sync.v1 / broker.breaks.v1
```

## The adapter interface

Two interfaces, not one with a capability flag:

```ts
interface ReadOnlyBrokerAdapter {
  capabilities(): BrokerCapabilities;
  fetchBalances(ctx): Promise<BalanceSnapshot[]>;
  fetchPositions(ctx): Promise<PositionSnapshot[]>;
  fetchTransactions(ctx, cursor): Promise<Page<TransactionRecord>>;
  fetchOrders?(ctx, cursor): Promise<Page<OrderRecord>>;
}

interface TradingBrokerAdapter extends ReadOnlyBrokerAdapter {
  submitOrder(ctx, order): Promise<BrokerOrderAck>;
  cancelOrder(ctx, id): Promise<void>;
}
```

An aggregator-backed connection is typed `ReadOnlyBrokerAdapter`, so "this connection
cannot trade" is a compile-time property rather than a runtime check someone can forget.
`execution-gateway` accepts only `TradingBrokerAdapter`.

## Schema (migrations 0025–0028)

- `broker.provider` — catalogue of supported brokers and aggregators with their declared
  capability matrix, rate limits and auth kind.
- `broker.connection` — extends the existing `book.broker_connection` concept with
  `provider_id`, `auth_kind`, `secret_ref`, `state`, `read_only`, `capability_snapshot`
  (what it declared at link time, so behaviour is reproducible).
- `broker.sync_cursor` — `(connection_id, resource)` → cursor, last success, last attempt,
  consecutive failures, next attempt. One row per resource is what makes independent
  per-resource resumption possible.
- `broker.sync_run` — one row per attempt: resource, outcome, counts
  (created/duplicate/superseded/rejected), duration, error class. This is the table the
  user-facing sync status reads.
- `broker.external_transaction` — raw broker transaction keyed
  `(connection_id, external_id)`, with the normalised interpretation and a pointer to the
  ledger transaction it produced. Supersession is a new row plus
  `superseded_by`, never an update.
- `broker.import_batch` / `broker.import_row` — file imports, their detected mapping, the
  preview outcome per row, and the commit result. Keeping the preview persisted is what
  lets us guarantee "the committed result matches the preview".
- `broker.format_profile` — learned column mappings per user per broker format.
- Extensions to `book.position_lot`: `basis_quality` enum and `source_connection_id`.

## Cost-basis reconstruction

```
if broker supplies lots                 → basis_quality = sourced
else if transaction history is complete → replay transactions through the account's
                                          lot-selection method → reconstructed
else                                    → single synthetic lot at the reported average
                                          price → estimated
```

"Complete" means: transactions cover a continuous period from before the position's first
acquisition to now, with no recorded gap, and replaying them reproduces the broker's
reported quantity exactly. If the replay disagrees with the reported quantity, the history
is not complete — we record a gap and fall back to `estimated`. Quietly trusting a replay
that does not reconcile is how wrong tax numbers get shipped.

## Scheduling and rate limits

BullMQ repeatable jobs per connection per resource. Intervals come from the provider's
declared limits, not a global constant: balances every 5 minutes while the market is open,
positions every 15, transactions hourly, with an immediate run on user request (rate
limited per connection). A token-bucket limiter per provider, shared across workers through
Redis, keeps us inside published limits even with several workers. `Retry-After` is
honoured when present; otherwise exponential backoff with jitter, and a circuit breaker
after N consecutive failures that flips the connection to a degraded state visible to the
user.

## Reconciliation

Runs after each position sync and nightly for every connection. For each instrument,
compare quantity and basis; for each currency, compare cash. Typed breaks:
`quantity`, `cash`, `cost_basis`, `missing_in_broker`, `missing_in_helios`,
`corporate_action_suspected`. Auto-resolution is attempted only for
`corporate_action_suspected`, and only when a known corporate action explains the delta
exactly. Everything else requires a decision, surfaced in the mobile break-review screen
and in the web console.

## Failure modes

| Failure | Behaviour |
| --- | --- |
| Credential expired | Connection → `reauthorisation_required`, syncs paused, user prompted. Not a failure alert. |
| Provider outage | Circuit opens, connection → `degraded`, last-known data still served with its staleness shown. |
| Partial page commit | Cursor advances only on a committed page, so the next run resumes at the page boundary; within-page idempotency makes a replay harmless. |
| Broker reports a position we have no transactions for | Position synced, gap recorded, basis `estimated`, flagged in the UI. |
| Aggregator changes a schema | Adapter validates responses against a schema and fails the run with a typed `contract_violation` rather than writing misinterpreted data. |
| Import confirmed twice | Batch commit is idempotent on batch id; the second confirm returns the first result. |

## Observability

- Spans: `broker.sync.run` (attributes: provider, resource, cursor, created/duplicate
  counts), `broker.adapter.call` (provider, endpoint, status, retry count),
  `broker.reconcile`, `broker.import.preview` / `.commit`.
- Metrics: `broker_sync_duration_seconds{provider,resource}`,
  `broker_sync_failures_total{provider,error_class}`, `broker_sync_staleness_seconds`
  (gauge per connection — the one users actually feel), `broker_breaks_open{type}`,
  `broker_rate_limit_hits_total{provider}`, `broker_lots_by_basis_quality`.
- Alerts: staleness above threshold for any healthy connection; open breaks older than 24h;
  `contract_violation` at any rate above zero.

## Security review points

- Credential refs only; a CI check greps migrations and models for credential-shaped column
  names.
- Secret-store access is per-service IAM, scoped by path prefix per connection.
- SSRF: aggregator and broker base URLs come from the provider catalogue, never from user
  input.
- Import files: size cap, content-type and extension validation, parsed in a worker with a
  memory ceiling, never evaluated; CSV formula injection neutralised on export paths.
- IDOR: every connection, break and import batch is fetched scoped by the owning account,
  enforced by RLS as well as by the query.
