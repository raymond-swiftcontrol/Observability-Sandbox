## Purpose

Defines how abusive, manipulative and spam content is reported, reviewed and acted on, and
the guarantees that users get about transparency and appeal.

## ADDED Requirements

### Requirement: Any user can report a post, profile or message

The system SHALL accept reports against a post, a profile or a direct message, with a
category and optional free text. A report MUST be acknowledged to the reporter and MUST NOT
reveal the reporter's identity to the reported user.

#### Scenario: Reporting a post

- **WHEN** a user reports a post for market manipulation
- **THEN** the report is recorded with category and reporter, enters the review queue, and the reporter receives an acknowledgement

#### Scenario: Reported user views the post

- **WHEN** the reported user views their own post after it is reported
- **THEN** no reporter identity is disclosed to them

### Requirement: Automated shadow-limiting precedes removal

When automated detection flags content as likely manipulation or spam, the system MUST
first reduce its distribution rather than delete it, and MUST queue it for human review.
Irreversible removal MUST require either a human decision or an explicit automated rule
category designated for immediate removal.

#### Scenario: Coordinated small-cap promotion detected

- **WHEN** detection identifies several accounts posting the same illiquid instrument within a short window
- **THEN** those posts are shadow-limited, remain visible on their authors' own timelines, and are queued for review

#### Scenario: Human reviewer clears flagged content

- **WHEN** a reviewer clears shadow-limited content
- **THEN** normal distribution resumes and the ranking penalty is lifted

### Requirement: Moderation actions are recorded and appealable

Every moderation action MUST record the actor, the reason, the rule applied and a
timestamp. A user subject to an action MUST be notified with the reason category and MUST
be able to submit one appeal per action.

#### Scenario: Content removed

- **WHEN** a reviewer removes a post
- **THEN** the action is recorded with actor, rule and reason, and the author is notified with the reason category and an appeal option

#### Scenario: Second appeal on the same action

- **WHEN** a user submits a second appeal for an action they already appealed
- **THEN** the request is rejected and the original appeal's status is returned

### Requirement: Moderation queue depth is an operational signal

The system SHALL expose the count and age of unreviewed reports as metrics, and MUST
tighten automated shadow-limiting thresholds when the oldest unreviewed report exceeds a
configured age.

#### Scenario: Queue ages past the threshold

- **WHEN** the oldest unreviewed report exceeds the configured age threshold
- **THEN** automated shadow-limit thresholds tighten and the condition is exposed as an alertable metric

### Requirement: Financial-advice guardrail

The system MUST NOT generate, rank or surface recommendations to buy or sell a specific
instrument. Ranking MAY order authors and posts; it MUST NOT order instruments by
attractiveness, and no surface may present an instrument list framed as suggested trades.

#### Scenario: Discovery surface composition

- **WHEN** a user opens the discovery surface
- **THEN** it presents authors and posts
- **AND** it presents no instrument ranking framed as a recommendation to trade
