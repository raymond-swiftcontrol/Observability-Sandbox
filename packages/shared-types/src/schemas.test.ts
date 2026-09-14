/**
 * Round-trip parsing of every headline contract, plus the invariants the
 * schemas restate from the SQL CHECK constraints.
 */
import { describe, expect, it } from 'vitest';
import { Account, CashBalance, EquitySnapshot, Position, PositionLot } from './book.js';
import { BrokerCapabilities, BrokerConnection, ImportBatch, PositionSnapshot } from './broker.js';
import { ApiError, ERROR_CODES, ERROR_STATUS, httpStatusFor, pageOf, toFieldErrors } from './api.js';
import { Bar, Instrument, OptionContract, Quote, Trade, Venue } from './market.js';
import { Fill, Order, OrderEvent, OrderRequest } from './oms.js';
import { AlertRule, Notification, Watchlist } from './notify.js';
import { BacktestRun, Deployment, Signal, Strategy, StrategyVersion } from './research.js';
import { Greeks, RiskAssessment, RiskLimit, VarSnapshot } from './risk.js';
import { Follow, Post, PostAttachment, Profile, Reaction, Report } from './social.js';
import { z } from 'zod';

const TS = '2026-03-02T14:30:00Z';
const INS = 'ins_01JB3QF7K2ZXQ8M4';
const ACC = 'acc_01JB3QF7K2ZXQ8M4';
const PF = 'pf_01JB3QF7K2ZXQ8M4';
const ORD = 'ord_01JB3QF7K2ZXQ8M4';
const USR = 'usr_01JB3QF7K2ZXQ8M4';
const UUID = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';

/** Parsing a schema's own output must be a fixed point, or the wire is lossy. */
function roundTrip<T extends z.ZodTypeAny>(schema: T, input: unknown): z.infer<T> {
  const once = schema.parse(input);
  const twice = schema.parse(JSON.parse(JSON.stringify(once)));
  expect(twice).toEqual(once);
  return once;
}

describe('market contracts', () => {
  it('round-trips a venue', () => {
    roundTrip(Venue, {
      id: 12,
      mic: 'XNAS',
      code: 'NASDAQ',
      name: 'Nasdaq Stock Market',
      kind: 'exchange',
      country_code: 'US',
      timezone: 'America/New_York',
      currency: 'USD',
      tick_size_regime: [{ max_price: '1', tick: '0.0001' }],
      lot_size: 1,
      supports_odd_lots: true,
      maker_fee_bps: '-0.2',
      taker_fee_bps: '0.3',
      settlement_days: 1,
      has_pre_market: true,
      has_post_market: true,
      is_24h: false,
      is_active: true,
    });
  });

  it('round-trips an instrument and an option contract', () => {
    const instrument = roundTrip(Instrument, {
      id: INS,
      symbol: 'AAPL',
      venue_id: 12,
      asset_class: 'equity',
      name: 'Apple Inc.',
      currency: 'USD',
      status: 'active',
      lot_size: '1',
      min_order_qty: '0.0001',
      multiplier: '1',
      is_shortable: true,
      is_marginable: true,
      is_fractionable: true,
    });
    expect(instrument.figi).toBeNull();

    roundTrip(OptionContract, {
      instrument_id: 'ins_01JB3QF7K2ZXQ8M6',
      underlying_id: INS,
      option_type: 'call',
      strike: '190',
      expiration_date: '2026-06-19',
      exercise_style: 'american',
      settlement: 'physical',
      contract_size: '100',
    });
  });

  it('rejects a lowercase ticker, matching reference.ticker', () => {
    expect(() =>
      Instrument.parse({
        id: INS,
        symbol: 'aapl',
        venue_id: 12,
        asset_class: 'equity',
        name: 'Apple Inc.',
        currency: 'USD',
        status: 'active',
        lot_size: '1',
        min_order_qty: '1',
        multiplier: '1',
        is_shortable: true,
        is_marginable: true,
        is_fractionable: true,
      }),
    ).toThrow();
  });

  const bar = {
    ts: TS,
    instrument_id: INS,
    interval: '1d',
    open: '183.10',
    high: '185.40',
    low: '182.55',
    close: '184.92',
    volume: '48211900',
  };

  it('round-trips a coherent bar', () => {
    const parsed = roundTrip(Bar, bar);
    expect(parsed.session).toBe('regular');
    expect(parsed.quality).toBe('vendor');
  });

  it('rejects an incoherent bar rather than backtesting an impossible fill', () => {
    expect(() => Bar.parse({ ...bar, high: '180' })).toThrow(/incoherent OHLC/);
    expect(() => Bar.parse({ ...bar, low: '190' })).toThrow(/incoherent OHLC/);
  });

  it('round-trips a quote and a trade', () => {
    roundTrip(Quote, {
      ts: TS,
      instrument_id: INS,
      bid_price: '184.90',
      bid_size: '300',
      ask_price: '184.93',
      ask_size: '500',
    });
    roundTrip(Trade, {
      ts: TS,
      instrument_id: INS,
      price: '184.91',
      size: '100',
      venue_id: 12,
      aggressor: 'buy',
    });
  });
});

