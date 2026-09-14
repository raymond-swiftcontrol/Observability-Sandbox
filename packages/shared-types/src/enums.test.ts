/**
 * Enum parity against the SQL.
 *
 * The enums in `enums.ts` are hand-written duplicates of the Postgres types.
 * This test is what keeps the duplication honest: it parses the migrations and
 * compares member-for-member, in order, so adding a value in SQL without adding
 * it here fails the build rather than failing at runtime in production.
 */
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import * as E from './enums.js';

const MIGRATIONS_DIR = fileURLToPath(new URL('../../../db/migrations/', import.meta.url));

/** `CREATE TYPE schema.name AS ENUM ( 'a', 'b' -- comment\n , 'c' );` */
function parseSqlEnums(): Map<string, string[]> {
  const out = new Map<string, string[]>();
  const files = readdirSync(MIGRATIONS_DIR)
    .filter((f) => f.endsWith('.sql') && !f.endsWith('.down.sql'))
    .sort();
  for (const file of files) {
    const sql = readFileSync(join(MIGRATIONS_DIR, file), 'utf8');
    const re = /CREATE TYPE\s+([a-z_]+\.[a-z_]+)\s+AS ENUM\s*\(([\s\S]*?)\);/g;
    for (const match of sql.matchAll(re)) {
      const [, name, body] = match;
      if (name === undefined || body === undefined) continue;
      const values = [...body.matchAll(/'([^']*)'/g)].map((m) => m[1] as string);
      out.set(name, values);
    }
  }
  return out;
}

const SQL_ENUMS = parseSqlEnums();

/** SQL type name → the constant this package exports for it. */
const PARITY: ReadonlyArray<readonly [string, readonly string[]]> = [
  ['reference.asset_class', E.ASSET_CLASSES],
  ['reference.bar_interval', E.BAR_INTERVALS],
  ['reference.side', E.SIDES],
  ['reference.position_side', E.POSITION_SIDES],
  ['reference.data_quality', E.DATA_QUALITIES],
  ['reference.venue_kind', E.VENUE_KINDS],
  ['reference.instrument_status', E.INSTRUMENT_STATUSES],
  ['reference.option_type', E.OPTION_TYPES],
  ['reference.exercise_style', E.EXERCISE_STYLES],
  ['reference.settlement_type', E.SETTLEMENT_TYPES],
  ['identity.user_status', E.USER_STATUSES],
  ['identity.kyc_status', E.KYC_STATUSES],
  ['identity.platform', E.CLIENT_PLATFORMS],
  ['book.account_type', E.ACCOUNT_TYPES],
  ['book.account_status', E.ACCOUNT_STATUSES],
  ['book.broker', E.BROKERS],
  ['book.ledger_account', E.LEDGER_ACCOUNTS],
  ['book.entry_reason', E.ENTRY_REASONS],
  ['book.transfer_direction', E.TRANSFER_DIRECTIONS],
  ['oms.order_type', E.ORDER_TYPES],
  ['oms.time_in_force', E.TIME_IN_FORCES],
  ['oms.order_status', E.ORDER_STATUSES],
  ['oms.execution_algo', E.EXECUTION_ALGOS],
  ['oms.order_source', E.ORDER_SOURCES],
  ['oms.event_type', E.ORDER_EVENT_TYPES],
  ['research.strategy_kind', E.STRATEGY_KINDS],
  ['research.strategy_status', E.STRATEGY_STATUSES],
  ['research.signal_action', E.SIGNAL_ACTIONS],
  ['research.backtest_status', E.BACKTEST_STATUSES],
  ['research.sample_designation', E.SAMPLE_DESIGNATIONS],
  ['research.slippage_model', E.SLIPPAGE_MODELS],
  ['research.feature_category', E.FEATURE_CATEGORIES],
  ['book.transfer_status', E.TRANSFER_STATUSES],
  ['risk.limit_scope', E.RISK_LIMIT_SCOPES],
  ['risk.limit_kind', E.RISK_LIMIT_KINDS],
  ['risk.enforcement', E.RISK_ENFORCEMENTS],
  ['risk.decision', E.RISK_VERDICTS],
  ['notify.alert_kind', E.ALERT_TRIGGER_KINDS],
  ['notify.channel', E.NOTIFICATION_CHANNELS],
  ['notify.urgency', E.NOTIFICATION_URGENCIES],
  ['notify.delivery_status', E.NOTIFICATION_STATUSES],
  ['social.visibility', E.PROFILE_VISIBILITIES],
  ['social.disclosure_level', E.PERFORMANCE_DISCLOSURES],
  ['social.follow_state', E.FOLLOW_STATES],
  ['audit.actor_kind', E.ACTOR_KINDS],
];

describe('SQL enum parity', () => {
  it('finds the migrations', () => {
    expect(SQL_ENUMS.size).toBeGreaterThan(20);
  });

  it.each(PARITY)('%s matches member-for-member and in order', (sqlName, tsValues) => {
    const sqlValues = SQL_ENUMS.get(sqlName);
    expect(sqlValues, `${sqlName} not found in db/migrations`).toBeDefined();
    // Order matters: it is Postgres's sort order for the type, so a client
    // sorting by index and a query sorting by the column must agree.
    expect(tsValues).toEqual(sqlValues);
  });

  it('covers every enum the listed migrations declare', () => {
    // A migration can legitimately declare a type this package does not model
    // (e.g. fundamentals), so the check is one-directional per schema: every
    // type in the schemas we do model must be listed above.
    const modelled = new Set(PARITY.map(([name]) => name));
    const missing = [...SQL_ENUMS.keys()].filter(
      (name) =>
        ['oms.', 'book.', 'research.', 'risk.', 'notify.', 'social.'].some((p) =>
          name.startsWith(p),
        ) &&
        !modelled.has(name),
    );
    expect(missing).toEqual([]);
  });
});

describe('enum schemas', () => {
  it('rejects a value that is not a member', () => {
    expect(() => E.OrderStatus.parse('partially_cancelled')).toThrow();
    expect(() => E.Broker.parse('robinhood')).toThrow();
  });

  it('classifies terminal and working statuses without overlap', () => {
    const terminal = new Set<string>(E.TERMINAL_ORDER_STATUSES);
    const working = new Set<string>(E.WORKING_ORDER_STATUSES);
    for (const status of working) expect(terminal.has(status)).toBe(false);
    for (const status of terminal) expect(E.ORDER_STATUSES).toContain(status);
  });
});
