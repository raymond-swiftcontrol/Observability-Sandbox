## Purpose

Defines how a trader connects a brokerage to Helios, what each connection is permitted to
do, and how credentials and revocation are handled.

## ADDED Requirements

### Requirement: Credentials are never persisted in the application database

The system MUST store brokerage credentials, tokens and API secrets only in the configured
secret store, and MUST persist only an opaque reference alongside the connection record.
No log, error payload, trace attribute or database column may contain a credential value.

#### Scenario: Completing a link

- **WHEN** a user completes a brokerage authorisation
- **THEN** the credential is written to the secret store and the connection record holds only its reference

#### Scenario: Adapter raises an error carrying the credential

- **WHEN** a broker API returns an error whose payload echoes the submitted key
- **THEN** the persisted error and the emitted log are redacted so no credential material is retained

### Requirement: Connections declare their capabilities

Each connection MUST declare which resources it can synchronise (balances, positions,
transactions, orders), the granularity available, and whether it is read-only. The system
MUST NOT attempt an operation a connection has not declared.

#### Scenario: Broker without transaction history

- **WHEN** a connection declares it cannot supply transaction history
- **THEN** no transaction sync is scheduled for it and positions synced through it are marked as having estimated cost basis

#### Scenario: Read-only connection

- **WHEN** a connection is declared read-only
- **THEN** no order submission path exists for it and any attempt to route an order to it fails before reaching the broker

### Requirement: Revocation is immediate and complete

When a user disconnects a brokerage, the system MUST stop all scheduled syncs for it,
delete the stored credential from the secret store, and retain the already-synced
historical data unless the user explicitly requests its deletion.

#### Scenario: Disconnecting a brokerage

- **WHEN** a user disconnects a linked brokerage
- **THEN** scheduled syncs stop, the credential is deleted from the secret store, and previously synced positions and transactions remain visible marked as no longer syncing

#### Scenario: Disconnecting with data deletion requested

- **WHEN** a user disconnects and requests deletion of the synced data
- **THEN** positions, transactions and lots sourced from that connection are deleted, and manually entered data is retained

### Requirement: Connection health is observable to the user

The system SHALL expose, for each connection, the last successful sync time per resource,
the current state, and the reason for any failure in language the user can act on.

#### Scenario: Expired authorisation

- **WHEN** a connection's authorisation expires
- **THEN** the connection state becomes re-authorisation-required and the user is prompted to reconnect, rather than syncs failing silently

#### Scenario: Broker rate limit reached

- **WHEN** a broker returns a rate-limit response
- **THEN** the sync backs off within that broker's declared limits and the connection remains healthy rather than being marked failed
