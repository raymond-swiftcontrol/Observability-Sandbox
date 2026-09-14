/**
 * Branded primitives and exact-decimal scalars.
 *
 * Two rules are encoded here and nowhere else:
 *
 *  1. Identifiers are not interchangeable strings. The platform's hardest bugs to
 *     find are the ones where an account id is passed where a portfolio id was
 *     expected: both are uuids, both validate, and the query simply returns
 *     nothing. Branding makes that a compile error.
 *  2. Money, prices and quantities cross service boundaries as decimal *strings*
 *     and are computed on with `Decimal`. `reference.money` is numeric(28,8) and
 *     `reference.quantity` is numeric(38,18) (see db/migrations/0001); a double
 *     cannot represent either, and JSON.parse would silently truncate them.
 */
import Decimal from 'decimal.js-light';
import { z } from 'zod';

/**
 * 40 significant digits: enough for numeric(38,18) quantities plus headroom for
 * intermediate products (quantity x price) before the result is rounded back to
 * a storable scale. Cloned rather than configured globally so that a dependency
 * calling `Decimal.set` cannot change the platform's arithmetic under us.
 */
export const HeliosDecimal = Decimal.clone({ precision: 40, rounding: 4 });
export type HeliosDecimal = Decimal;

/** Crockford base32 (no I, L, O, U) as produced by `platform.public_id()`. */
const PUBLIC_ID_BODY = '[0-9A-HJKMNP-TV-Z]{8,32}';
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Identifiers arrive in two shapes and both are legitimate: services join on the
 * uuid surrogate key, the gateway and mobile client speak the sortable public id
 * (`ord_01JB3QF7K2ZXQ8M4`). Accepting both but validating the *prefix* keeps the
 * mix-up class of bug — an account id where an instrument id belongs — a
 * validation failure at the edge instead of an empty result set three hops in.
 */
function brandedId<B extends string>(prefix: string, brand: B) {
  const publicRe = new RegExp(`^${prefix}_${PUBLIC_ID_BODY}$`);
  return z
    .string()
    .trim()
    .refine((v) => UUID_RE.test(v) || publicRe.test(v), {
      message: `expected a uuid or a ${prefix}_ prefixed public id`,
    })
    .brand<B>();
}

export const InstrumentId = brandedId('ins', 'InstrumentId');
export const VenueId = z.number().int().positive().brand<'VenueId'>();
export const AccountId = brandedId('acc', 'AccountId');
export const PortfolioId = brandedId('pf', 'PortfolioId');
export const OrderId = brandedId('ord', 'OrderId');
export const FillId = brandedId('fil', 'FillId');
export const UserId = brandedId('usr', 'UserId');
export const StrategyId = brandedId('stg', 'StrategyId');
export const BacktestId = brandedId('bt', 'BacktestId');
export const PostId = brandedId('pst', 'PostId');
export const ConnectionId = brandedId('bcx', 'ConnectionId');

export type InstrumentId = z.infer<typeof InstrumentId>;
export type VenueId = z.infer<typeof VenueId>;
export type AccountId = z.infer<typeof AccountId>;
export type PortfolioId = z.infer<typeof PortfolioId>;
export type OrderId = z.infer<typeof OrderId>;
export type FillId = z.infer<typeof FillId>;
export type UserId = z.infer<typeof UserId>;
export type StrategyId = z.infer<typeof StrategyId>;
export type BacktestId = z.infer<typeof BacktestId>;
export type PostId = z.infer<typeof PostId>;
export type ConnectionId = z.infer<typeof ConnectionId>;

/**
 * No exponent form: Postgres never emits one for `numeric`, and accepting it
 * here would mean two wire representations of the same value, which breaks the
 * string equality that idempotency keys and dedupe rely on.
 */
const DECIMAL_RE = /^-?\d+(?:\.\d+)?$/;

export class DecimalParseError extends Error {
  constructor(
    readonly input: unknown,
    reason: string,
  ) {
    super(`invalid decimal (${reason}): ${String(input)}`);
    this.name = 'DecimalParseError';
  }
}

interface DecimalSpec {
  /** Maximum fractional digits, matching the SQL domain's scale. */
  readonly scale: number;
  readonly signed: boolean;
  readonly label: string;
}

