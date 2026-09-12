## Purpose

Defines what a trader sees when they open the feed: which posts are eligible, how they are
ordered, and the correctness guarantees the feed must hold when its caches are cold,
stale or unavailable.

## ADDED Requirements

### Requirement: Feed eligibility

A post SHALL appear in a viewer's home feed only if all of the following hold: the author
is actively followed by the viewer or the post is in a group the viewer belongs to; no
block exists in either direction; the author is not muted by the viewer; the post's
visibility permits the viewer; and the post is not removed or pending moderation review.

#### Scenario: Post from a followed author

- **WHEN** a followed, unmuted, unblocked author publishes a public post
- **THEN** the post is eligible for the viewer's home feed

#### Scenario: Post under moderation review

- **WHEN** a post from a followed author is pending moderation review
- **THEN** the post does not appear in any viewer's feed except the author's own timeline

#### Scenario: Followers-only post from a non-followed author

- **WHEN** an author the viewer does not follow publishes a followers-only post
- **THEN** the post is not eligible for that viewer's feed even via an instrument feed

### Requirement: Feed correctness is independent of cache state

The home feed MUST return a correct, complete and correctly ordered result when the feed
cache is empty, partially populated or unavailable. Cache state MAY affect latency only.

#### Scenario: Cache unavailable

- **WHEN** the feed cache is unreachable and a viewer requests their home feed
- **THEN** the feed is served from the primary store with the same eligibility and ordering rules
- **AND** a degraded-mode metric is incremented
- **AND** no error is surfaced to the viewer

#### Scenario: Cold cache for a new follow

- **WHEN** a viewer follows a new author whose posts were never fanned out to them
- **THEN** that author's eligible existing posts are available in the viewer's feed on the next request

### Requirement: Ranked and chronological feeds are both available

The system SHALL offer a ranked home feed and a strictly reverse-chronological feed over
the same eligible post set. The viewer's choice MUST persist across sessions and devices.

#### Scenario: Switching to chronological

- **WHEN** a viewer selects the chronological feed
- **THEN** posts are returned strictly newest-first with no ranking applied
- **AND** the same selection is in effect when the viewer opens the app on another device

### Requirement: Ranking penalises repetition and rewards rationale

Feed ranking MUST reduce the score of a post when the same author has already published a
post tagging the same instrument within the preceding 24 hours, and MUST increase the score
of a post that contains written rationale beyond the attached artefact.

#### Scenario: Third post on the same ticker in a day

- **WHEN** an author publishes a third post tagging `$TSLA` within 24 hours
- **THEN** that post ranks below an otherwise equivalent first-of-day post from the same author

#### Scenario: Bare trade share versus trade share with rationale

- **WHEN** two authors of equal affinity and recency share a trade, one with 200 characters of rationale and one with none
- **THEN** the post with rationale ranks higher

### Requirement: Instrument feeds

For any instrument, the system SHALL provide a feed of posts tagging that instrument,
restricted to posts the viewer is permitted to see. Cashtags MUST resolve to instruments
by the symbol that was active at the time of posting.

#### Scenario: Cashtag on a renamed ticker

- **WHEN** a post from 2023 tags `$FB` and the instrument's current symbol is `META`
- **THEN** that post appears in the instrument feed for the META instrument

#### Scenario: Unresolvable cashtag

- **WHEN** a post tags `$NOTAREALTICKER`
- **THEN** the post is published with the cashtag rendered as plain text and no instrument association

### Requirement: Pagination is stable under insertion

Feed pagination MUST use a cursor such that a post inserted during pagination does not
cause an already-returned post to be returned again on a subsequent page.

#### Scenario: New post arrives mid-pagination

- **WHEN** a viewer fetches page 1, a followed author then publishes, and the viewer fetches page 2 with the returned cursor
- **THEN** page 2 contains no post that appeared on page 1
