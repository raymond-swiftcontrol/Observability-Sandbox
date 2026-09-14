/**
 * Social layer contracts — from `openspec/changes/social-trading-network`.
 *
 * Two of the spec's guarantees are encoded structurally rather than left to a
 * service to remember:
 *
 *  - A trade attachment's verification verdict is a stored field captured at
 *    attach time along with the facts it attests to (side, instrument, price,
 *    execution time). A verdict computed at read time would be a claim about
 *    data that may since have changed.
 *  - Quantity and notional never appear on the viewer-facing post shapes at all.
 *    They live on the author-only attachment detail, and reach a viewer only
 *    through `serializeForDisclosure` in `./disclosure.js`, which is an
 *    allowlist.
 */
import { z } from 'zod';
import {
  AttachmentKind,
  FollowState,
  ModerationState,
  PerformanceDisclosure,
  PostKind,
  PostVisibility,
  ProfileVisibility,
  ReactionKind,
  ReportCategory,
  ReportState,
  ReportTargetKind,
  Side,
  VerificationMethod,
  VerificationVerdict,
} from './enums.js';
import {
  BacktestId,
  FillId,
  InstrumentId,
  Money,
  PostId,
  Price,
  Quantity,
  Ratio,
  StrategyId,
  Timestamp,
  UserId,
  Weight,
} from './primitives.js';

/**
 * Case-insensitively unique, 3-24 characters. Stored lowercased; the display
 * form is `display_handle`, so `QuantKid` and `quantkid` cannot both exist.
 */
export const Handle = z
  .string()
  .min(3)
  .max(24)
  .regex(/^[A-Za-z0-9_]+$/, 'handles are letters, digits and underscores')
  .brand<'Handle'>();
export type Handle = z.infer<typeof Handle>;

export const normalizeHandle = (raw: string): string => raw.trim().toLowerCase();

export const Profile = z.object({
  user_id: UserId,
  handle: Handle,
  display_name: z.string().min(1).max(60),
  bio: z.string().max(280).nullable().default(null),
  avatar_url: z.string().url().nullable().default(null),
  visibility: ProfileVisibility.default('public'),
  /**
   * The privacy dial the whole disclosure serializer keys off. Defaults to
   * `none` so a profile that has never been configured leaks nothing.
   */
  performance_disclosure: PerformanceDisclosure.default('none'),
  is_verified_identity: z.boolean().default(false),
  follower_count: z.number().int().nonnegative().default(0),
  following_count: z.number().int().nonnegative().default(0),
  post_count: z.number().int().nonnegative().default(0),
  created_at: Timestamp,
  updated_at: Timestamp,
  handle_released_at: Timestamp.nullable().default(null),
});
export type Profile = z.infer<typeof Profile>;

/**
 * Percentages and ratios only. Absolute amounts are deliberately absent from the
 * type, so `returns_only` is expressible without a filtering step, and `full`
 * disclosure carries its amounts on a separate object.
 */
export const ProfilePerformance = z.object({
  time_weighted_return_1m: Ratio.nullable().default(null),
  time_weighted_return_3m: Ratio.nullable().default(null),
  time_weighted_return_1y: Ratio.nullable().default(null),
  time_weighted_return_itd: Ratio.nullable().default(null),
  max_drawdown: Ratio.nullable().default(null),
  win_rate: Ratio.nullable().default(null),
  sharpe: Ratio.nullable().default(null),
  volatility_annualised: Ratio.nullable().default(null),
  trade_count: z.number().int().nonnegative().default(0),
  as_of: Timestamp,
});
export type ProfilePerformance = z.infer<typeof ProfilePerformance>;

/** The `full`-disclosure extension. Never merged into `ProfilePerformance`. */
export const ProfilePerformanceAmounts = z.object({
  equity: Money,
  gross_exposure: Money,
  realized_pnl_ytd: Money,
});
export type ProfilePerformanceAmounts = z.infer<typeof ProfilePerformanceAmounts>;