/**
 * Numbers are accepted for ergonomics (literals in tests and in the mobile order
 * ticket) but are canonicalised through `Decimal` immediately, and integers
 * beyond 2^53 are rejected rather than silently rounded. Strings remain the
 * contract for anything originating in the database.
 */
function decimalScalar<B extends string>(spec: DecimalSpec, brand: B) {
  return z
    .union([z.string(), z.number(), z.instanceof(Decimal)])
    .transform((raw, ctx): string => {
      let text: string;
      if (typeof raw === 'number') {
        if (!Number.isFinite(raw)) {
          ctx.addIssue({ code: z.ZodIssueCode.custom, message: `${spec.label} must be finite` });
          return z.NEVER;
        }
        if (!Number.isSafeInteger(Math.trunc(raw))) {
          ctx.addIssue({
            code: z.ZodIssueCode.custom,
            message: `${spec.label} magnitude exceeds exact double range; pass a string`,
          });
          return z.NEVER;
        }
        text = new HeliosDecimal(raw).toFixed();
      } else if (typeof raw === 'string') {
        text = raw.trim();
      } else {
        text = new HeliosDecimal(raw.toFixed()).toFixed();
      }

      if (!DECIMAL_RE.test(text)) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          message: `${spec.label} must be a plain decimal string`,
        });
        return z.NEVER;
      }
      const fraction = text.split('.')[1] ?? '';
      if (fraction.length > spec.scale) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          message: `${spec.label} carries ${fraction.length} decimals, scale is ${spec.scale}`,
        });
        return z.NEVER;
      }
      const d = new HeliosDecimal(text);
      if (!spec.signed && d.isNegative() && !d.isZero()) {
        ctx.addIssue({ code: z.ZodIssueCode.custom, message: `${spec.label} must not be negative` });
        return z.NEVER;
      }
      // Canonical form: '1.50' and '+1.5' and 1.5 all become '1.5', so two
      // payloads describing the same amount compare equal as strings.
      return d.toFixed();
    })
    .brand<B>();
}

/** numeric(28,8) — signed: P&L, fees and ledger legs are all money. */
export const Money = decimalScalar({ scale: 8, signed: true, label: 'money' }, 'Money');
/** numeric(28,12), non-negative — mirrors the `reference.price` CHECK. */
export const Price = decimalScalar({ scale: 12, signed: false, label: 'price' }, 'Price');
/** numeric(28,12), signed — spreads and per-unit P&L. */
export const SignedPrice = decimalScalar({ scale: 12, signed: true, label: 'signed price' }, 'SignedPrice');
/** numeric(38,18) — signed because ledger entries carry directional quantity. */
export const Quantity = decimalScalar({ scale: 18, signed: true, label: 'quantity' }, 'Quantity');
/** numeric(18,10) — returns, weights, participation rates. */
export const Ratio = decimalScalar({ scale: 10, signed: true, label: 'ratio' }, 'Ratio');
/** numeric(12,6) — slippage and fee rates. */
export const Bps = decimalScalar({ scale: 6, signed: true, label: 'bps' }, 'Bps');

export type Money = z.infer<typeof Money>;
export type Price = z.infer<typeof Price>;
export type SignedPrice = z.infer<typeof SignedPrice>;
export type Quantity = z.infer<typeof Quantity>;
export type Ratio = z.infer<typeof Ratio>;
export type Bps = z.infer<typeof Bps>;

function parser<T>(schema: { parse: (v: unknown) => T }, label: string) {
  return (input: unknown): T => {
    const result = schema.parse(input);
    if (result === undefined) throw new DecimalParseError(input, label);
    return result;
  };
}

export const parseMoney = parser(Money, 'money');
export const parsePrice = parser(Price, 'price');
export const parseQuantity = parser(Quantity, 'quantity');
export const parseRatio = parser(Ratio, 'ratio');
export const parseBps = parser(Bps, 'bps');

export const parseInstrumentId = (v: unknown): InstrumentId => InstrumentId.parse(v);
export const parseAccountId = (v: unknown): AccountId => AccountId.parse(v);
export const parsePortfolioId = (v: unknown): PortfolioId => PortfolioId.parse(v);
export const parseOrderId = (v: unknown): OrderId => OrderId.parse(v);
export const parseUserId = (v: unknown): UserId => UserId.parse(v);