describe('book contracts', () => {
  it('round-trips an account', () => {
    roundTrip(Account, {
      id: ACC,
      owner_user_id: USR,
      name: 'Main',
      account_type: 'margin',
      status: 'active',
      base_currency: 'USD',
      broker: 'alpaca',
      is_paper: false,
      max_leverage: '4',
      day_trade_buying_power_multiple: '4',
      created_at: TS,
      updated_at: TS,
    });
  });

  const position = {
    id: UUID,
    account_id: ACC,
    portfolio_id: PF,
    instrument_id: INS,
    side: 'long',
    quantity: '120',
    avg_entry_price: '183.22',
    cost_basis: '21986.40',
    realized_pnl: '0',
    day_open_quantity: '120',
    multiplier: '1',
    opened_at: TS,
    updated_at: TS,
  };

  it('round-trips a position', () => {
    roundTrip(Position, position);
  });

  it('rejects a flat position holding quantity', () => {
    expect(() => Position.parse({ ...position, side: 'flat' })).toThrow();
    expect(() => Position.parse({ ...position, side: 'long', quantity: '0' })).toThrow();
  });

  it('rejects a lot with more remaining than it opened', () => {
    const lot = {
      id: UUID,
      position_id: UUID,
      account_id: ACC,
      instrument_id: INS,
      quantity_opened: '100',
      quantity_remaining: '40',
      entry_price: '183.22',
      entry_commission: '0',
      opened_at: TS,
    };
    roundTrip(PositionLot, lot);
    expect(() => PositionLot.parse({ ...lot, quantity_remaining: '140' })).toThrow();
  });

  it('round-trips a cash balance and an equity snapshot', () => {
    roundTrip(CashBalance, {
      account_id: ACC,
      currency: 'USD',
      settled: '12000',
      unsettled: '500',
      pending_transfer: '0',
      reserved: '1200',
      margin_loan: '0',
      buying_power: '45200',
      day_trade_buying_power: '45200',
      updated_at: TS,
    });
    roundTrip(EquitySnapshot, {
      ts: TS,
      account_id: ACC,
      equity: '412300',
      cash: '12500',
      long_market_value: '399800',
      short_market_value: '0',
      gross_exposure: '399800',
      net_exposure: '399800',
      margin_used: '0',
      maintenance_margin: '99950',
      buying_power: '45200',
      realized_pnl_day: '0',
      unrealized_pnl: '18400',
      fees_day: '0',
      dividends_day: '0',
      positions_count: 7,
      currency: 'USD',
    });
  });
});