/**
 * What `verified` is allowed to claim, recorded at attach time. The facts are
 * copied rather than referenced: the spec requires that a later revocation must
 * not alter the post, which means the post cannot be a live view of the fill.
 */
export const TradeVerification = z.object({
  verdict: VerificationVerdict,
  method: VerificationMethod.nullable().default(null),
  fill_id: FillId.nullable().default(null),
  verified_at: Timestamp.nullable().default(null),
  revoked_at: Timestamp.nullable().default(null),
  revocation_reason: z.string().max(200).nullable().default(null),
});
export type TradeVerification = z.infer<typeof TradeVerification>;

/** One holding of a shared portfolio snapshot: weight, never size. */
export const PortfolioSnapshotHolding = z.object({
  instrument_id: InstrumentId,
  weight: Weight,
  return_since_entry: Ratio.nullable().default(null),
});
export type PortfolioSnapshotHolding = z.infer<typeof PortfolioSnapshotHolding>;

/**
 * Attachment payloads by kind. `quantity` and `notional` are present on the
 * trade payload because the author is entitled to see them; reaching a viewer
 * requires `full` disclosure *and* the post's reveal-notional flag, and that
 * decision is made in one place — see `./disclosure.js`.
 */
export const TradeAttachmentPayload = z.object({
  instrument_id: InstrumentId,
  side: Side,
  entry_price: Price,
  exit_price: Price.nullable().default(null),
  return_pct: Ratio.nullable().default(null),
  executed_at: Timestamp,
  closed_at: Timestamp.nullable().default(null),
  quantity: Quantity.nullable().default(null),
  notional: Money.nullable().default(null),
});
export type TradeAttachmentPayload = z.infer<typeof TradeAttachmentPayload>;

export const PortfolioAttachmentPayload = z.object({
  /** Immutable once shared, hence the explicit as-of rather than a live read. */
  as_of: Timestamp,
  holdings: z.array(PortfolioSnapshotHolding).min(1),
  period_return: Ratio.nullable().default(null),
  equity: Money.nullable().default(null),
});
export type PortfolioAttachmentPayload = z.infer<typeof PortfolioAttachmentPayload>;

export const BacktestAttachmentPayload = z.object({
  backtest_id: BacktestId,
  strategy_id: StrategyId.nullable().default(null),
  /**
   * The assumptions are required, not optional: the spec rejects a backtest
   * share missing any of them, and a nullable field here would push that check
   * into whichever service happened to remember it.
   */
  fee_model: z.string().min(1).max(64),
  slippage_model: z.string().min(1).max(64),
  start_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  end_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  universe_definition: z.record(z.unknown()),
  sample: z.enum(['in_sample', 'out_of_sample', 'walk_forward']),
  total_return: Ratio,
  max_drawdown: Ratio,
  sharpe: Ratio.nullable().default(null),
});
export type BacktestAttachmentPayload = z.infer<typeof BacktestAttachmentPayload>;

export const PostAttachment = z
  .object({
    id: z.string().uuid(),
    post_id: PostId,
    kind: AttachmentKind,
    verification: TradeVerification,
    trade: TradeAttachmentPayload.nullable().default(null),
    portfolio: PortfolioAttachmentPayload.nullable().default(null),
    backtest: BacktestAttachmentPayload.nullable().default(null),
    media_url: z.string().url().nullable().default(null),
    created_at: Timestamp,
  })
  .superRefine((a, ctx) => {
    const present = {
      trade: a.trade !== null,
      position: a.trade !== null,
      portfolio: a.portfolio !== null,
      backtest: a.backtest !== null,
      media: a.media_url !== null,
    }[a.kind];
    if (!present) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: `a ${a.kind} attachment must carry its ${a.kind} payload`,
        path: ['kind'],
      });
    }
    // Verified is a claim about a specific fill. Without one there is nothing
    // to have verified, and the spec's timeout path must produce 'unverified'.
    if (a.verification.verdict === 'verified' && a.verification.fill_id === null) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'a verified attachment must reference the fill it attests to',
        path: ['verification', 'fill_id'],
      });
    }
    if (a.verification.verdict === 'revoked' && a.verification.revocation_reason === null) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'a revocation must record its reason',
        path: ['verification', 'revocation_reason'],
      });
    }
  });
