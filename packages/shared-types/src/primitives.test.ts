import { describe, expect, it } from 'vitest';
import {
  AccountId,
  InstrumentId,
  Money,
  Price,
  Quantity,
  Ratio,
  Timestamp,
  addMoney,
  compareDecimals,
  notional,
  parseMoney,
  safeRatio,
  subtractMoney,
  sumMoney,
  toDecimal,
} from './primitives.js';

describe('branded identifiers', () => {
  it('accepts both a uuid and a correctly prefixed public id', () => {
    expect(AccountId.parse('acc_01JB3QF7K2ZXQ8M4')).toBe('acc_01JB3QF7K2ZXQ8M4');
    expect(AccountId.parse('3f2504e0-4f89-41d3-9a0c-0305e82c3301')).toBeTruthy();
  });

  it('rejects the right kind of id with the wrong prefix', () => {
    // The bug this exists to catch: an instrument id passed where an account id
    // belongs. Both are strings, both look plausible, and the query returns
    // nothing rather than failing.
    expect(() => AccountId.parse('ins_01JB3QF7K2ZXQ8M4')).toThrow();
    expect(() => InstrumentId.parse('acc_01JB3QF7K2ZXQ8M4')).toThrow();
  });

  it('rejects ambiguous base32 characters, matching platform.public_id()', () => {
    expect(() => AccountId.parse('acc_IIIIIIII')).toThrow();
    expect(() => AccountId.parse('acc_OOOOOOOO')).toThrow();
  });
});

describe('decimal scalars', () => {
  it('canonicalises equivalent spellings to one string', () => {
    expect(Money.parse('1.50')).toBe('1.5');
    expect(Money.parse(1.5)).toBe('1.5');
    expect(Money.parse(' 1.5 ')).toBe('1.5');
  });

  it('rejects exponent notation, which Postgres never emits for numeric', () => {
    expect(() => Money.parse('1.5e3')).toThrow();
  });

  it('rejects more decimals than the SQL scale allows', () => {
    // reference.money is numeric(28,8).
    expect(() => Money.parse('1.123456789')).toThrow();
    expect(Money.parse('1.12345678')).toBe('1.12345678');
    // reference.price is numeric(28,12).
    expect(Price.parse('0.000000000001')).toBe('0.000000000001');
  });

  it('rejects a negative price, mirroring the domain CHECK', () => {
    expect(() => Price.parse('-1')).toThrow();
    expect(Money.parse('-1')).toBe('-1');
  });

  it('refuses a number too large to be exact, rather than rounding it', () => {
    expect(() => Money.parse(2 ** 53 + 2)).toThrow();
  });

  it('rejects non-finite numbers', () => {
    expect(() => Money.parse(Number.NaN)).toThrow();
    expect(() => Money.parse(Number.POSITIVE_INFINITY)).toThrow();
  });
});

describe('money arithmetic', () => {
  it('does not accumulate binary floating-point error', () => {
    // 0.1 + 0.2 !== 0.3 in a double. Summed a hundred times over, that is the
    // difference between a ledger that balances and one that does not.
    const cents = Array.from({ length: 100 }, () => Money.parse('0.1'));
    expect(sumMoney(cents)).toBe('10');
    expect(addMoney(Money.parse('0.1'), Money.parse('0.2'))).toBe('0.3');
  });

  it('computes notional exactly for an option multiplier', () => {
    // 3 contracts x $2.35 x 100 = $705, not $704.9999999999999.
    const value = notional(Quantity.parse('3'), Price.parse('2.35'), Ratio.parse('100'));
    expect(value).toBe('705');
  });

  it('subtracts without drift', () => {
    expect(subtractMoney(Money.parse('100.10'), Money.parse('100.09'))).toBe('0.01');
  });

  it('compares numerically, not lexicographically', () => {
    // '9' > '10' as strings; as money it is not.
    expect(compareDecimals(Money.parse('9'), Money.parse('10'))).toBe(-1);
    expect(compareDecimals(Money.parse('10'), Money.parse('10.0'))).toBe(0);
  });

  it('returns null rather than Infinity for a zero denominator', () => {
    expect(safeRatio(Money.parse('5'), Money.parse('0'))).toBeNull();
    expect(safeRatio(Money.parse('1'), Money.parse('4'))).toBe('0.25');
  });

  it('round-trips through Decimal without changing value', () => {
    const m = parseMoney('1234.56789012');
    expect(toDecimal(m).toFixed(8)).toBe('1234.56789012');
  });
});

describe('timestamps', () => {
  it('requires an explicit offset', () => {
    expect(Timestamp.parse('2026-03-02T14:30:00Z')).toBe('2026-03-02T14:30:00Z');
    expect(Timestamp.parse('2026-03-02T14:30:00.000+01:00')).toBeTruthy();
    expect(() => Timestamp.parse('2026-03-02T14:30:00')).toThrow();
  });
});
