/**
 * Exhaustive disclosure tests.
 *
 * "Exhaustive" is meant literally: the matrix cases below enumerate every
 * (disclosure level x viewer relationship x reveal-notional) combination rather
 * than sampling a few, because the cost of a missed combination here is a
 * privacy incident and the cost of enumerating them is twelve lines.
 */
import { describe, expect, it } from 'vitest';
import { PERFORMANCE_DISCLOSURES, type PerformanceDisclosure } from './enums.js';
import type { ViewerRelationship } from './social.js';
import {
  AMOUNT_FIELDS,
  DISCLOSURE_FIELD_TIERS,
  RETURNS_FIELDS,
  STRUCTURAL_FIELDS,
  resolveTier,
  serializeForDisclosure,
  serializePostForViewer,
  tierOf,
} from './disclosure.js';

const RELATIONSHIPS: readonly ViewerRelationship[] = ['self', 'follower', 'stranger', 'blocked'];

/** A trade share carrying one field from each tier plus an unclassified one. */
const tradePost = {
  id: 'pst_01JB3QF7K2ZXQ8M4',
  author_user_id: 'usr_01JB3QF7K2ZXQ8M4',
  kind: 'trade',
  body: 'closed the swing',
  reveal_notional: false,
  created_at: '2026-03-02T14:30:00Z',
  trade: {
    instrument_id: 'ins_01JB3QF7K2ZXQ8M4',
    side: 'buy',
    entry_price: '183.22',
    exit_price: '191.04',
    return_pct: '0.0427',
    executed_at: '2026-02-11T15:02:11Z',
    quantity: '120',
    notional: '21986.40',
  },
  // Not in any tier. A field added to a schema without being classified must
  // not reach a viewer just because nobody remembered to deny it.
  internal_broker_ref: 'IBKR-4417-XYZ',
};

const SIZE_KEYS = ['quantity', 'notional', 'equity', 'market_value', 'cost_basis'] as const;

function collectKeys(value: unknown, into: Set<string> = new Set()): Set<string> {
  if (Array.isArray(value)) {
    for (const item of value) collectKeys(item, into);
    return into;
  }
  if (typeof value === 'object' && value !== null) {
    for (const [k, v] of Object.entries(value)) {
      into.add(k);
      collectKeys(v, into);
    }
  }
  return into;
}

describe('field classification table', () => {
  it('classifies every listed field exactly once', () => {
    const all = [...STRUCTURAL_FIELDS, ...RETURNS_FIELDS, ...AMOUNT_FIELDS];
    expect(new Set(all).size).toBe(all.length);
    expect(DISCLOSURE_FIELD_TIERS.size).toBe(all.length);
  });

  it('denies an unclassified field', () => {
    expect(tierOf('internal_broker_ref')).toBeNull();
    expect(tierOf('gross_notional_next_quarter')).toBeNull();
  });

  it('puts every size-bearing field in the amount tier', () => {
    for (const key of SIZE_KEYS) expect(tierOf(key)).toBe('amount');
  });
});

describe('tier resolution across the full matrix', () => {
  const cases: Array<[PerformanceDisclosure, ViewerRelationship, boolean, string]> = [];
  for (const level of PERFORMANCE_DISCLOSURES) {
    for (const relationship of RELATIONSHIPS) {
      for (const reveal of [false, true]) {
        // self always sees everything; blocked never reaches resolveTier.
        const expected =
          relationship === 'self'
            ? 'amount'
            : level === 'none'
              ? 'structural'
              : level === 'returns_only'
                ? 'returns'
                : reveal
                  ? 'amount'
                  : 'returns';
        cases.push([level, relationship, reveal, expected]);
      }
    }
  }

  it.each(cases)('level=%s relationship=%s reveal=%s -> %s', (level, relationship, reveal, want) => {
    expect(resolveTier({ level, relationship, revealNotional: reveal })).toBe(want);
  });

  it('enumerates the whole matrix', () => {
    expect(cases).toHaveLength(PERFORMANCE_DISCLOSURES.length * RELATIONSHIPS.length * 2);
  });
});

describe('serialization across the full matrix', () => {
  for (const level of PERFORMANCE_DISCLOSURES) {
    for (const relationship of RELATIONSHIPS) {
      for (const reveal of [false, true]) {
        const label = `level=${level} relationship=${relationship} reveal=${reveal}`;

        it(`${label} never leaks a size unless entitled`, () => {
          const out = serializeForDisclosure(
            { ...tradePost, reveal_notional: reveal },
            { level, relationship, revealNotional: reveal },
          );
          const entitled = relationship === 'self' || (level === 'full' && reveal);
          if (relationship === 'blocked') {
            expect(out).toBeNull();
            return;
          }
          const keys = collectKeys(out);
          for (const key of SIZE_KEYS) {
            expect(keys.has(key), `${label} exposed ${key}`).toBe(entitled && key in tradePost.trade);
          }
        });

        it(`${label} never leaks an unclassified field to a non-author`, () => {
          const out = serializeForDisclosure(
            { ...tradePost, reveal_notional: reveal },
            { level, relationship, revealNotional: reveal },
          );
          if (relationship === 'self') {
            expect(collectKeys(out).has('internal_broker_ref')).toBe(true);
            return;
          }
          if (relationship === 'blocked') return;
          expect(collectKeys(out).has('internal_broker_ref')).toBe(false);
        });
      }
    }
  }
});