export type PostAttachment = z.infer<typeof PostAttachment>;

export const Post = z.object({
  id: PostId,
  author_user_id: UserId,
  kind: PostKind,
  visibility: PostVisibility.default('public'),
  body: z.string().max(2000),
  /**
   * Per-post opt-in. Full disclosure on the profile is necessary but not
   * sufficient — the author must also say so for this post.
   */
  reveal_notional: z.boolean().default(false),
  instrument_ids: z.array(InstrumentId).max(8).default([]),
  attachments: z.array(PostAttachment).max(4).default([]),
  reply_to_post_id: PostId.nullable().default(null),
  repost_of_post_id: PostId.nullable().default(null),
  moderation_state: ModerationState.default('ok'),
  reaction_counts: z.record(ReactionKind, z.number().int().nonnegative()).default({}),
  reply_count: z.number().int().nonnegative().default(0),
  created_at: Timestamp,
  edited_at: Timestamp.nullable().default(null),
  deleted_at: Timestamp.nullable().default(null),
});
export type Post = z.infer<typeof Post>;

/**
 * Follows are asymmetric and, against a private profile, start `pending`. A
 * pending follow grants nothing — the feed query must filter on `state`, which
 * is why the state is on the edge rather than implied by the edge's existence.
 */
export const Follow = z.object({
  follower_user_id: UserId,
  followee_user_id: UserId,
  state: FollowState,
  requested_at: Timestamp,
  activated_at: Timestamp.nullable().default(null),
  /** A mute suppresses delivery without severing the follow. */
  is_muted: z.boolean().default(false),
});
export type Follow = z.infer<typeof Follow>;

/**
 * Blocks are bidirectional in effect and are never disclosed to the blocked
 * user, so the API returns not-found rather than forbidden for a blocked action.
 */
export const Block = z.object({
  blocker_user_id: UserId,
  blocked_user_id: UserId,
  created_at: Timestamp,
});
export type Block = z.infer<typeof Block>;

export const Reaction = z.object({
  post_id: PostId,
  user_id: UserId,
  kind: ReactionKind,
  created_at: Timestamp,
});
export type Reaction = z.infer<typeof Reaction>;

export const Report = z.object({
  id: z.string().uuid(),
  target_kind: ReportTargetKind,
  target_id: z.string().min(1),
  /** Held server-side and never returned to the reported user. */
  reporter_user_id: UserId,
  category: ReportCategory,
  detail: z.string().max(1000).nullable().default(null),
  state: ReportState.default('open'),
  resolution_note: z.string().max(1000).nullable().default(null),
  reviewed_by_user_id: UserId.nullable().default(null),
  created_at: Timestamp,
  reviewed_at: Timestamp.nullable().default(null),
});
export type Report = z.infer<typeof Report>;

/**
 * A moderation action is recorded with actor, rule and reason so it can be
 * appealed. `appeal_count` is capped at one by the spec, and is a counter rather
 * than a boolean so a second attempt can be answered with the first appeal.
 */
export const ModerationAction = z.object({
  id: z.string().uuid(),
  target_kind: ReportTargetKind,
  target_id: z.string().min(1),
  from_state: ModerationState,
  to_state: ModerationState,
  actor_user_id: UserId.nullable().default(null),
  is_automated: z.boolean().default(false),
  rule: z.string().max(64),
  reason_category: z.string().max(64),
  reason_detail: z.string().max(1000).nullable().default(null),
  appeal_count: z.number().int().min(0).max(1).default(0),
  created_at: Timestamp,
});
export type ModerationAction = z.infer<typeof ModerationAction>;

/** How the current viewer stands relative to an author. Drives disclosure. */
export const ViewerRelationship = z.enum(['self', 'follower', 'stranger', 'blocked']);
export type ViewerRelationship = z.infer<typeof ViewerRelationship>;