describe('order contracts', () => {
  const base = {
    client_order_id: 'mobile-7f2a91cc',
    account_id: ACC,
    portfolio_id: PF,
    instrument_id: INS,
    side: 'buy',
    order_type: 'limit',
    quantity: '100',
    limit_price: '183.50',
  };

  it('round-trips a request and applies its defaults', () => {
    const parsed = roundTrip(OrderRequest, base);
    expect(parsed.time_in_force).toBe('day');
    expect(parsed.source).toBe('mobile');
    expect(parsed.notional).toBeNull();
  });

  it('requires a limit price on a limit order', () => {
    expect(() => OrderRequest.parse({ ...base, limit_price: null })).toThrow(/limit price/);
  });

  it('requires a stop price on a stop order', () => {
    expect(() =>
      OrderRequest.parse({ ...base, order_type: 'stop', limit_price: null }),
    ).toThrow(/stop price/);
  });

  it('requires exactly one of quantity and notional', () => {
    expect(() => OrderRequest.parse({ ...base, notional: '5000' })).toThrow(/exactly one/);
    expect(() => OrderRequest.parse({ ...base, quantity: null })).toThrow(/exactly one/);
    expect(OrderRequest.parse({ ...base, quantity: null, notional: '5000' }).notional).toBe('5000');
  });

  it('requires an iceberg to display less than it holds', () => {
    expect(() =>
      OrderRequest.parse({ ...base, order_type: 'iceberg', display_quantity: '100' }),
    ).toThrow(/display_quantity/);
    expect(
      OrderRequest.parse({ ...base, order_type: 'iceberg', display_quantity: '10' })
        .display_quantity,
    ).toBe('10');
  });

  it('requires a date on a gtd order', () => {
    expect(() => OrderRequest.parse({ ...base, time_in_force: 'gtd' })).toThrow(/good_till_date/);
  });

  const order = {
    ...base,
    id: ORD,
    source: 'mobile',
    time_in_force: 'day',
    extended_hours: false,
    status: 'partially_filled',
    filled_quantity: '40',
    leaves_quantity: '60',
    commission: '0',
    fees: '0',
    algo: 'none',
    broker: 'alpaca',
    created_at: TS,
    updated_at: TS,
  };

  it('round-trips an order', () => {
    roundTrip(Order, order);
  });

  it('rejects leaves that do not reconcile', () => {
    expect(() => Order.parse({ ...order, leaves_quantity: '70' })).toThrow(/leaves_quantity/);
  });

  it('requires terminal_at exactly on a terminal status', () => {
    expect(() =>
      Order.parse({ ...order, status: 'filled', filled_quantity: '100', leaves_quantity: '0' }),
    ).toThrow(/terminal_at/);
    expect(() => Order.parse({ ...order, terminal_at: TS })).toThrow(/terminal_at/);
  });

  it('requires a reason on a rejection', () => {
    expect(() =>
      Order.parse({ ...order, status: 'rejected', terminal_at: TS, rejected_reason: null }),
    ).toThrow(/reason/);
  });

  it('round-trips an order event', () => {
    roundTrip(OrderEvent, {
      id: 4412,
      order_id: ORD,
      sequence: 3,
      event_type: 'partial_fill',
      from_status: 'new',
      to_status: 'partially_filled',
      quantity: '40',
      price: '183.44',
      occurred_at: TS,
      recorded_at: TS,
    });
  });

  const fill = {
    id: 'fil_01JB3QF7K2ZXQ8M4',
    order_id: ORD,
    account_id: ACC,
    instrument_id: INS,
    side: 'buy',
    quantity: '40',
    price: '183.44',
    gross_amount: '7337.60',
    commission: '0.35',
    sec_fee: '0',
    taf_fee: '0',
    clearing_fee: '0',
    exchange_fee: '0',
    other_fees: '0',
    net_amount: '7337.95',
    trade_date: '2026-03-02',
    executed_at: TS,
    recorded_at: TS,
  };

  it('round-trips a fill whose fees reconcile', () => {
    roundTrip(Fill, fill);
  });

  it('rejects a fill whose net amount does not reconcile', () => {
    // A buy's fees increase what was paid; subtracting them posts the wrong
    // ledger entry and the position's cost basis is wrong forever after.
    expect(() => Fill.parse({ ...fill, net_amount: '7337.25' })).toThrow(/reconcile/);
  });
});

