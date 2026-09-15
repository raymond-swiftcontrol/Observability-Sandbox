/**
 * Rolling (windowed) statistics, returned as `Series` aligned to the input —
 * a `null` at index i means "fewer than `window` points are available yet".
 */
import { requirePositiveInt, type Series, filled } from '../utils.js';
import { stddevSample, variancePopulation, varianceSample } from './descriptive.js';

/**
 * Rolling mean via a running sum: O(n) total rather than O(n * window),
 * because each step only needs to add the entering value and subtract the
 * one leaving the window.
 */
export function rollingMean(values: readonly number[], window: number): Series {
  requirePositiveInt(window, 'window');
  const out = filled(values.length);
  let runningSum = 0;
  for (let i = 0; i < values.length; i += 1) {
    runningSum += values[i] as number;
    if (i >= window) runningSum -= values[i - window] as number;
    if (i >= window - 1) out[i] = runningSum / window;
  }
  return out;
}

/**
 * Rolling sample standard deviation. O(n * window): a running-sum-of-squares
 * approach is O(n) but accumulates floating point error over long series
 * (the classic "naive variance" instability), which matters more here than
 * the speed does since windows are typically small (14-200 bars).
 */
export function rollingStdDev(values: readonly number[], window: number, sample = true): Series {
  requirePositiveInt(window, 'window');
  if (window < 2 && sample) {
    throw new Error('rollingStdDev with sample=true requires window >= 2');
  }
  const out = filled(values.length);
  for (let i = window - 1; i < values.length; i += 1) {
    const slice = values.slice(i - window + 1, i + 1);
    out[i] = sample ? stddevSample(slice) : Math.sqrt(variancePopulation(slice));
  }
  return out;
}

/** Rolling sample variance; see `rollingStdDev` for the complexity tradeoff. */
export function rollingVariance(values: readonly number[], window: number, sample = true): Series {
  requirePositiveInt(window, 'window');
  const out = filled(values.length);
  for (let i = window - 1; i < values.length; i += 1) {
    const slice = values.slice(i - window + 1, i + 1);
    out[i] = sample ? varianceSample(slice) : variancePopulation(slice);
  }
  return out;
}

/**
 * Rolling minimum via a monotonic increasing deque of indices: each element
 * enters and leaves the deque at most once, so this is O(n) total rather than
 * O(n * window) for a naive re-scan.
 */
export function rollingMin(values: readonly number[], window: number): Series {
  return rollingExtreme(values, window, (a, b) => a <= b);
}

/** Rolling maximum; see `rollingMin` for the monotonic-deque argument. */
export function rollingMax(values: readonly number[], window: number): Series {
  return rollingExtreme(values, window, (a, b) => a >= b);
}

function rollingExtreme(
  values: readonly number[],
  window: number,
  keepFront: (candidate: number, incoming: number) => boolean,
): Series {
  requirePositiveInt(window, 'window');
  const out = filled(values.length);
  const deque: number[] = []; // indices into `values`, front = current extreme
  for (let i = 0; i < values.length; i += 1) {
    const v = values[i] as number;
    while (deque.length > 0 && !keepFront(values[deque[deque.length - 1] as number] as number, v)) {
      deque.pop();
    }
    deque.push(i);
    if ((deque[0] as number) <= i - window) deque.shift();
    if (i >= window - 1) out[i] = values[deque[0] as number] as number;
  }
  return out;
}
