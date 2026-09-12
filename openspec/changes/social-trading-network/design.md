# Design — Social Trading Network

## Shape of the change

A new service, `apps/social-service` (TypeScript/NestJS, same conventions as the
gateway), owns the `social` schema and the feed cache. The API gateway does not talk to
the `social` schema directly; it calls the social service over gRPC and stitches results
into its GraphQL schema. This keeps the social write path — which is high-volume,
low-value-per-write, and will need independent scaling — off the trading path, which is
low-volume and must never be slowed down by a feed fan-out.

```
mobile ──GraphQL──▶ api-gateway ──gRPC──▶ social-service ──▶ social schema (Postgres)
                         │                      │
                         │                      ├──▶ Redis (feed cache, counters)
                         │                      └──▶ Kafka social.events.v1
                         └──gRPC──▶ execution-gateway / book (verification lookups)
                                                │
                       notification-worker ◀────┘ social.events.v1
```

## Data model

New schema `social`, migrations `0020`–`0024`:

- `social.profile` — 1:1 with `identity.user`; handle (citext, unique), bio, links,
  `visibility` (`public` | `followers` | `private`), `performance_disclosure`
  (`none` | `returns_only` | `full`), badge flags.
- `social.follow` — `(follower_id, followee_id)` with `state` (`pending` | `active`),
  so private accounts get approve-follow for free.
- `social.block`, `social.mute` — bidirectional enforcement happens in the query layer
  *and* in an RLS policy, because a missed filter in one resolver is a privacy incident.
- `social.post` — author, body, `kind` (`text` | `trade` | `portfolio` | `backtest` |
  `repost`), `parent_post_id` for replies, `repost_of_id`, `group_id`, counters,
  `visibility`, moderation state, `language`, `created_at`.
- `social.post_instrument` — extracted cashtags, `(post_id, instrument_id)`; this is what
  the instrument feed reads.
- `social.post_attachment` — polymorphic, one row per attached artefact: `fill_id`,
  `position_id`, `backtest_id`, or `media_key`. Verification is resolved at attach time
  and the verdict is **stored on the row**, not recomputed on read, so a later broker
  disconnect does not retroactively un-verify history.
- `social.reaction`, `social.bookmark`, `social.repost` — `(post_id, user_id)` keyed.
- `social.group`, `social.group_member` — roles `owner` | `moderator` | `member`.
- `social.conversation`, `social.conversation_member`, `social.message` — DMs; messages
  are a hypertable because volume is time-series shaped and old threads compress well.
- `social.report`, `social.moderation_action`, `social.appeal` — the moderation trail.
- `social.author_stats` — materialised per-author engagement and track-record metrics,
  refreshed by a scheduled job; feeds ranking and leaderboards.

Every user-scoped table gets an RLS policy keyed on `platform.current_user_id()`.

## Feed composition

Hybrid fan-out. Pure fan-out-on-write collapses when an author with 200k followers posts;
pure fan-out-on-read collapses when a user follows 2k accounts.

- Authors below the `FEED_FANOUT_FOLLOWER_CEILING` (default 5,000) fan out on write: a
  Kafka consumer pushes the post id into each follower's Redis sorted set
  (`feed:{user_id}`, score = ranking score, capped at 800 entries).
- Authors above the ceiling are **not** fanned out. They are pulled at read time from a
  per-author timeline cache and merged into the ranked result.
- A cold or evicted feed is rebuilt from Postgres on demand; the cache is an
  optimisation, never the source of truth. `GET /feed` must be correct with Redis empty.

Ranking score, computed at fan-out and refreshed on a cadence:

```
score = w_recency · decay(age, half_life=6h)
      + w_affinity · affinity(viewer, author)      -- past engagement, mutual follow
      + w_quality  · author_quality                -- track record length, report rate
      + w_engage   · log1p(replies + 2·reposts + 0.5·reactions)
      + w_rationale · has_written_rationale         -- deliberate thumb on the scale
      - p_repetition · same_author_same_instrument_24h
      - p_reported   · open_report_pressure
```

Weights live in `platform.feature_flag` so they are tunable without a deploy, and every
scored feed request emits the component breakdown as span attributes — we will not be able
to debug "why is my feed bad" without that.

## Verification

A trade attachment is verified when the referenced `oms.fill` either (a) came from a
Helios-routed order, or (b) arrived through a broker sync whose connection was healthy at
the time, and the fill's `instrument_id`, `price`, `executed_at` and `side` are echoed
into the attachment row. The attachment stores `verification_method` and
`verified_at`. Quantity and notional are stored but are stripped by the serialiser unless
the author's `performance_disclosure` is `full` **and** the post sets `reveal_notional`.

Returns on a shared trade are computed from the fill and the current or closing mark, as a
percentage, server-side. The client never receives the inputs it would need to back out
position size.

## Kafka topics

- `social.events.v1` — post created/edited/deleted, follow, reaction, report. Keyed by
  author id for ordering. Consumed by the fan-out worker, the notification worker, and the
  analytics sink.
- `social.moderation.v1` — moderation decisions; separate topic because its retention is
  years, not days, and access is restricted.

## Failure modes

| Failure | Behaviour |
| --- | --- |
| Redis unavailable | Feeds served from Postgres with a higher latency budget; a metric marks degraded mode. No errors surface to the user. |
| Fan-out consumer lags | Posts still appear in the author's own timeline and in read-time merge; the ranked feed goes stale, bounded by consumer lag, which is alerted at 60s. |
| Verification lookup times out | The post is created **unverified** rather than blocked. A background job retries and upgrades the badge. Never claim verified on a timeout. |
| Broker sync later reveals a fill was amended | The attachment is re-verified by the amendment handler; if the fill no longer supports the claim, the badge is revoked and the author notified. The post body is untouched — we do not silently rewrite what someone said. |
| Moderation queue backs up | Auto-shadow-limit thresholds tighten automatically; the queue depth is an SLO with a page. |

## Observability

- Spans: `social.post.create` (with attachment verification as a child span),
  `social.feed.compose` (with `cache_hit`, `candidate_count`, `ranking_ms` attributes),
  `social.fanout.deliver`.
- Metrics: `social_feed_compose_duration_seconds` (histogram, by cache state),
  `social_fanout_lag_seconds`, `social_posts_created_total{kind,verified}`,
  `social_reports_open`, `social_moderation_queue_age_seconds`,
  `social_verification_failures_total{reason}`.
- Logs: every moderation action and every badge revocation, at info, with actor and reason.

## Alternatives considered

- **Put social in the API gateway.** Rejected: couples feed fan-out scaling to the
  trading path, and a social incident would then degrade order entry.
- **Graph database for the follow graph.** Rejected: the access patterns are one- and
  two-hop, which Postgres handles fine at our scale, and it would add an operational
  dependency for no current benefit. Revisit past ~50M edges.
- **Recompute verification on every read.** Rejected: makes read latency depend on broker
  availability and lets history change under the reader.
