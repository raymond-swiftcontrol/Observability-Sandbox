/** On-Balance Volume: cumulative volume, signed by the direction of each bar's close-to-close change. */
import { requireNonEmpty, type OhlcvBar } from '../utils.js';

export function obv(bars: readonly OhlcvBar[]): number[] {
  requireNonEmpty(bars, 'bars');
  const out: number[] = [bars[0]!.volume];
  for (let i = 1; i < bars.length; i += 1) {
    const prevClose = (bars[i - 1] as OhlcvBar).close;
    const bar = bars[i] as OhlcvBar;
    let delta = 0;
    if (bar.close > prevClose) delta = bar.volume;
    else if (bar.close < prevClose) delta = -bar.volume;
    out.push((out[i - 1] as number) + delta);
  }
  return out;
}