describe('research contracts', () => {
  it('round-trips a strategy and its version', () => {
    roundTrip(Strategy, {
      id: 'str_01JB3QF7K2ZXQ8M4',
      owner_user_id: USR,
      name: 'Cross-sectional momentum',
      slug: 'cross-sectional-momentum',
      kind: 'momentum',
      asset_classes: ['equity'],
      bar_interval: '1d',
      status: 'validated',
      created_at: TS,
      updated_at: TS,
    });

    roundTrip(StrategyVersion, {
      id: UUID,
      strategy_id: 'str_01JB3QF7K2ZXQ8M4',
      version: 4,
      content_hash: 'a'.repeat(64),
      code: 'def signals(ctx): ...',
      created_at: TS,
    });
  });

  it('requires exactly one body on a version', () => {
    const base = {
      id: UUID,
      strategy_id: 'str_01JB3QF7K2ZXQ8M4',
      version: 1,
      content_hash: 'b'.repeat(64),
      created_at: TS,
    };
    expect(() => StrategyVersion.parse(base)).toThrow(/exactly one/);
    expect(() =>
      StrategyVersion.parse({ ...base, code: 'x', rule_tree: { op: 'and' } }),
    ).toThrow(/exactly one/);
  });

  it('round-trips a deployment and a signal', () => {
    roundTrip(Deployment, {
      id: 'dep_01JB3QF7K2ZXQ8M4',
      strategy_version_id: UUID,
      portfolio_id: PF,
      mode: 'paper',
      allocated_capital: '50000',
      deployed_at: TS,
      created_at: TS,
      updated_at: TS,
    });

    const signal = roundTrip(Signal, {
      ts: TS,
      id: UUID,
      deployment_id: 'dep_01JB3QF7K2ZXQ8M4',
      strategy_version_id: UUID,
      instrument_id: INS,
      action: 'enter_long',
      strength: '0.72',
      confidence: '0.55',
      target_weight: '0.04',
      bar_ts: TS,
      generated_at: TS,
    });
    expect(signal.acted_on_at).toBeNull();
  });

  it('round-trips a backtest run with its assumptions', () => {
    roundTrip(BacktestRun, {
      id: 'bt_01JB3QF7K2ZXQ8M4',
      strategy_version_id: UUID,
      requested_by_user_id: USR,
      status: 'completed',
      assumptions: {
        fee_model: 'per_share_0_005',
        slippage_model: 'spread_proportional',
        start_date: '2018-01-01',
        end_date: '2025-12-31',
        universe_definition: { index: 'SP500' },
        sample: 'out_of_sample',
        initial_capital: '100000',
        bar_interval: '1d',
      },
      metrics: {
        total_return: '1.84',
        cagr: '0.152',
        volatility_annualised: '0.181',
        sharpe: '0.84',
        sortino: '1.21',
        calmar: '0.68',
        max_drawdown: '-0.223',
        max_drawdown_duration_days: 214,
        win_rate: '0.56',
        trade_count: 1841,
      },
      created_at: TS,
    });
  });
});

describe('risk contracts', () => {
  it('round-trips a limit and rejects one with two thresholds', () => {
    const limit = {
      id: UUID,
      scope: 'account',
      account_id: ACC,
      kind: 'max_leverage',
      threshold_ratio: '4',
      created_at: TS,
      updated_at: TS,
    };
    roundTrip(RiskLimit, limit);
    expect(() => RiskLimit.parse({ ...limit, threshold_money: '1000' })).toThrow(/exactly one/);
  });

  it('rejects a limit that does not name its target', () => {
    expect(() =>
      RiskLimit.parse({
        id: UUID,
        scope: 'portfolio',
        kind: 'max_drawdown',
        threshold_ratio: '0.2',
        created_at: TS,
        updated_at: TS,
      }),
    ).toThrow(/portfolio/);
  });

  it('round-trips an assessment, a VaR snapshot and greeks', () => {
    roundTrip(RiskAssessment, {
      id: UUID,
      order_id: ORD,
      account_id: ACC,
      verdict: 'approved_with_warnings',
      breaches: [
        {
          kind: 'max_concentration',
          scope: 'portfolio',
          observed: '0.34',
          threshold: '0.30',
          enforcement: 'soft',
          message: 'position would be 34% of the sleeve',
        },
      ],
      evaluated_at: TS,
      duration_ms: 11,
    });

    roundTrip(VarSnapshot, {
      ts: TS,
      account_id: ACC,
      method: 'historical',
      confidence: '0.95',
      horizon_days: 1,
      var_amount: '8420.15',
      var_pct: '0.0204',
    });

    roundTrip(Greeks, {
      as_of: TS,
      delta: '0.54',
      gamma: '0.031',
      theta: '-0.084',
      vega: '0.211',
      rho: '0.092',
    });
  });
});