/** Widen any decimal scalar to a `Decimal` for arithmetic. */
export function toDecimal(value: Money | Price | SignedPrice | Quantity | Ratio | Bps): Decimal {
  return new HeliosDecimal(value as unknown as string);
}

const ZERO = new HeliosDecimal(0);

export const ZERO_MONEY = Money.parse('0');
export const ZERO_QUANTITY = Quantity.parse('0');

/** Sum money exactly. Rounds the result to the money scale only at the end. */
export function sumMoney(values: readonly Money[]): Money {
  const total = values.reduce<Decimal>((acc, v) => acc.plus(toDecimal(v)), ZERO);
  return Money.parse(total.toFixed(8));
}

export function addMoney(a: Money, b: Money): Money {
  return Money.parse(toDecimal(a).plus(toDecimal(b)).toFixed(8));
}

export function subtractMoney(a: Money, b: Money): Money {
  return Money.parse(toDecimal(a).minus(toDecimal(b)).toFixed(8));
}

export function negateMoney(a: Money): Money {
  return Money.parse(toDecimal(a).negated().toFixed(8));
}

/**
 * Notional = quantity x price x multiplier. Rounded half-up to the money scale,
 * which is what the ledger stores; callers that need the unrounded value should
 * compose `toDecimal` themselves.
 */
export function notional(quantity: Quantity, price: Price, multiplier: Ratio | number = 1): Money {
  const mult =
    typeof multiplier === 'number' ? new HeliosDecimal(multiplier) : toDecimal(multiplier);
  return Money.parse(toDecimal(quantity).times(toDecimal(price)).times(mult).toFixed(8));
}

/** -1, 0 or 1. Comparing decimal strings lexicographically is wrong; this is not. */
export function compareDecimals(
  a: Money | Price | Quantity | Ratio | Bps,
  b: Money | Price | Quantity | Ratio | Bps,
): -1 | 0 | 1 {
  return toDecimal(a).comparedTo(toDecimal(b)) as -1 | 0 | 1;
}

export function isZero(value: Money | Price | Quantity | Ratio | Bps): boolean {
  return toDecimal(value).isZero();
}

/** Exact ratio as a `Ratio`; a zero denominator yields null rather than Infinity. */
export function safeRatio(
  numerator: Money | Price | Quantity,
  denominator: Money | Price | Quantity,
): Ratio | null {
  const d = toDecimal(denominator);
  if (d.isZero()) return null;
  return Ratio.parse(toDecimal(numerator).dividedBy(d).toFixed(10));
}

/** ISO-4217 alphabetic code, matching `reference.currency_code`. */
export const CurrencyCode = z
  .string()
  .regex(/^[A-Z]{3}$/, 'expected a 3-letter ISO 4217 code')
  .brand<'CurrencyCode'>();
export type CurrencyCode = z.infer<typeof CurrencyCode>;

/** Uppercase ticker, matching `reference.ticker`. */
export const Ticker = z
  .string()
  .min(1)
  .max(32)
  .regex(/^[A-Z0-9./:\-]+$/, 'ticker must be uppercase')
  .brand<'Ticker'>();
export type Ticker = z.infer<typeof Ticker>;

export const EmailAddress = z.string().email().max(254).brand<'EmailAddress'>();
export type EmailAddress = z.infer<typeof EmailAddress>;

/**
 * Timestamps cross the wire as ISO-8601 strings with an offset. `Date` is not
 * used in the contracts because it is mutable, serialises ambiguously, and loses
 * the original offset — which matters for venue-local session boundaries.
 */
export const Timestamp = z
  .string()
  .datetime({ offset: true })
  .brand<'Timestamp'>();
export type Timestamp = z.infer<typeof Timestamp>;

export const IsoDate = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, 'expected YYYY-MM-DD')
  .brand<'IsoDate'>();
export type IsoDate = z.infer<typeof IsoDate>;

export const TraceId = z.string().regex(/^[0-9a-f]{32}$/, 'expected a 32-hex-char W3C trace id');
export const SpanId = z.string().regex(/^[0-9a-f]{16}$/, 'expected a 16-hex-char W3C span id');
