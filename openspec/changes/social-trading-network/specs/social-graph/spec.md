## Purpose

Defines how traders present themselves on Helios and how the follow, mute and block
relationships between them behave, including the privacy guarantees that hold when an
account is private or a performance disclosure is restricted.

## ADDED Requirements

### Requirement: Profile creation and handle uniqueness

Every user SHALL have exactly one social profile. A profile MUST carry a handle that is
unique case-insensitively across all profiles, between 3 and 24 characters, composed of
letters, digits and underscores. Handles MUST NOT be reassignable to another user within
30 days of being released.

#### Scenario: Claiming an available handle

- **WHEN** a user with no profile requests the handle `quantkid`
- **THEN** the profile is created with handle `quantkid` and default visibility `public`

#### Scenario: Handle collision differing only by case

- **WHEN** a user requests the handle `QuantKid` and another profile already holds `quantkid`
- **THEN** the request is rejected with a handle-unavailable error and no profile is created

#### Scenario: Recently released handle

- **WHEN** a user requests a handle that another user released 10 days ago
- **THEN** the request is rejected until 30 days have elapsed since release

### Requirement: Performance disclosure control

A profile SHALL declare a performance disclosure level of `none`, `returns_only` or
`full`. The system MUST NOT emit account equity, position quantity or trade notional to
any viewer other than the profile owner unless the level is `full`. At `returns_only`,
percentage returns and risk statistics MAY be emitted. At `none`, no performance data of
any kind may be emitted.

#### Scenario: Viewer requests performance of a returns_only profile

- **WHEN** a viewer fetches the profile of a user whose disclosure is `returns_only`
- **THEN** the response contains time-weighted return, max drawdown and win rate
- **AND** the response contains no equity, notional or quantity fields

#### Scenario: Viewer requests performance of a none profile

- **WHEN** a viewer fetches the profile of a user whose disclosure is `none`
- **THEN** the response omits the performance section entirely

#### Scenario: Owner views their own profile

- **WHEN** the profile owner fetches their own profile at any disclosure level
- **THEN** the response contains the full performance detail including notional values

### Requirement: Asymmetric follows with approval for private accounts

Follows SHALL be asymmetric. Following a `public` profile MUST take effect immediately.
Following a `private` profile MUST create a pending request that only becomes active when
the followee approves it. A pending request MUST NOT grant access to any content the
profile restricts to followers.

#### Scenario: Following a public profile

- **WHEN** a user follows a public profile
- **THEN** the follow becomes active immediately and the followee's posts become eligible for the follower's feed

#### Scenario: Following a private profile

- **WHEN** a user follows a private profile
- **THEN** a pending follow request is created
- **AND** the requester's feed contains none of the followee's posts
- **AND** the followee receives a follow-request notification

#### Scenario: Approving a pending request

- **WHEN** a followee approves a pending follow request
- **THEN** the follow becomes active and the follower's feed begins including the followee's eligible posts

### Requirement: Blocks are bidirectional and immediate

When user A blocks user B, the system MUST immediately remove any follow relationship in
either direction, hide A's content from B and B's content from A, prevent new follows in
either direction, and prevent direct messages in either direction. A block MUST NOT
notify the blocked user.

#### Scenario: Blocking an existing follower

- **WHEN** A blocks B while B follows A
- **THEN** the follow is deleted, B cannot see A's posts or profile performance, and B receives no notification of the block

#### Scenario: Blocked user attempts to follow

- **WHEN** B attempts to follow A after being blocked
- **THEN** the request fails with a not-found error rather than a blocked error, so block status is not disclosed

### Requirement: Mutes suppress delivery without severing the follow

A mute SHALL remove the muted author's posts from the muter's feeds and notifications
while leaving the follow relationship intact and leaving the muted user's own view
unchanged.

#### Scenario: Muting a followed author

- **WHEN** a user mutes an author they follow and then loads their feed
- **THEN** no posts from that author appear in the feed
- **AND** the follow relationship still exists and is still visible to the author

### Requirement: Follower counts exclude pending and blocked relationships

Published follower and following counts MUST count only active follows and MUST exclude
relationships involving a block in either direction.

#### Scenario: Count after a block

- **WHEN** an account with 10 followers blocks one of them
- **THEN** the published follower count becomes 9
