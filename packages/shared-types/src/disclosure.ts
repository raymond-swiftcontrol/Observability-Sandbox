/**
 * The disclosure-stripping serializer.
 *
 * This is a privacy control, not a formatting convenience. The social-graph and
 * trade-sharing specs both state the rule negatively — the system MUST NOT emit
 * account equity, position quantity or trade notional unless disclosure is
 * `full` — and a blocklist is the wrong shape for a MUST NOT: it fails open. Add
 * `gross_notional` to a schema next quarter, forget to add it to the blocklist,
 * and every viewer of every post sees it, silently and retroactively.
 *
 * So the implementation is an allowlist over field *names*, deny by default: a
 * key that is not classified is dropped, whatever it holds. The failure mode of
 * a forgotten field is a missing number in the UI, which someone notices in a
 * day, rather than a leak nobody notices at all.
 *
 * Field names rather than paths, because the same name means the same thing
 * everywhere in these contracts (`quantity` is a size wherever it appears) and a
 * path-based table would have to be re-derived every time a schema is nested
 * somewhere new — which is the same forget-to-update failure in another place.
 */
import type { PerformanceDisclosure } from './enums.js';
import type { ViewerRelationship } from './social.js';

/**
 * Three tiers, ordered. A viewer resolved to a tier receives fields at that tier
 * and below.
 */
export type DisclosureTier = 'structural' | 'returns' | 'amount';

const TIER_RANK: Readonly<Record<DisclosureTier, number>> = {
  structural: 0,
  returns: 1,
  amount: 2,
};

/**
 * Identity, classification and time. Nothing here reveals how large a position
 * is or how much money an account holds.
 */
export const STRUCTURAL_FIELDS = [
  'id',
  'post_id',
  'user_id',
  'author_user_id',
  'followee_user_id',
  'follower_user_id',
  'instrument_id',
  'instrument_ids',
  'underlying_id',
  'backtest_id',
  'strategy_id',
  'handle',
  'display_name',
  'bio',
  'avatar_url',
  'kind',
  'side',
  'action',
  'visibility',
  'moderation_state',
  'state',
  'status',
  'symbol',
  'raw_symbol',
  'name',
  'body',
  'title',
  'currency',
  'asset_class',
  'asset_classes',
  'sample',
  'fee_model',
  'slippage_model',
  'borrow_model',
  'start_date',
  'end_date',
  'universe_definition',
  'interval',
  'bar_interval',
  'as_of',
  'created_at',
  'updated_at',
  'edited_at',
  'deleted_at',
  'executed_at',
  'closed_at',
  'opened_at',
  'occurred_at',
  'trade_date',
  'expires_at',
  'verified_at',
  'revoked_at',
  'revocation_reason',
  'verdict',
  'method',
  'verification',
  'attachments',
  'trade',
  'portfolio',
  'backtest',
  'holdings',
  'performance',
  'is_verified_identity',
  'is_muted',
  'follower_count',
  'following_count',
  'post_count',
  'reply_count',
  'reaction_counts',
  'trade_count',
  'positions_count',
  'reveal_notional',
  'performance_disclosure',
  'tags',
  'media_url',
  'deep_link',
  'topic',
  'rationale',
  'basis_quality',
] as const;

/**
 * Percentages, ratios and per-unit prices. A price is a public fact about the
 * market; combined with a quantity it is a position size, which is why prices
 * sit here and quantities sit a tier above.
 *
 * At `none` these are withheld too: the spec says a `none` profile emits no
 * performance data *of any kind*, and a percentage return is performance data.
 */
export const RETURNS_FIELDS = [
  'price',
  'entry_price',
  'exit_price',
  'avg_entry_price',
  'last_price',
  'suggested_limit_price',
  'stop_loss_price',
  'take_profit_price',
  'strike',
  'return_pct',
  'return_since_entry',
  'period_return',
  'cumulative_return',
  'total_return',
  'return_net',
  'return_gross',
  'time_weighted_return_1m',
  'time_weighted_return_3m',
  'time_weighted_return_1y',
  'time_weighted_return_itd',
  'max_drawdown',
  'max_drawdown_duration_days',
  'drawdown',
  'sharpe',
  'deflated_sharpe',
  'sortino',
  'calmar',
  'omega',
  'win_rate',
  'profit_factor',
  'payoff_ratio',
  'expectancy',
  'volatility_annualised',
  'beta',
  'alpha',
  'information_ratio',
  'tracking_error',
  'ulcer_index',
  'var_95',
  'expected_shortfall_95',
  'exposure',
  'turnover_annualised',
  'weight',
  'unrealized_pnl_pct',
  'cagr',
] as const;

/**
 * Sizes and amounts. Reachable only by the author, or by a viewer of a post
 * whose author is at `full` disclosure *and* who set reveal-notional on that
 * post — both conditions, per the trade-sharing spec.
 */
