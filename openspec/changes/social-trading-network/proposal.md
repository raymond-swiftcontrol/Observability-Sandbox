# Social Trading Network

Traders currently get a private, single-player experience: they research, backtest and
trade alone. This change gives Helios a social layer so a trader can follow people whose
process they respect, see what those people actually did (not what they claim), and
discuss it — without anyone having to expose their net worth. The outcome we want is that
a new user who has linked a brokerage can, within one session, follow five traders, see a
ranked feed of their verified activity, and post their own trade with a one-tap share from
the position screen.

The differentiator is **verification**. Public investing discourse is dominated by
unfalsifiable claims. Because Helios already holds broker-synced fills and positions, a
shared trade can carry a "broker-verified" badge proving the trade happened, at that price,
at that time — while still disclosing only percentage returns unless the author explicitly
opts to reveal notionals.

## Why now

- Broker connectivity (`broker-connectivity-sync`) produces the verified fill and position
  data that makes verified sharing possible. Without it this is just another forum.
- Retention on a solo research tool is weak; a follow graph is the strongest retention
  mechanism available to us and it compounds.
- The risk is reputational, not technical: a social layer that leaks position sizes or
  amplifies pump-and-dump behaviour is worse than no social layer. Designing the privacy
  and moderation model now, while the graph is empty, is far cheaper than retrofitting it.

## What ships

- **Profiles** with a handle, bio, optional verified-performance strip (time-weighted
  return over selectable windows, max drawdown, win rate), and follower counts.
- **Follow graph**: asymmetric follows, mutes, blocks, private accounts with
  approve-follow requests.
- **Feed**: a ranked home feed from follows plus a chronological "latest" feed, an
  instrument feed (everything tagged `$AAPL`), and a discovery feed of high-signal authors.
- **Posts**: text up to 2,000 characters with `$CASHTAG` instrument tagging, images,
  attached trades, attached portfolio snapshots, and attached backtest tear-sheets.
- **Verified trade shares**: a share created from a real fill carries a badge and an
  immutable reference to the fill; entry/exit prices and percentage return are shown,
  quantity and notional are hidden unless opted in.
- **Engagement**: replies (one level of threading), reactions, reposts with optional
  commentary, bookmarks.
- **Groups**: invite-or-open communities with their own feed and an owner-moderated
  member list.
- **Direct messages**: 1:1 and small group threads, with a request inbox for non-followers.
- **Leaderboards**: opt-in only, ranked on risk-adjusted return over a fixed window, with
  a minimum track-record length so a single lucky month cannot top the table.
- **Moderation**: user reports, an operator review queue, automated rules for
  pump-and-dump patterns and spam, shadow-limiting, and an appeal path.

## Non-goals

- **Copy trading / auto-following trades.** Routing a follower's capital from a leader's
  signal is a regulated advisory activity in most jurisdictions. Out of scope here; a
  separate change will evaluate it with legal input.
- **Paid subscriptions to authors.** No monetisation in this change.
- **Public chat rooms / live audio.** Real-time rooms need their own moderation capacity.
- **Cross-posting to external networks.** Deferred.
- **Recommending securities.** Helios ranks authors by engagement and track record; it
  never ranks or suggests instruments to buy.

## Capabilities

- `social-graph` — profiles, follows, blocks, mutes, privacy.
- `social-feed` — feed composition, ranking, instrument and group feeds.
- `trade-sharing` — verified trade and portfolio attachments, disclosure controls.
- `social-moderation` — reporting, review queue, automated abuse detection, appeals.

## Risks and how we hold them

| Risk | Mitigation |
| --- | --- |
| Position sizes or account values leak | Disclosure is a per-share decision, defaulting to percentage-only. Notional fields are stripped server-side in the serialiser, not hidden in the client. |
| Coordinated pump-and-dump | Detection on co-ordinated posting of illiquid small caps; shadow-limit before removal; a rate limit on cashtag posts per author per day. |
| Verified badge becomes meaningless | A badge is only issued when the referenced fill came from a broker sync or a Helios-routed order. Manually entered trades can be shared but are explicitly labelled unverified. |
| Feed becomes a performance-bragging monoculture | Ranking penalises repeated single-name return posts from the same author and rewards posts with written rationale. |
| Harassment via DMs | Non-followers land in a request inbox; blocks are bidirectional and immediate. |
