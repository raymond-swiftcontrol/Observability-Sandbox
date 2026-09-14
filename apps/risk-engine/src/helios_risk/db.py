"""Async engine management and the SQLAlchemy Core table definitions.

Core, not the ORM: every query in this service is either a narrow hot-path read
(the pre-trade gate's account snapshot) or an analytical aggregate over
positions. An identity map buys nothing for either and hides the SQL that
actually runs on the order path.

The table definitions mirror ``db/migrations/`` — column names and schemas are
the contract, and building queries from these objects rather than f-strings is
what makes a typo a load-time error instead of a 3am incident.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine, create_async_engine

from helios_risk.config import Settings

METADATA = sa.MetaData()

# ── reference ────────────────────────────────────────────────────────────────
instrument = sa.Table(
    "instrument",
    METADATA,
    sa.Column("id", sa.Uuid, primary_key=True),
    sa.Column("symbol", sa.String(32)),
    sa.Column("asset_class", sa.Text),
    sa.Column("currency", sa.String(3)),
    sa.Column("status", sa.Text),
    sa.Column("sector_id", sa.SmallInteger),
    sa.Column("country_code", sa.String(2)),
    sa.Column("multiplier", sa.Numeric),
    sa.Column("is_shortable", sa.Boolean),
    sa.Column("is_marginable", sa.Boolean),
    sa.Column("maintenance_margin_rate", sa.Numeric),
    sa.Column("short_borrow_rate_bps", sa.Numeric),
    sa.Column("adv_30d", sa.Numeric),
    sa.Column("median_spread_bps", sa.Numeric),
    sa.Column("market_cap", sa.Numeric),
    schema="reference",
)

option_contract = sa.Table(
    "option_contract",
    METADATA,
    sa.Column("instrument_id", sa.Uuid, primary_key=True),
    sa.Column("underlying_id", sa.Uuid),
    sa.Column("option_type", sa.Text),
    sa.Column("strike", sa.Numeric),
    sa.Column("expiration_date", sa.Date),
    sa.Column("exercise_style", sa.Text),
    sa.Column("contract_size", sa.Numeric),
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

# ── book ─────────────────────────────────────────────────────────────────────
account = sa.Table(
    "account",
    METADATA,
    sa.Column("id", sa.Uuid, primary_key=True),
    sa.Column("public_id", sa.Text),
    sa.Column("owner_user_id", sa.Uuid),
    sa.Column("account_type", sa.Text),
    sa.Column("status", sa.Text),
    sa.Column("base_currency", sa.String(3)),
    sa.Column("max_leverage", sa.Numeric),
    sa.Column("day_trade_buying_power_multiple", sa.Numeric),
    sa.Column("pdt_restricted", sa.Boolean),
    sa.Column("day_trades_used_5d", sa.SmallInteger),
    sa.Column("options_level", sa.SmallInteger),
    sa.Column("shorting_enabled", sa.Boolean),
    sa.Column("crypto_enabled", sa.Boolean),
    sa.Column("trading_blocked", sa.Boolean),
    sa.Column("trading_blocked_reason", sa.Text),
    schema="book",
)

cash_balance = sa.Table(
    "cash_balance",
    METADATA,
    sa.Column("account_id", sa.Uuid),
    sa.Column("currency", sa.String(3)),
    sa.Column("settled", sa.Numeric),
    sa.Column("unsettled", sa.Numeric),
    sa.Column("reserved", sa.Numeric),
    sa.Column("margin_loan", sa.Numeric),
    sa.Column("buying_power", sa.Numeric),
    sa.Column("day_trade_buying_power", sa.Numeric),
    schema="book",
)

position = sa.Table(
    "position",
    METADATA,
    sa.Column("id", sa.Uuid, primary_key=True),
    sa.Column("account_id", sa.Uuid),
    sa.Column("portfolio_id", sa.Uuid),
    sa.Column("instrument_id", sa.Uuid),
    sa.Column("side", sa.Text),
    sa.Column("quantity", sa.Numeric),
    sa.Column("avg_entry_price", sa.Numeric),
    sa.Column("last_price", sa.Numeric),
    sa.Column("marked_at", sa.DateTime(timezone=True)),
    sa.Column("market_value", sa.Numeric),
    sa.Column("cost_basis", sa.Numeric),
    sa.Column("unrealized_pnl", sa.Numeric),
    sa.Column("multiplier", sa.Numeric),
    sa.Column("delta_adjusted_qty", sa.Numeric),
    sa.Column("closed_at", sa.DateTime(timezone=True)),
    schema="book",
)

equity_snapshot = sa.Table(
    "equity_snapshot",
    METADATA,
    sa.Column("ts", sa.DateTime(timezone=True)),
    sa.Column("account_id", sa.Uuid),
    sa.Column("portfolio_id", sa.Uuid),
    sa.Column("equity", sa.Numeric),
    sa.Column("cash", sa.Numeric),
    sa.Column("long_market_value", sa.Numeric),
    sa.Column("short_market_value", sa.Numeric),
    sa.Column("gross_exposure", sa.Numeric),
    sa.Column("net_exposure", sa.Numeric),
    sa.Column("leverage", sa.Numeric),
    sa.Column("maintenance_margin", sa.Numeric),
    sa.Column("realized_pnl_day", sa.Numeric),
    sa.Column("unrealized_pnl", sa.Numeric),
    sa.Column("return_net", sa.Numeric),
    sa.Column("high_water_mark", sa.Numeric),
    sa.Column("drawdown", sa.Numeric),
    schema="book",
)

# ── market ───────────────────────────────────────────────────────────────────
bar_1d = sa.Table(
    "bar_1d",
    METADATA,
    sa.Column("ts", sa.DateTime(timezone=True)),
    sa.Column("instrument_id", sa.Uuid),
    sa.Column("close", sa.Numeric),
    sa.Column("return_log", sa.Numeric),
    sa.Column("return_simple", sa.Numeric),
    schema="market",
)

option_quote = sa.Table(
    "option_quote",
    METADATA,
    sa.Column("ts", sa.DateTime(timezone=True)),
    sa.Column("instrument_id", sa.Uuid),
    sa.Column("underlying_id", sa.Uuid),
    sa.Column("bid", sa.Numeric),
    sa.Column("ask", sa.Numeric),
    sa.Column("underlying_price", sa.Numeric),
    sa.Column("implied_vol", sa.Numeric),
    sa.Column("risk_free_rate", sa.Numeric),
    sa.Column("dividend_yield", sa.Numeric),
    schema="market",
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

    @property
    def connected(self) -> bool:
        return self._engine is not None

    async def connect(self) -> None:
        s = self._settings
        self._engine = create_async_engine(
            _asyncpg_url(s.database_url),
            pool_size=s.database_pool_max,
            max_overflow=0,
            pool_pre_ping=True,
            connect_args={
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
        if self._engine is None:
            return False
        try:
            async with self.engine.connect() as conn:
                await conn.execute(sa.text("SELECT 1"))
        except Exception:  # noqa: BLE001 - readiness must never raise
            return False
        return True


def _asyncpg_url(url: str) -> str:
    """Rewrite a libpq URL for the asyncpg driver.

    ``sslmode`` is a libpq spelling that asyncpg rejects outright; it is dropped
    here rather than half-translated, and TLS belongs on connect_args.
    """
    plain = url.replace("postgresql+asyncpg://", "postgresql://")
    base, _, query = plain.partition("?")
    kept = [kv for kv in query.split("&") if kv and not kv.startswith("sslmode=")]
    out = base.replace("postgresql://", "postgresql+asyncpg://", 1)
    return f"{out}?{'&'.join(kept)}" if kept else out
