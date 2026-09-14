"""Async engine management and the SQLAlchemy Core table definitions.

Core, not the ORM: every query in this service is an analytical read over
hypertables, frequently with window functions and ``time_bucket``. An identity
map and unit of work buy nothing here and obscure the SQL that actually runs.

The table definitions below mirror ``db/migrations/`` exactly. They exist so
that queries are built from checked names rather than f-strings, and so the
lookahead test-suite can compile a query and inspect its predicates.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine, create_async_engine

from helios_quant.config import Settings

METADATA = sa.MetaData()

# ── reference ────────────────────────────────────────────────────────────────
instrument = sa.Table(
    "instrument",
    METADATA,
    sa.Column("id", sa.Uuid, primary_key=True),
    sa.Column("public_id", sa.Text),
    sa.Column("symbol", sa.String(32)),
    sa.Column("venue_id", sa.SmallInteger),
    sa.Column("asset_class", sa.Text),
    sa.Column("name", sa.String(200)),
    sa.Column("currency", sa.String(3)),
    sa.Column("calendar_id", sa.SmallInteger),
    sa.Column("status", sa.Text),
    sa.Column("sector_id", sa.SmallInteger),
    sa.Column("country_code", sa.String(2)),
    sa.Column("multiplier", sa.Numeric),
    sa.Column("is_shortable", sa.Boolean),
    sa.Column("is_marginable", sa.Boolean),
    sa.Column("short_borrow_rate_bps", sa.Numeric),
    sa.Column("adv_30d", sa.Numeric),
    sa.Column("median_spread_bps", sa.Numeric),
    sa.Column("market_cap", sa.Numeric),
    sa.Column("listed_on", sa.Date),
    sa.Column("delisted_on", sa.Date),
    sa.Column("data_start_date", sa.Date),
    schema="reference",
)

index_constituent = sa.Table(
    "index_constituent",
    METADATA,
    sa.Column("index_id", sa.Uuid),
    sa.Column("instrument_id", sa.Uuid),
    sa.Column("valid_from", sa.Date),
    sa.Column("valid_to", sa.Date),
    sa.Column("weight", sa.Numeric),
    sa.Column("shares", sa.Numeric),
    schema="reference",
)

corporate_action = sa.Table(
    "corporate_action",
    METADATA,
    sa.Column("id", sa.Uuid, primary_key=True),
    sa.Column("instrument_id", sa.Uuid),
    sa.Column("action_type", sa.Text),
    sa.Column("ex_date", sa.Date),
    sa.Column("payable_date", sa.Date),
    sa.Column("split_ratio", sa.Numeric),
    sa.Column("price_factor", sa.Numeric),
    sa.Column("volume_factor", sa.Numeric),
    sa.Column("cash_amount", sa.Numeric),
    sa.Column("cash_currency", sa.String(3)),
    schema="reference",
)

trading_session = sa.Table(
    "trading_session",
    METADATA,
    sa.Column("calendar_id", sa.SmallInteger),
    sa.Column("session_date", sa.Date),
    sa.Column("is_half_day", sa.Boolean),
    schema="reference",
)

sector = sa.Table(
    "sector",
    METADATA,
    sa.Column("id", sa.SmallInteger, primary_key=True),
    sa.Column("gics_code", sa.String(8)),
    sa.Column("level", sa.SmallInteger),
    sa.Column("name", sa.String(80)),
    sa.Column("parent_id", sa.SmallInteger),
    schema="reference",
)

# ── market ───────────────────────────────────────────────────────────────────
bar_1d = sa.Table(
    "bar_1d",
    METADATA,
    sa.Column("ts", sa.DateTime(timezone=True)),
    sa.Column("instrument_id", sa.Uuid),
    sa.Column("open", sa.Numeric),
    sa.Column("high", sa.Numeric),
    sa.Column("low", sa.Numeric),
    sa.Column("close", sa.Numeric),
    sa.Column("volume", sa.Numeric),
    sa.Column("trade_count", sa.Integer),
    sa.Column("vwap", sa.Numeric),
    sa.Column("official_close", sa.Numeric),
    sa.Column("prev_close", sa.Numeric),
    sa.Column("return_simple", sa.Numeric),
    sa.Column("return_log", sa.Numeric),
    sa.Column("gap_pct", sa.Numeric),
    sa.Column("true_range", sa.Numeric),
    sa.Column("dollar_volume", sa.Numeric),
    sa.Column("quality", sa.Text),
    schema="market",
)

bar_1m = sa.Table(
    "bar_1m",
    METADATA,
    sa.Column("ts", sa.DateTime(timezone=True)),
    sa.Column("instrument_id", sa.Uuid),
    sa.Column("open", sa.Numeric),
    sa.Column("high", sa.Numeric),
    sa.Column("low", sa.Numeric),
    sa.Column("close", sa.Numeric),
    sa.Column("volume", sa.Numeric),
    sa.Column("trade_count", sa.Integer),
    sa.Column("vwap", sa.Numeric),
    sa.Column("session", sa.String(12)),
    sa.Column("quality", sa.Text),
    schema="market",
)

quote = sa.Table(
    "quote",
    METADATA,
    sa.Column("ts", sa.DateTime(timezone=True)),
    sa.Column("instrument_id", sa.Uuid),
    sa.Column("bid_price", sa.Numeric),
    sa.Column("bid_size", sa.Numeric),
    sa.Column("ask_price", sa.Numeric),
    sa.Column("ask_size", sa.Numeric),
    sa.Column("spread", sa.Numeric),
    sa.Column("mid", sa.Numeric),
    schema="market",
)

# ── fundamental ──────────────────────────────────────────────────────────────
company_snapshot = sa.Table(
    "company_snapshot",
    METADATA,
    sa.Column("instrument_id", sa.Uuid),
    # as_of is "when the market could know this". Research filters on it; see
    # the COMMENT in 0006. period_end is for display and grouping only.
    sa.Column("as_of", sa.Date),
    sa.Column("filing_id", sa.Uuid),
    sa.Column("period_end", sa.Date),
    sa.Column("market_cap", sa.Numeric),
    sa.Column("enterprise_value", sa.Numeric),
    sa.Column("pe_ratio", sa.Numeric),
    sa.Column("forward_pe", sa.Numeric),
    sa.Column("pb_ratio", sa.Numeric),
    sa.Column("ps_ratio", sa.Numeric),
    sa.Column("ev_ebitda", sa.Numeric),
    sa.Column("ev_sales", sa.Numeric),
    sa.Column("fcf_yield", sa.Numeric),
    sa.Column("earnings_yield", sa.Numeric),
    sa.Column("dividend_yield", sa.Numeric),
    sa.Column("payout_ratio", sa.Numeric),
    sa.Column("gross_margin", sa.Numeric),
    sa.Column("operating_margin", sa.Numeric),
    sa.Column("net_margin", sa.Numeric),
    sa.Column("roe", sa.Numeric),
    sa.Column("roa", sa.Numeric),
    sa.Column("roic", sa.Numeric),
    sa.Column("asset_turnover", sa.Numeric),
    sa.Column("accruals_ratio", sa.Numeric),
    sa.Column("debt_to_equity", sa.Numeric),
    sa.Column("net_debt_ebitda", sa.Numeric),
    sa.Column("current_ratio", sa.Numeric),
    sa.Column("quick_ratio", sa.Numeric),
    sa.Column("interest_coverage", sa.Numeric),
    sa.Column("revenue_growth", sa.Numeric),
    sa.Column("earnings_growth", sa.Numeric),
    sa.Column("fcf_growth", sa.Numeric),
    sa.Column("piotroski_f_score", sa.SmallInteger),
    sa.Column("altman_z_score", sa.Numeric),
    sa.Column("quality_score", sa.Numeric),
    sa.Column("value_score", sa.Numeric),
    sa.Column("shares_outstanding", sa.Numeric),
    sa.Column("shares_diluted", sa.Numeric),
    schema="fundamental",
)

estimate = sa.Table(
    "estimate",
    METADATA,
    sa.Column("instrument_id", sa.Uuid),
    sa.Column("as_of", sa.Date),
    sa.Column("fiscal_year", sa.SmallInteger),
    sa.Column("fiscal_period", sa.Text),
    sa.Column("metric_key", sa.String(48)),
    sa.Column("mean_estimate", sa.Numeric),
    sa.Column("median_estimate", sa.Numeric),
    sa.Column("std_dev", sa.Numeric),
    sa.Column("analyst_count", sa.SmallInteger),
    sa.Column("revision_30d", sa.Numeric),
    sa.Column("revision_90d", sa.Numeric),
    schema="fundamental",
)

corporate_event = sa.Table(
    "corporate_event",
    METADATA,
    sa.Column("id", sa.Uuid, primary_key=True),
    sa.Column("instrument_id", sa.Uuid),
    sa.Column("event_type", sa.Text),
    sa.Column("scheduled_at", sa.DateTime(timezone=True)),
    sa.Column("timing_hint", sa.String(16)),
    sa.Column("is_confirmed", sa.Boolean),
    sa.Column("eps_estimate", sa.Numeric),
    sa.Column("eps_actual", sa.Numeric),
    sa.Column("eps_surprise_pct", sa.Numeric),
    sa.Column("price_reaction_pct", sa.Numeric),
    sa.Column("implied_move_pct", sa.Numeric),
    schema="fundamental",
)

short_interest = sa.Table(
    "short_interest",
    METADATA,
    sa.Column("instrument_id", sa.Uuid),
    sa.Column("settlement_date", sa.Date),
    # FINRA publishes with an ~8 day lag. published_at is the only honest filter.
    sa.Column("published_at", sa.Date),
    sa.Column("shares_short", sa.Numeric),
    sa.Column("days_to_cover", sa.Numeric),
    sa.Column("pct_of_float", sa.Numeric),
    sa.Column("borrow_fee_bps", sa.Numeric),
    sa.Column("utilization_pct", sa.Numeric),
    schema="fundamental",
)

macro_series = sa.Table(
    "macro_series",
    METADATA,
    sa.Column("id", sa.SmallInteger, primary_key=True),
    sa.Column("code", sa.String(32)),
    sa.Column("name", sa.String(160)),
    sa.Column("frequency", sa.String(16)),
    sa.Column("release_lag_days", sa.SmallInteger),
    sa.Column("is_rate", sa.Boolean),
    schema="fundamental",
)

# The first-print view, not macro_observation. Revisions embed information that
# was published later; a backtest reading them is reading the future.
macro_first_print = sa.Table(
    "macro_first_print",
    METADATA,
    sa.Column("series_id", sa.SmallInteger),
    sa.Column("observed_on", sa.Date),
    sa.Column("published_at", sa.Date),
    sa.Column("value", sa.Numeric),
    schema="fundamental",
)


class Database:
    """Owns the async engine. One instance per process, created in the lifespan."""

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._engine: AsyncEngine | None = None

    @property
    def engine(self) -> AsyncEngine:
        if self._engine is None:
            raise RuntimeError("Database.connect() has not been called")
        return self._engine

    async def connect(self) -> None:
        s = self._settings
        self._engine = create_async_engine(
            s.database_url,
            pool_size=s.database_pool_max,
            max_overflow=0,
            pool_pre_ping=True,
            connect_args={
                # A research query that runs away takes the pool with it. The
                # statement timeout is the backstop; the analytical endpoints
                # also page their results.
                "server_settings": {
                    "statement_timeout": str(s.database_statement_timeout_ms),
                    "application_name": s.service_name,
                    "timezone": "UTC",
                }
            },
        )

    async def disconnect(self) -> None:
        if self._engine is not None:
            await self._engine.dispose()
            self._engine = None

    @asynccontextmanager
    async def begin(self) -> AsyncIterator[AsyncConnection]:
        async with self.engine.begin() as conn:
            yield conn

    async def healthy(self) -> bool:
        try:
            async with self.engine.connect() as conn:
                await conn.execute(sa.text("SELECT 1"))
        except Exception:  # noqa: BLE001 - readiness must never raise
            return False
        return True
