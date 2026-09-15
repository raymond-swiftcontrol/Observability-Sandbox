# Tasks — Social Trading Network

## 1. Schema foundations

- [x] 1.1 Migration `0020_social_graph.sql`: `social.profile`, `social.handle_release`,
      `social.follow`, `social.block`, `social.mute`; handle uniqueness as a case-insensitive
      unique index; 30-day handle release enforced by a check against `handle_release`.
- [x] 1.2 Migration `0021_social_content.sql`: `social.post`, `social.post_instrument`,
      `social.post_attachment`, `social.reaction`, `social.bookmark`, `social.repost`;
      counter columns plus the triggers that maintain them.
- [x] 1.3 Migration `0022_social_groups_dm.sql`: `social.group`, `social.group_member`,
      `social.conversation`, `social.conversation_member`, `social.message` (hypertable,
      compression after 30 days).
- [x] 1.4 Migration `0023_social_moderation.sql`: `social.report`,
      `social.moderation_action`, `social.appeal`, `social.detection_signal`.
- [x] 1.5 Migration `0024_social_rls.sql`: RLS policies on every user-scoped social table,
      including the bidirectional block filter. Add the pgTAP-style assertions that prove a
      blocked user cannot select the blocker's rows.
- [ ] 1.6 Seed data: 40 demo profiles with varied disclosure levels, a follow graph with a
      high-follower author to exercise the read-time merge path, and 300 posts.

## 2. Social service

- [ ] 2.1 Scaffold `apps/social-service` (NestJS, gRPC server, OTel bootstrap from
      `@helios/observability`, health + readiness endpoints, Dockerfile).
- [ ] 2.2 Profile module: create/update, handle claim with collision and release rules,
      disclosure level enforcement in the serialiser (not the resolver).
- [ ] 2.3 Graph module: follow/unfollow, approve/deny requests, block, mute; emit
      `social.events.v1`.
- [ ] 2.4 Post module: create/edit/delete, cashtag extraction with point-in-time symbol
      resolution via `reference.resolve_symbol`, reply threading, repost.
- [ ] 2.5 Attachment + verification module: resolve a fill or position to a verification
      verdict, store the verdict, strip notional fields per disclosure rules, handle the
      timeout-means-unverified path.
- [ ] 2.6 Engagement module: reactions, bookmarks, counter maintenance, idempotent toggles.
- [ ] 2.7 Groups module: create, join/invite, role changes, group feed scoping.
- [ ] 2.8 DM module: conversation creation, request inbox for non-followers, block
      enforcement, read receipts.

## 3. Feed

- [ ] 3.1 Ranking function as a pure, unit-testable module with weights read from
      `platform.feature_flag`; emit the component breakdown as span attributes.
- [ ] 3.2 Fan-out worker: Kafka consumer writing to `feed:{user_id}` Redis sorted sets,
      capped, skipping authors above the follower ceiling.
- [ ] 3.3 Read-time merge for high-follower authors plus the Postgres fallback path that
      makes the feed correct with Redis empty.
- [ ] 3.4 Cursor pagination that is stable under insertion (composite score + post id cursor).
- [ ] 3.5 Instrument feed and discovery feed queries.
- [ ] 3.6 `social.author_stats` refresh job feeding ranking and leaderboards.
- [ ] 3.7 Opt-in leaderboard with a minimum track-record length and risk-adjusted ordering.

## 4. Moderation

- [ ] 4.1 Report intake, dedupe per reporter per target, acknowledgement.
- [ ] 4.2 Detection rules: coordinated-posting, cashtag flooding, liquidity-aware
      small-cap limits, link spam. Each rule independently testable against fixtures.
- [ ] 4.3 Shadow-limit mechanism wired into ranking; reviewer clear/remove actions.
- [ ] 4.4 Appeal submission and single-appeal enforcement.
- [ ] 4.5 Queue-depth driven threshold tightening, plus the metrics and alert rules.
- [ ] 4.6 Operator review queue UI in `apps/web-console`.

## 5. API gateway integration

- [ ] 5.1 GraphQL types, queries and mutations for profiles, feed, posts, engagement,
      groups, DMs; DataLoader batching for author hydration.
- [ ] 5.2 WS subscriptions: new post in feed, new reply, new DM, badge revoked.
- [ ] 5.3 Rate limits per mutation class; stricter limits on instrument-tagged posts.
- [ ] 5.4 Contract tests between gateway and social service.

## 6. Mobile

- [ ] 6.1 Feed screen: ranked/chronological toggle, infinite scroll on the stable cursor,
      pull-to-refresh, optimistic reactions.
- [ ] 6.2 Post composer: cashtag autocomplete, attachment picker (trade, position,
      backtest), disclosure toggle with an explicit warning when revealing notionals.
- [ ] 6.3 One-tap "share this trade" from the position and order-detail screens.
- [ ] 6.4 Profile screen with the verified-performance strip and follow/unfollow states
      including pending.
- [ ] 6.5 Post detail with threaded replies; report and block actions.
- [ ] 6.6 Groups and DM screens, request inbox.
- [ ] 6.7 Leaderboard screen with the opt-in explainer.

## 7. Notifications

- [ ] 7.1 Consume `social.events.v1` in the notification worker: new follower, follow
      request, reply, reaction milestone, badge revoked, moderation action.
- [ ] 7.2 Per-category notification preferences and a digest path for low-urgency events.

## 8. Verification and hardening

- [ ] 8.1 Unit tests for every spec scenario in the four capability specs.
- [ ] 8.2 Privacy regression suite: for each disclosure level and viewer relationship,
      assert the serialised payload contains no withheld field. This suite is the thing
      that stops a leak, so it asserts on the wire format, not on the service return value.
- [ ] 8.3 Load test: feed composition at 2k follows and a 200k-follower author.
- [ ] 8.4 Security review: IDOR on post/profile/message ids, RLS bypass attempts, cashtag
      injection, media upload content-type enforcement, DM access across blocks.
- [ ] 8.5 Grafana dashboard for the social service and the SLO alert rules.
- [ ] 8.6 Update `docs/ARCHITECTURE.md` and add an ADR for the hybrid fan-out decision.