describe('notification contracts', () => {
  it('round-trips an alert rule', () => {
    roundTrip(AlertRule, {
      id: UUID,
      user_id: USR,
      instrument_id: INS,
      name: 'AAPL above 190',
      trigger_kind: 'price_above',
      comparator: 'above',
      threshold_price: '190',
      channels: ['push'],
      created_at: TS,
      updated_at: TS,
    });
  });

  it('requires exactly one threshold', () => {
    expect(() =>
      AlertRule.parse({
        id: UUID,
        user_id: USR,
        name: 'bad',
        trigger_kind: 'price_above',
        comparator: 'above',
        threshold_price: '190',
        threshold_ratio: '0.05',
        channels: ['push'],
        created_at: TS,
        updated_at: TS,
      }),
    ).toThrow(/exactly one threshold/);
  });

  it('requires a cooldown on a repeating alert', () => {
    expect(() =>
      AlertRule.parse({
        id: UUID,
        user_id: USR,
        name: 'flood',
        trigger_kind: 'price_above',
        comparator: 'above',
        threshold_price: '190',
        channels: ['push'],
        is_repeating: true,
        created_at: TS,
        updated_at: TS,
      }),
    ).toThrow(/cooldown/);
  });

  it('round-trips a watchlist and a notification', () => {
    roundTrip(Watchlist, {
      id: UUID,
      user_id: USR,
      name: 'Megacaps',
      items: [{ instrument_id: INS, added_at: TS }],
      created_at: TS,
      updated_at: TS,
    });

    roundTrip(Notification, {
      id: UUID,
      user_id: USR,
      channel: 'push',
      status: 'delivered',
      topic: 'order.filled',
      title: 'Filled 100 AAPL',
      body: 'Your limit order filled at 183.44',
      idempotency_key: 'ord_01JB3QF7K2ZXQ8M4:filled',
      created_at: TS,
    });
  });

  it('rejects a topic that is not a dotted event key', () => {
    expect(() =>
      Notification.parse({
        id: UUID,
        user_id: USR,
        channel: 'push',
        status: 'sent',
        topic: 'OrderFilled',
        title: 't',
        body: 'b',
        idempotency_key: 'k'.repeat(10),
        created_at: TS,
      }),
    ).toThrow();
  });
});

describe('social contracts', () => {
  it('round-trips a profile with a safe default disclosure', () => {
    const profile = roundTrip(Profile, {
      user_id: USR,
      handle: 'quantkid',
      display_name: 'Quant Kid',
      created_at: TS,
      updated_at: TS,
    });
    // An unconfigured profile must leak nothing.
    expect(profile.performance_disclosure).toBe('none');
    expect(profile.visibility).toBe('public');
  });

  it('rejects a handle outside the spec bounds', () => {
    const base = { user_id: USR, display_name: 'x', created_at: TS, updated_at: TS };
    expect(() => Profile.parse({ ...base, handle: 'ab' })).toThrow();
    expect(() => Profile.parse({ ...base, handle: 'a'.repeat(25) })).toThrow();
    expect(() => Profile.parse({ ...base, handle: 'quant kid' })).toThrow();
  });

  const attachment = {
    id: UUID,
    post_id: 'pst_01JB3QF7K2ZXQ8M4',
    kind: 'trade',
    verification: {
      verdict: 'verified',
      method: 'broker_sync',
      fill_id: 'fil_01JB3QF7K2ZXQ8M4',
      verified_at: TS,
    },
    trade: {
      instrument_id: INS,
      side: 'buy',
      entry_price: '183.22',
      executed_at: TS,
    },
    created_at: TS,
  };

  it('round-trips a verified trade attachment', () => {
    roundTrip(PostAttachment, attachment);
  });

  it('refuses to call an attachment verified without the fill it attests to', () => {
    expect(() =>
      PostAttachment.parse({
        ...attachment,
        verification: { verdict: 'verified', method: null, fill_id: null },
      }),
    ).toThrow(/fill/);
  });

  it('accepts the timeout path as unverified', () => {
    const parsed = PostAttachment.parse({
      ...attachment,
      verification: { verdict: 'unverified' },
    });
    expect(parsed.verification.verdict).toBe('unverified');
  });

  it('requires a reason on a revocation', () => {
    expect(() =>
      PostAttachment.parse({
        ...attachment,
        verification: { verdict: 'revoked', fill_id: 'fil_01JB3QF7K2ZXQ8M4', revoked_at: TS },
      }),
    ).toThrow(/reason/);
  });

  it('requires an attachment to carry the payload its kind promises', () => {
    expect(() => PostAttachment.parse({ ...attachment, kind: 'backtest' })).toThrow(/payload/);
  });

  it('round-trips a post, a follow, a reaction and a report', () => {
    const post = roundTrip(Post, {
      id: 'pst_01JB3QF7K2ZXQ8M4',
      author_user_id: USR,
      kind: 'trade',
      body: 'closed the swing',
      instrument_ids: [INS],
      attachments: [attachment],
      created_at: TS,
    });
    expect(post.reveal_notional).toBe(false);

    roundTrip(Follow, {
      follower_user_id: USR,
      followee_user_id: 'usr_01JB3QF7K2ZXQ8M6',
      state: 'pending',
      requested_at: TS,
    });

    roundTrip(Reaction, {
      post_id: 'pst_01JB3QF7K2ZXQ8M4',
      user_id: USR,
      kind: 'insightful',
      created_at: TS,
    });

    roundTrip(Report, {
      id: UUID,
      target_kind: 'post',
      target_id: 'pst_01JB3QF7K2ZXQ8M4',
      reporter_user_id: USR,
      category: 'market_manipulation',
      created_at: TS,
    });
  });
});