describe('spec scenarios', () => {
  it('returns_only: entry price, exit price and percentage return, no sizes', () => {
    const out = serializeForDisclosure(tradePost, {
      level: 'returns_only',
      relationship: 'stranger',
    }) as { trade: Record<string, unknown> };

    expect(out.trade).toMatchObject({
      entry_price: '183.22',
      exit_price: '191.04',
      return_pct: '0.0427',
    });
    expect(out.trade).not.toHaveProperty('quantity');
    expect(out.trade).not.toHaveProperty('notional');
  });

  it('full + reveal_notional: the viewer receives quantity and notional', () => {
    const post = { ...tradePost, reveal_notional: true };
    const out = serializePostForViewer(post, 'full', 'follower') as {
      trade: Record<string, unknown>;
    };
    expect(out.trade.quantity).toBe('120');
    expect(out.trade.notional).toBe('21986.40');
  });

  it('full without reveal_notional: still no quantity or notional', () => {
    // The spec makes these two conditions conjunctive; a profile-level setting
    // alone is not consent for a specific post.
    const out = serializePostForViewer(tradePost, 'full', 'follower') as {
      trade: Record<string, unknown>;
    };
    expect(out.trade).not.toHaveProperty('quantity');
    expect(out.trade).not.toHaveProperty('notional');
    expect(out.trade.return_pct).toBe('0.0427');
  });

  it('none: the performance section is omitted entirely, not emptied', () => {
    const profile = {
      user_id: 'usr_01JB3QF7K2ZXQ8M4',
      handle: 'quantkid',
      display_name: 'Quant Kid',
      performance_disclosure: 'none',
      performance: {
        time_weighted_return_1y: '0.184',
        max_drawdown: '-0.092',
        win_rate: '0.57',
      },
    };
    const out = serializeForDisclosure(profile, {
      level: 'none',
      relationship: 'stranger',
    }) as Record<string, unknown>;

    expect(out).not.toHaveProperty('performance');
    expect(out.handle).toBe('quantkid');
  });

  it('returns_only: the performance section keeps percentages and risk stats', () => {
    const profile = {
      user_id: 'usr_01JB3QF7K2ZXQ8M4',
      handle: 'quantkid',
      performance: {
        time_weighted_return_1y: '0.184',
        max_drawdown: '-0.092',
        win_rate: '0.57',
        equity: '412300.00',
      },
    };
    const out = serializeForDisclosure(profile, {
      level: 'returns_only',
      relationship: 'follower',
    }) as { performance: Record<string, unknown> };

    expect(out.performance).toMatchObject({
      time_weighted_return_1y: '0.184',
      max_drawdown: '-0.092',
      win_rate: '0.57',
    });
    expect(out.performance).not.toHaveProperty('equity');
  });

  it('owner sees the full detail at every level', () => {
    for (const level of PERFORMANCE_DISCLOSURES) {
      const out = serializeForDisclosure(tradePost, { level, relationship: 'self' }) as typeof tradePost;
      expect(out.trade.quantity).toBe('120');
      expect(out.trade.notional).toBe('21986.40');
    }
  });

  it('a blocked viewer gets null, not an empty object', () => {
    // An empty object still confirms the post exists, which a block must not.
    for (const level of PERFORMANCE_DISCLOSURES) {
      expect(serializeForDisclosure(tradePost, { level, relationship: 'blocked' })).toBeNull();
    }
  });
});

describe('portfolio shares expose composition, not size', () => {
  const portfolioPost = {
    id: 'pst_01JB3QF7K2ZXQ8M5',
    kind: 'portfolio',
    reveal_notional: false,
    portfolio: {
      as_of: '2026-03-01T21:00:00Z',
      period_return: '0.061',
      equity: '412300.00',
      holdings: [
        { instrument_id: 'ins_01JB3QF7K2ZXQ8M4', weight: '0.34', quantity: '900' },
        { instrument_id: 'ins_01JB3QF7K2ZXQ8M6', weight: '0.21', quantity: '150' },
      ],
    },
  };

  it('emits weights and the as-of time, and no share counts or dollar values', () => {
    const out = serializeForDisclosure(portfolioPost, {
      level: 'returns_only',
      relationship: 'stranger',
    }) as { portfolio: { holdings: Array<Record<string, unknown>>; as_of: string } };

    expect(out.portfolio.as_of).toBe('2026-03-01T21:00:00Z');
    expect(out.portfolio.holdings.map((h) => h.weight)).toEqual(['0.34', '0.21']);
    for (const holding of out.portfolio.holdings) {
      expect(holding).not.toHaveProperty('quantity');
    }
    expect(out.portfolio).not.toHaveProperty('equity');
  });

  it('strips inside arrays at every depth', () => {
    const nested = { holdings: [{ holdings: [{ quantity: '1', weight: '0.5' }] }] };
    const out = serializeForDisclosure(nested, {
      level: 'returns_only',
      relationship: 'stranger',
    });
    expect(collectKeys(out).has('quantity')).toBe(false);
    expect(collectKeys(out).has('weight')).toBe(true);
  });
});

describe('serializer mechanics', () => {
  it('leaves primitives and nulls intact', () => {
    const out = serializeForDisclosure({ body: 'hi', bio: null, tags: ['a', 'b'] }, {
      level: 'returns_only',
      relationship: 'stranger',
    });
    expect(out).toEqual({ body: 'hi', bio: null, tags: ['a', 'b'] });
  });

  it('keeps an object that was already empty when dropEmptyObjects is set', () => {
    // Dropping a section because filtering emptied it is meaningful; dropping
    // one the author genuinely left empty would change the payload's shape for
    // no privacy reason.
    const out = serializeForDisclosure(
      { verification: {} },
      { level: 'returns_only', relationship: 'stranger' },
    );
    expect(out).toEqual({ verification: {} });
  });

  it('does not mutate the input', () => {
    const input = structuredClone(tradePost);
    serializeForDisclosure(input, { level: 'none', relationship: 'stranger' });
    expect(input).toEqual(tradePost);
  });
});
