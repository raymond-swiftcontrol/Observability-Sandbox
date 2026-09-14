/**
 * Alerting, watchlists and notification delivery contracts.
 */
import { z } from 'zod';
import {
  AlertTriggerKind,
  BarInterval,
  NotificationChannel,
  NotificationStatus,
} from './enums.js';
import {
  AccountId,
  InstrumentId,
  Money,
  Price,
  Ratio,
  Timestamp,
  UserId,
} from './primitives.js';

/**
 * Comparators are spelled out rather than taken as a free-text operator because
 * the alert evaluator runs these against a live tick stream and an unparseable
 * rule there is a missed alert, not a validation error a user can see.
 */
export const AlertComparator = z.enum(['above', 'below', 'crosses_above', 'crosses_below']);
export type AlertComparator = z.infer<typeof AlertComparator>;

export const AlertRule = z
  .object({
    id: z.string().uuid(),
    user_id: UserId,
    instrument_id: InstrumentId.nullable().default(null),
    account_id: AccountId.nullable().default(null),
    name: z.string().min(1).max(80),
    trigger_kind: AlertTriggerKind,
    comparator: AlertComparator,
    threshold_price: Price.nullable().default(null),
    threshold_ratio: Ratio.nullable().default(null),
    threshold_money: Money.nullable().default(null),
    /** Indicator alerts need a bar interval; a price alert is tick-driven. */
    interval: BarInterval.nullable().default(null),
    indicator: z.string().max(32).nullable().default(null),
    indicator_params: z.record(z.number()).default({}),
    channels: z.array(NotificationChannel).min(1),
    /** One-shot by default: a repeating price alert is a notification flood. */
    is_repeating: z.boolean().default(false),
    cooldown_seconds: z.number().int().nonnegative().default(0),
    is_active: z.boolean().default(true),
    expires_at: Timestamp.nullable().default(null),
    last_triggered_at: Timestamp.nullable().default(null),
    trigger_count: z.number().int().nonnegative().default(0),
    created_at: Timestamp,
    updated_at: Timestamp,
  })
  .superRefine((r, ctx) => {
    const thresholds = [r.threshold_price, r.threshold_ratio, r.threshold_money].filter(
      (t) => t !== null,
    );
    if (thresholds.length !== 1) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'an alert carries exactly one threshold',
        path: ['threshold_price'],
      });
    }
    if (r.trigger_kind === 'indicator_cross' && (r.indicator === null || r.interval === null)) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'an indicator alert needs both an indicator and a bar interval',
        path: ['indicator'],
      });
    }
    if (r.is_repeating && r.cooldown_seconds === 0) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'a repeating alert needs a non-zero cooldown',
        path: ['cooldown_seconds'],
      });
    }
  });
export type AlertRule = z.infer<typeof AlertRule>;

export const WatchlistItem = z.object({
  instrument_id: InstrumentId,
  display_order: z.number().int().nonnegative().default(0),
  note: z.string().max(200).nullable().default(null),
  added_at: Timestamp,
});
export type WatchlistItem = z.infer<typeof WatchlistItem>;

export const Watchlist = z.object({
  id: z.string().uuid(),
  user_id: UserId,
  name: z.string().min(1).max(60),
  items: z.array(WatchlistItem).default([]),
  is_default: z.boolean().default(false),
  /** Sharing a watchlist is opt-in, like a strategy. */
  is_public: z.boolean().default(false),
  created_at: Timestamp,
  updated_at: Timestamp,
});
export type Watchlist = z.infer<typeof Watchlist>;

export const Notification = z.object({
  id: z.string().uuid(),
  user_id: UserId,
  channel: NotificationChannel,
  status: NotificationStatus,
  /** Dot-separated event key, e.g. `order.filled` — routed on, so it is constrained. */
  topic: z.string().regex(/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/),
  title: z.string().min(1).max(120),
  body: z.string().max(500),
  /**
   * Deep-link target rather than a URL: the mobile client resolves it against
   * its own router, and a server-supplied URL is an open-redirect waiting to be
   * clicked.
   */
  deep_link: z.string().max(200).nullable().default(null),
  data: z.record(z.unknown()).default({}),
  /** Dedupe key: retried delivery of the same event must not double-notify. */
  idempotency_key: z.string().max(128),
  created_at: Timestamp,
  sent_at: Timestamp.nullable().default(null),
  read_at: Timestamp.nullable().default(null),
  failure_reason: z.string().nullable().default(null),
});
export type Notification = z.infer<typeof Notification>;
