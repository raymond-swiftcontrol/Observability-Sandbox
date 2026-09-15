/**
 * Internal helpers shared across indicators. Not re-exported from the
 * package root — indicators compose these, callers should not need to.
 */
import type { Series } from '../utils.js';

/** Splits off the leading `null` warm-up run of a `Series`, returning the rest as a plain number array. */
export function trimLeadingNulls(series: Series): { offset: number; values: number[] } {
  let offset = 0;
  while (offset < series.length && series[offset] == null) offset += 1;
  return { offset, values: series.slice(offset) as number[] };
}

/**
 * Composes a derived series (e.g. `2*emaOfEma - ema`) that was computed over
 * a trimmed (null-stripped) sub-array back into the original index space.
 */
export function realign(length: number, offset: number, values: Series): Array<number | null> {
  const out = new Array<number | null>(length).fill(null);
  for (let i = 0; i < values.length; i += 1) out[offset + i] = values[i] ?? null;
  return out;
}
