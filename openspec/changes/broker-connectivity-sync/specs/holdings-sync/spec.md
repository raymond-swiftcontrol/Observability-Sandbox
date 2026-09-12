## Purpose

Defines the guarantees of incremental brokerage synchronisation: idempotency, gap
detection, cost-basis reconstruction, and reconciliation against Helios's own book.

## ADDED Requirements

### Requirement: Transaction sync is idempotent

A synchronised transaction MUST be uniquely identified by its connection and external
transaction identifier. Re-delivering the same transaction MUST NOT create a second record
or double-post to the ledger.

#### Scenario: Broker re-emits a transaction

- **WHEN** a sync receives a transaction whose external id was already ingested for that connection
- **THEN** no new record is created, no ledger entry is posted, and the sync reports it as a duplicate

#### Scenario: Broker restates a transaction

- **WHEN** a sync receives a transaction with a known external id but changed amount
- **THEN** the existing record is superseded with an audit trail and the ledger is corrected by a reversing entry plus a new entry, never by mutating the original

### Requirement: Sync progress uses per-resource cursors

Each connection MUST track an independent cursor per resource, so a failure syncing one
resource does not re-sync or skip another. A sync MUST resume from its cursor after an
interruption without reprocessing the full history.

#### Scenario: Failure partway through a transaction page

- **WHEN** a transaction sync fails after committing 2 of 5 pages
- **THEN** the next run resumes from the cursor at page 3 and the position cursor is unaffected

### Requirement: Gaps are detected and reported, not silently tolerated

When a sync detects a discontinuity — a missing sequence, a period with no data where the
broker reports activity, or a position change unexplained by any transaction — it MUST
record a typed gap and surface it, rather than presenting an incomplete history as complete.

#### Scenario: Position changed with no explaining transaction

- **WHEN** a synced position's quantity changes and no transaction accounts for the change
- **THEN** a gap is recorded against that instrument and period, and the affected position's history is marked incomplete

### Requirement: Cost basis quality is explicit

Every lot MUST carry a basis quality of `sourced`, `reconstructed` or `estimated`. A lot
whose basis was not supplied by the broker and could not be derived from a complete
transaction history MUST be `estimated`, and any surface displaying its cost basis,
unrealised P&L or realised P&L MUST indicate that.

#### Scenario: Broker supplies lot-level basis

- **WHEN** a broker returns per-lot acquisition prices and dates
- **THEN** the lots are stored with basis quality `sourced`

#### Scenario: Basis derived from full transaction history

- **WHEN** a broker supplies no lots but a complete transaction history covering the whole holding period
- **THEN** lots are reconstructed from the transactions and stored with basis quality `reconstructed`

#### Scenario: Basis derived from an average price only

- **WHEN** a broker supplies only a position average price and no usable transaction history
- **THEN** a single lot is stored with basis quality `estimated` and every display of its P&L carries an estimated-basis indicator

### Requirement: Reconciliation raises typed breaks

A reconciliation pass SHALL compare broker-reported positions, quantities and cash against
Helios's book and record a typed break for each discrepancy beyond tolerance. The broker's
figures MUST NOT silently overwrite the Helios book.

#### Scenario: Quantity mismatch

- **WHEN** a broker reports 100 shares and the Helios book holds 90
- **THEN** a quantity break is recorded with both values and the delta, and neither value is overwritten

#### Scenario: Mismatch explained by a corporate action

- **WHEN** a quantity mismatch is exactly explained by a known split on the instrument
- **THEN** the break is auto-resolved with the corporate action as its resolution and the book is adjusted accordingly

### Requirement: Sync never destroys unexplained user data

A sync MUST NOT delete or overwrite a manually entered position, lot or transaction that
it cannot match to broker-reported data. Such records MUST be retained and flagged for the
user to confirm or remove.

#### Scenario: Manual position absent from broker data

- **WHEN** a user manually entered a position that the broker does not report
- **THEN** the manual position is retained, flagged as unconfirmed by the broker, and the user is asked to confirm or remove it