describe('broker contracts', () => {
  const capabilities = {
    read_only: true,
    resources: ['balances', 'positions'],
    supports_lots: false,
  };

  it('round-trips a connection holding only a secret reference', () => {
    const connection = roundTrip(BrokerConnection, {
      id: 'bcx_01JB3QF7K2ZXQ8M4',
      account_id: ACC,
      user_id: USR,
      broker: 'interactive_brokers',
      environment: 'live',
      state: 'active',
      capabilities,
      secret_ref: 'arn:aws:secretsmanager:us-east-1:1234:secret:helios/ibkr/abc',
      created_at: TS,
      updated_at: TS,
    });
    expect(Object.keys(connection)).not.toContain('access_token');
  });

  it("marks a broker without transaction history as unable to source basis", () => {
    const caps = BrokerCapabilities.parse({ read_only: true, resources: ['positions'] });
    expect(caps.resources).not.toContain('transactions');
    // A position from such a connection cannot claim 'sourced' basis.
    expect(() =>
      PositionSnapshot.parse({
        connection_id: 'bcx_01JB3QF7K2ZXQ8M4',
        account_id: ACC,
        raw_symbol: 'AAPL',
        quantity: '120',
        average_price: '183.22',
        currency: 'USD',
        basis_quality: 'sourced',
        lots: [],
        as_of: TS,
      }),
    ).toThrow(/sourced/);
  });

  it('round-trips an estimated-basis position snapshot', () => {
    const snapshot = roundTrip(PositionSnapshot, {
      connection_id: 'bcx_01JB3QF7K2ZXQ8M4',
      account_id: ACC,
      raw_symbol: 'AAPL',
      quantity: '120',
      average_price: '183.22',
      currency: 'USD',
      basis_quality: 'estimated',
      as_of: TS,
    });
    expect(snapshot.lots).toEqual([]);
  });

  it('requires an import preview to account for every row', () => {
    const batch = {
      id: UUID,
      account_id: ACC,
      user_id: USR,
      state: 'previewed',
      filename: 'ibkr-2025.csv',
      byte_size: 40211,
      mapping: { columns: { Symbol: 'raw_symbol', Quantity: 'quantity' } },
      row_count: 10,
      creatable_count: 7,
      duplicate_count: 2,
      rejected_count: 1,
      created_at: TS,
    };
    roundTrip(ImportBatch, batch);
    expect(() => ImportBatch.parse({ ...batch, creatable_count: 6 })).toThrow(/every row/);
  });
});

describe('api envelopes', () => {
  it('maps every error code to a status', () => {
    for (const code of ERROR_CODES) {
      expect(httpStatusFor(code)).toBe(ERROR_STATUS[code]);
      expect(httpStatusFor(code)).toBeGreaterThanOrEqual(400);
    }
  });

  it('answers a blocked relationship with not-found, not forbidden', () => {
    // The social-graph spec: block status must not be disclosed.
    expect(httpStatusFor('not_found')).toBe(404);
  });

  it('round-trips an error envelope', () => {
    roundTrip(ApiError, {
      code: 'validation_failed',
      message: 'quantity is required',
      fields: [{ path: 'quantity', message: 'Required' }],
      request_id: 'req_7f2a91cc',
      trace_id: 'a'.repeat(32),
    });
  });

  it('builds a cursor page for any item schema', () => {
    const page = pageOf(z.object({ id: z.string() }));
    const parsed = page.parse({ items: [{ id: 'a' }], next_cursor: 'b2Zmc2V0LTQy' });
    expect(parsed.total).toBeNull();
    expect(parsed.next_cursor).toBe('b2Zmc2V0LTQy');
  });

  it('flattens a Zod failure into field errors with their paths', () => {
    const result = Order.safeParse({});
    expect(result.success).toBe(false);
    if (!result.success) {
      const fields = toFieldErrors(result.error);
      expect(fields.length).toBeGreaterThan(0);
      expect(fields.every((f) => typeof f.path === 'string')).toBe(true);
    }
  });
});