export const AMOUNT_FIELDS = [
  'quantity',
  'target_quantity',
  'day_open_quantity',
  'quantity_opened',
  'quantity_remaining',
  'filled_quantity',
  'leaves_quantity',
  'delta_adjusted_qty',
  'notional',
  'equity',
  'cash',
  'settled',
  'unsettled',
  'reserved',
  'buying_power',
  'day_trade_buying_power',
  'margin_loan',
  'margin_used',
  'maintenance_margin',
  'market_value',
  'long_market_value',
  'short_market_value',
  'gross_exposure',
  'net_exposure',
  'cost_basis',
  'allocated_capital',
  'initial_capital',
  'high_water_mark',
  'realized_pnl',
  'realized_pnl_ytd',
  'realized_pnl_day',
  'unrealized_pnl',
  'day_pnl',
  'amount',
  'gross_amount',
  'net_amount',
  'commission',
  'fees',
  'fees_day',
  'dividends_day',
  'threshold_money',
  'var_amount',
  'expected_shortfall',
  'price_improvement',
] as const;

function buildTable(): ReadonlyMap<string, DisclosureTier> {
  const table = new Map<string, DisclosureTier>();
  const add = (keys: readonly string[], tier: DisclosureTier): void => {
    for (const key of keys) {
      const existing = table.get(key);
      // A field classified twice is ambiguous, and the ambiguity would resolve
      // in declaration order — silently, and in whichever direction the last
      // edit happened to leave it. Fail at module load instead.
      if (existing !== undefined && existing !== tier) {
        throw new Error(`disclosure field '${key}' is classified as both ${existing} and ${tier}`);
      }
      table.set(key, tier);
    }
  };
  add(STRUCTURAL_FIELDS, 'structural');
  add(RETURNS_FIELDS, 'returns');
  add(AMOUNT_FIELDS, 'amount');
  return table;
}

export const DISCLOSURE_FIELD_TIERS = buildTable();

/** The tier a field belongs to, or null if it is not classified — i.e. denied. */
export function tierOf(field: string): DisclosureTier | null {
  return DISCLOSURE_FIELD_TIERS.get(field) ?? null;
}

export interface DisclosureContext {
  /** The author's profile-level setting. */
  readonly level: PerformanceDisclosure;
  /** How the viewer stands relative to the author. */
  readonly relationship: ViewerRelationship;
  /** The per-post opt-in. Meaningless unless `level` is 'full'. */
  readonly revealNotional?: boolean;
}

/**
 * The single place the two-condition rule is evaluated. Returning the tier — not
 * a boolean — means callers that need to explain a redaction ("upgrade to see
 * sizes") can do so without re-deriving the rule.
 */
export function resolveTier(ctx: DisclosureContext): DisclosureTier {
  if (ctx.relationship === 'self') return 'amount';
  switch (ctx.level) {
    case 'none':
      return 'structural';
    case 'returns_only':
      return 'returns';
    case 'full':
      return ctx.revealNotional === true ? 'amount' : 'returns';
  }
}

export interface SerializeOptions {
  /**
   * Drop an object that filtering emptied. This is what makes a `none` profile
   * omit its performance section entirely rather than emit `performance: {}`,
   * which reads as "no data" when it means "not disclosed".
   */
  readonly dropEmptyObjects?: boolean;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function strip(value: unknown, maxRank: number, dropEmpty: boolean): unknown {
  if (Array.isArray(value)) {
    return value.map((item) => strip(item, maxRank, dropEmpty));
  }
  if (!isPlainObject(value)) return value;

  const out: Record<string, unknown> = {};
  for (const [key, raw] of Object.entries(value)) {
    const tier = DISCLOSURE_FIELD_TIERS.get(key);
    // Deny by default: an unclassified key is dropped rather than passed
    // through. Anything new is invisible until someone classifies it.
    if (tier === undefined) continue;
    if (TIER_RANK[tier] > maxRank) continue;

    const stripped = strip(raw, maxRank, dropEmpty);
    if (
      dropEmpty &&
      isPlainObject(stripped) &&
      Object.keys(stripped).length === 0 &&
      isPlainObject(raw) &&
      Object.keys(raw).length > 0
    ) {
      continue;
    }
    out[key] = stripped;
  }
  return out;
}

/**
 * Strip `payload` to what `ctx` permits.
 *
 * Returns `null` for a blocked viewer: a block hides content in both directions,
 * and an empty object would still confirm that the post exists.
 *
 * The author ('self') gets the payload back unchanged — including amounts —
 * which is the one case where the allowlist is bypassed. That bypass is safe
 * precisely because it is keyed on the relationship rather than on any field.
 */
export function serializeForDisclosure<T>(
  payload: T,
  ctx: DisclosureContext,
  options: SerializeOptions = {},
): unknown {
  if (ctx.relationship === 'blocked') return null;
  if (ctx.relationship === 'self') return payload;
  const dropEmpty = options.dropEmptyObjects ?? true;
  return strip(payload, TIER_RANK[resolveTier(ctx)], dropEmpty);
}

/**
 * Convenience for the common call site: a post read by a viewer. Folds the
 * post's reveal flag into the context so no caller has to remember that `full`
 * alone is not enough.
 */
export function serializePostForViewer<T extends { reveal_notional?: boolean }>(
  post: T,
  level: PerformanceDisclosure,
  relationship: ViewerRelationship,
): unknown {
  return serializeForDisclosure(post, {
    level,
    relationship,
    revealNotional: post.reveal_notional === true,
  });
}
