# Broker Connectivity and Seamless Portfolio Import

A trader's first question on opening Helios is "where is my actual portfolio?". Today they
would have to type it in. This change lets a user link a major brokerage in under a minute
and have their holdings, transaction history and cost basis appear — or, when their broker
is unsupported or they simply prefer not to link it, get the same result by importing a
statement, pasting a CSV, or entering positions by hand. Every downstream Helios
capability (risk, performance attribution, verified social sharing) becomes useful the
moment this works, and useless until it does.

Three paths to the same destination, in descending order of fidelity:

1. **Direct link** — OAuth or API-key connection to brokers we support natively
   (Alpaca, Interactive Brokers, Tradier, tastytrade, Binance, Coinbase, OANDA).
2. **Aggregator link** — for the long tail (Schwab, Fidelity, Robinhood, Webull, E*TRADE,
   Vanguard) through a brokerage-aggregation provider behind one internal adapter
   interface, so swapping providers does not touch anything above the adapter.
3. **Manual** — statement/CSV import with a column mapper that learns per-broker formats,
   or direct entry with symbol search and lot-level cost basis.

## Why this is harder than it looks

- **Cost basis is not given to you.** Many brokers return positions with an average price
  and no lots. Realised P&L, wash sales and tax reporting all need lots, so we reconstruct
  them from transaction history where available and mark them `estimated` where not. A
  position whose basis is estimated must say so everywhere it is displayed.
- **Transaction histories are incomplete and non-idempotent.** Brokers paginate
  inconsistently, restate, and re-emit. Sync must be cursor-based, idempotent per external
  transaction id, and able to detect and repair gaps.
- **Corporate actions are applied differently by every broker.** A 4:1 split may arrive as
  an adjustment, two transactions, or silently. Reconciliation against our own corporate
  action data is how we catch it.
- **Credentials are the crown jewels.** No token, key or secret may ever be stored in
  Postgres. Only a reference into the secret store.

## What ships

- A connection flow with per-broker capability declaration (what it can sync, at what
  granularity, how often).
- Incremental sync of balances, positions, transactions and orders with per-resource
  cursors, backoff that respects each broker's rate limits, and a visible sync status.
- Lot reconstruction from transaction history, with an explicit `basis_quality` on every lot.
- A reconciliation pass that compares broker-reported positions and cash to our own book
  and raises typed breaks.
- Statement/CSV import with format detection, a mapping UI, a dry-run preview, and
  duplicate detection against already-synced transactions.
- Manual portfolio entry with lot-level detail.
- Mobile surfaces: connect, sync status, break review, import wizard, manual entry.

## Non-goals

- **Placing orders through the aggregator.** Links are read-only here; trading stays on the
  native broker adapters in `execution-gateway`.
- **Screenshot / OCR import.** Interesting, unreliable, deferred.
- **Tax form generation.** We produce the lot data a tax report needs; generating 1099/8949
  output is a separate change.
- **Bank account linking or funding.** Out of scope.

## Capabilities

- `broker-linking` — connecting, capability declaration, credential handling, revocation.
- `holdings-sync` — incremental sync, idempotency, gap detection, reconciliation.
- `portfolio-import` — CSV/statement import and manual entry, including basis quality.

## Non-negotiables

- Credentials live only in the secret store; the database holds a reference.
- A sync must never delete a user's manually entered data it cannot explain.
- Any displayed cost basis that was estimated rather than sourced MUST be labelled as such.
- A read-only connection must be provably unable to place an order: the adapter interface
  for aggregator links has no submit method at all, rather than one that refuses.
