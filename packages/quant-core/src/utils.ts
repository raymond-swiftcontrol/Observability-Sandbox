/**
 * Small shared helpers. Deliberately not exported from the package root as a
 * namespace: they are used by every other module here and re-exported flat.
 *
 * Everything in `@helios/quant-core` operates on `number`, not the exact
 * decimals of `@helios/shared-types`. That is a deliberate boundary: these are
 * statistical estimates over long series, where a double's 15 significant
 * digits are far beyond the precision of the inputs, and exact arithmetic over
 * a 10-year daily series would be orders of magnitude slower on a phone. Money
 * that lands in a ledger never passes through here.
 */

/** Trading days in a year — the platform-wide annualisation constant. */
export const TRADING_DAYS_PER_YEAR = 252;

export class QuantError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'QuantError';
  }
}

/** Throws rather than returning NaN: a silent NaN propagates for a long way. */
export function requireFinite(value: number, label: string): number {
  if (!Number.isFinite(value)) throw new QuantError(`${label} must be finite, got ${value}`);
  return value;
}

export function requirePositiveInt(value: number, label: string): number {
  if (!Number.isInteger(value) || value <= 0) {
    throw new QuantError(`${label} must be a positive integer, got ${value}`);
  }
  return value;
}

export function requireNonEmpty<T>(values: readonly T[], label: string): void {
  if (values.length === 0) throw new QuantError(`${label} must not be empty`);
}

/**
 * Division that answers `fallback` instead of Infinity or NaN. Ratios in this
 * package divide by things that are legitimately zero (a strategy with no
 * losses has no loss total), and Infinity in a tear-sheet renders as garbage.
 */
export function safeDiv(numerator: number, denominator: number, fallback = Number.NaN): number {
  if (denominator === 0 || !Number.isFinite(denominator) || !Number.isFinite(numerator)) {
    return fallback;
  }
  return numerator / denominator;
}

/** Clamps to [min, max]; NaN clamps to `min`, which is the conservative side. */
export function clamp(value: number, min: number, max: number): number {
  if (Number.isNaN(value)) return min;
  return Math.min(Math.max(value, min), max);
}

/**
 * Leading `null`s mark the warm-up period of a windowed indicator. Returning a
 * shorter array instead would misalign the result with its bar series, which is
 * the single most common charting bug.
 */
export type Series = ReadonlyArray<number | null>;

export function filled(length: number): Array<number | null> {
  return new Array<number | null>(length).fill(null);
}

/** Simple (arithmetic) returns: r_t = p_t / p_{t-1} - 1. */
export function simpleReturns(prices: readonly number[]): number[] {
  const out: number[] = [];
  for (let i = 1; i < prices.length; i += 1) {
    const prev = prices[i - 1] as number;
    const curr = prices[i] as number;
    out.push(safeDiv(curr - prev, prev, 0));
  }
  return out;
}

/**
 * Log returns. Additive across time, which is why they are the right input for
 * volatility and correlation even though simple returns are what a user reads.
 */
export function logReturns(prices: readonly number[]): number[] {
  const out: number[] = [];
  for (let i = 1; i < prices.length; i += 1) {
    const prev = prices[i - 1] as number;
    const curr = prices[i] as number;
    if (prev <= 0 || curr <= 0) throw new QuantError('log returns require positive prices');
    out.push(Math.log(curr / prev));
  }
  return out;
}

/** Compounds a return series into an equity curve starting at `initial`. */
export function equityCurve(returns: readonly number[], initial = 1): number[] {
  const out: number[] = [initial];
  let level = initial;
  for (const r of returns) {
    level *= 1 + r;
    out.push(level);
  }
  return out;
}

/**
 * Drawdown at each point: (value - running peak) / running peak, so values are
 * <= 0. Expressed against the peak rather than the start, because that is what
 * an investor actually experiences.
 */
export function drawdownSeries(values: readonly number[]): number[] {
  const out: number[] = [];
  let peak = Number.NEGATIVE_INFINITY;
  for (const v of values) {
    if (v > peak) peak = v;
    out.push(peak === 0 ? 0 : (v - peak) / peak);
  }
  return out;
}

/** The underwater curve is the drawdown series; named for how it is plotted. */
export const underwaterCurve = drawdownSeries;

export interface OhlcvBar {
  readonly ts: number;
  readonly open: number;
  readonly high: number;
  readonly low: number;
  readonly close: number;
  readonly volume: number;
}

/**
 * Aggregate bars into a coarser interval by bucketing on epoch milliseconds.
 *
 * Buckets are aligned to the epoch rather than to the first bar, so resampling
 * the same series from two different start points produces the same buckets —
 * without that, two clients charting the same instrument disagree about where
 * a 4h candle begins.
 */
export function resampleBars(bars: readonly OhlcvBar[], intervalMs: number): OhlcvBar[] {
  requirePositiveInt(intervalMs, 'intervalMs');
  const out: OhlcvBar[] = [];
  let bucketStart = Number.NaN;
  let current: {
    ts: number;
    open: number;
    high: number;
    low: number;
    close: number;
    volume: number;
  } | null = null;

  for (const bar of bars) {
    const start = Math.floor(bar.ts / intervalMs) * intervalMs;
    if (current === null || start !== bucketStart) {
      if (current !== null) out.push(current);
      bucketStart = start;
      current = {
        ts: start,
        open: bar.open,
        high: bar.high,
        low: bar.low,
        close: bar.close,
        volume: bar.volume,
      };
      continue;
    }
    current.high = Math.max(current.high, bar.high);
    current.low = Math.min(current.low, bar.low);
    current.close = bar.close;
    current.volume += bar.volume;
  }
  if (current !== null) out.push(current);
  return out;
}

// ── Formatting ───────────────────────────────────────────────────────────────

/**
 * Formatting lives here rather than in the UI package because the same numbers
 * are rendered by the mobile app, by notification bodies built server-side, and
 * by the CLI — and "-2.3%" versus "(2.3%)" across those is the kind of
 * inconsistency users read as a bug.
 */
export function formatMoney(value: number, currency = 'USD', fractionDigits = 2): string {
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency,
    minimumFractionDigits: fractionDigits,
    maximumFractionDigits: fractionDigits,
  }).format(value);
}

/** `0.0234` renders as `+2.34%`. Signed by default: direction is the message. */
export function formatPercent(ratio: number, fractionDigits = 2, signed = true): string {
  const pct = ratio * 100;
  const sign = signed && pct > 0 ? '+' : '';
  return `${sign}${pct.toFixed(fractionDigits)}%`;
}

export function formatBps(ratio: number, fractionDigits = 1): string {
  return `${(ratio * 10_000).toFixed(fractionDigits)} bps`;
}

/** Compact notation for axis labels and list rows: 1.2M, 48.2K. */
export function formatCompact(value: number, fractionDigits = 1): string {
  const abs = Math.abs(value);
  const sign = value < 0 ? '-' : '';
  if (abs >= 1e12) return `${sign}${(abs / 1e12).toFixed(fractionDigits)}T`;
  if (abs >= 1e9) return `${sign}${(abs / 1e9).toFixed(fractionDigits)}B`;
  if (abs >= 1e6) return `${sign}${(abs / 1e6).toFixed(fractionDigits)}M`;
  if (abs >= 1e3) return `${sign}${(abs / 1e3).toFixed(fractionDigits)}K`;
  return `${sign}${abs.toFixed(fractionDigits)}`;
}
