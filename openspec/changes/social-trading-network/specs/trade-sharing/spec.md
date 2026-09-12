## Purpose

Defines how a trader shares a real trade, position or backtest into the social layer, what
the "broker-verified" badge is allowed to claim, and the disclosure rules that keep
position sizes and account values private by default.

## ADDED Requirements

### Requirement: Verified badge provenance

A trade attachment MUST be labelled `verified` only when it references a fill that either
originated from a Helios-routed order or arrived through a broker synchronisation, and
whose side, instrument, price and execution time are recorded on the attachment at attach
time. Any other trade attachment MUST be labelled `unverified` and MUST be visually
distinguishable.

#### Scenario: Sharing a broker-synced fill

- **WHEN** a user shares a trade backed by a fill received from a connected brokerage
- **THEN** the attachment is labelled verified and records the fill's side, instrument, price and execution time

#### Scenario: Sharing a manually entered trade

- **WHEN** a user shares a trade they entered by hand
- **THEN** the attachment is labelled unverified

#### Scenario: Verification service unavailable at attach time

- **WHEN** verification cannot be completed within its time budget
- **THEN** the post is published with the attachment labelled unverified
- **AND** the system retries verification in the background and may upgrade the label later

### Requirement: Notional and quantity are withheld by default

For any viewer other than the author, the system MUST NOT emit trade quantity, notional
value, position size or account equity for a shared trade or portfolio, unless the author's
profile disclosure is `full` and the specific post sets the reveal-notional flag. Returns
MUST be expressed as percentages computed server-side.

#### Scenario: Default share

- **WHEN** a viewer loads a shared trade from an author whose disclosure is `returns_only`
- **THEN** the response contains entry price, exit price and percentage return
- **AND** the response contains no quantity, notional or equity field

#### Scenario: Author opts into full disclosure for one post

- **WHEN** an author with `full` disclosure publishes a trade share with reveal-notional set
- **THEN** viewers receive the quantity and notional for that post only

#### Scenario: Author has full disclosure but the post does not opt in

- **WHEN** an author with `full` disclosure publishes a trade share without reveal-notional
- **THEN** viewers do not receive quantity or notional

### Requirement: Badge revocation on contradicting data

When subsequently synchronised broker data contradicts a verified attachment — the fill is
cancelled, amended beyond a tolerance, or no longer present — the system MUST revoke the
verified label, notify the author, and record the revocation. The post body MUST NOT be
altered by revocation.

#### Scenario: Fill is busted by the venue

- **WHEN** a broker sync reports that a fill backing a verified share was cancelled
- **THEN** the attachment's verified label is revoked, the author is notified, and the revocation is recorded with a reason
- **AND** the author's original post text is unchanged

### Requirement: Portfolio snapshot shares expose composition, not size

A shared portfolio snapshot SHALL expose holdings as percentage weights of the shared
sleeve and MUST NOT expose absolute values unless full disclosure and reveal-notional both
apply. The snapshot MUST be immutable once shared, carrying the as-of timestamp it was
taken at.

#### Scenario: Sharing a portfolio

- **WHEN** a user shares a portfolio snapshot at `returns_only` disclosure
- **THEN** viewers see each holding's percentage weight and the snapshot's as-of time
- **AND** viewers see no share counts or dollar values

#### Scenario: Portfolio changes after sharing

- **WHEN** the author's holdings change after a snapshot was shared
- **THEN** the shared snapshot continues to show the composition as of its original as-of time

### Requirement: Backtest shares carry their assumptions

A shared backtest tear-sheet MUST include the fee model, slippage assumption, data range,
universe definition and whether the result is in-sample or out-of-sample. A backtest share
missing any of these MUST be rejected.

#### Scenario: Sharing a complete backtest

- **WHEN** a user shares a backtest whose run recorded its fee model, slippage model, date range, universe and sample designation
- **THEN** the share is published and displays those assumptions alongside the equity curve

#### Scenario: Sharing a backtest without a recorded slippage model

- **WHEN** a user attempts to share a backtest run that has no slippage assumption recorded
- **THEN** the share is rejected with an explanation of the missing assumption

### Requirement: Shares are rate limited per author

The system SHALL limit the number of instrument-tagged posts a single author may publish
per rolling 24-hour period, and MUST apply a stricter limit for instruments below a
liquidity threshold.

#### Scenario: Exceeding the small-cap posting limit

- **WHEN** an author publishes posts tagging an instrument whose average daily volume is below the threshold, beyond the permitted count in 24 hours
- **THEN** further such posts are rejected with a rate-limit error until the window rolls
