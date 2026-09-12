## Purpose

Defines how a trader gets their portfolio into Helios without linking an account: file
import and manual entry, including duplicate protection and the preview guarantee.

## ADDED Requirements

### Requirement: Import is previewed before it is committed

A file import MUST produce a dry-run preview listing the rows that would be created,
skipped as duplicates, and rejected as unparseable, and MUST NOT write any data until the
user confirms. The committed result MUST match the preview.

#### Scenario: Previewing a CSV

- **WHEN** a user uploads a transaction CSV
- **THEN** a preview is returned showing counts and per-row outcomes, and nothing is persisted

#### Scenario: Confirming an import

- **WHEN** the user confirms a previewed import
- **THEN** exactly the rows shown as creatable in the preview are created

### Requirement: Column mapping is detected and correctable

The system SHALL attempt to detect the broker format and column mapping of an uploaded
file, and MUST let the user correct the mapping before confirming. A corrected mapping for
a recognised broker format SHOULD be remembered for that user's subsequent imports.

#### Scenario: Recognised broker export

- **WHEN** a user uploads a file matching a known broker export format
- **THEN** the column mapping is pre-filled and the user may adjust it before confirming

#### Scenario: Unrecognised format

- **WHEN** the format is not recognised
- **THEN** the user is presented with the detected headers and sample values to map manually, and no row is rejected solely for being in an unknown format

### Requirement: Imports are deduplicated against existing data

An import MUST detect rows that duplicate an already-present transaction, whether
previously imported or synced from a brokerage, and MUST skip them by default.

#### Scenario: Re-importing an overlapping file

- **WHEN** a user imports a file whose date range overlaps a previous import
- **THEN** the overlapping transactions are reported as duplicates and skipped

#### Scenario: Importing a file overlapping a broker sync

- **WHEN** an imported transaction matches one already received from a linked brokerage
- **THEN** the imported row is skipped and the brokerage-sourced record is retained as authoritative

### Requirement: Manual entry supports lot-level detail

Manual position entry SHALL accept one or more lots with quantity, price and acquisition
date per lot, and MUST resolve the instrument through symbol search rather than free text.
A manually entered lot's basis quality MUST be `sourced` when the user supplies the lot
detail.

#### Scenario: Entering a multi-lot position

- **WHEN** a user enters a position as three lots with distinct prices and dates
- **THEN** three lots are created with basis quality `sourced` and the position's average price is derived from them

#### Scenario: Entering an unresolvable symbol

- **WHEN** a user enters a symbol that resolves to no instrument
- **THEN** the entry is rejected with a search prompt and nothing is created
