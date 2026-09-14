"""The risk domain's value types.

Two conventions are load-bearing and are stated here once rather than repeated
in every module:

**Signed quantity.** ``book.position`` stores a non-negative ``quantity`` plus a
``side`` enum, because that is what a ledger wants. Risk arithmetic wants a
single signed number: a short is a negative quantity. The loader signs on the
way in (:func:`PositionSnapshot.from_row`) and nothing downstream carries a
side flag. Getting this wrong flips the sign of net exposure and of every
delta, which is exactly the class of bug that survives code review.

**float, not Decimal.** Everything in this service is a threshold comparison or
a distributional estimate, never a posting to the ledger. Carrying
``numeric(28,8)`` through a Cholesky factorisation would be slow and no more
correct — the covariance matrix it factors is an estimate with two significant
figures at best. Money that must balance lives in ``book.*`` and is handled by
Postgres.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime
from enum import StrEnum
from typing import Literal
from uuid import UUID

AssetClass = Literal[
    "equity",
    "etf",
    "adr",
    "fund",
    "option",
    "future",
    "future_option",
    "forex",
    "crypto",
    "crypto_perp",
    "index",
    "bond",
    "commodity",
    "warrant",
    "cfd",
]

Side = Literal["buy", "sell"]
OptionType = Literal["call", "put"]
ExerciseStyle = Literal["american", "european", "bermudan"]

# Mirrors oms.order_type in 0008. Only the subset the gate needs to price is
# enumerated distinctly; the rest fall through to the reference-price path.
OrderType = Literal[
    "market",
    "limit",
    "stop",
    "stop_limit",
    "trailing_stop",
    "market_on_open",
    "market_on_close",
    "limit_on_close",
    "pegged",
    "iceberg",
]

DERIVATIVE_CLASSES: frozenset[str] = frozenset({"option", "future_option"})


class Severity(StrEnum):
    """How a breach is treated, not how bad it feels.

    ``soft`` warns and lets the order through; ``hard`` rejects it; ``critical``
    rejects it *and* trips the kill switch, because a breach of that kind means
    the book is already somewhere it should never have been.
    """

    SOFT = "soft"
    HARD = "hard"
    CRITICAL = "critical"


@dataclass(frozen=True, slots=True)
class OptionTerms:
    """The contract terms needed to price an option position."""

    option_type: OptionType
    strike: float
    expiration: date
    exercise_style: ExerciseStyle = "american"
    contract_size: float = 100.0


@dataclass(frozen=True, slots=True)
class InstrumentRef:
    """The reference-data facts risk needs, denormalised onto one object.

    Deliberately a snapshot rather than a live handle: the pre-trade gate must
    evaluate against a coherent view, and re-reading reference data mid-decision
    is how two rules end up disagreeing about the same instrument.
    """

    instrument_id: UUID
    symbol: str
    asset_class: AssetClass
    currency: str = "USD"
    sector: str | None = None
    country_code: str | None = None
    multiplier: float = 1.0
    is_shortable: bool = False
    is_marginable: bool = False
    maintenance_margin_rate: float = 0.25
    short_borrow_rate_bps: float = 0.0
    adv_30d: float | None = None
    median_spread_bps: float | None = None
    market_cap: float | None = None
    beta: float | None = None
    # Present only for options; the greeks and stress modules branch on it.
    option: OptionTerms | None = None
    underlying_id: UUID | None = None

    @property
    def is_option(self) -> bool:
        return self.option is not None

    @property
    def risk_underlying_id(self) -> UUID:
        """The id positions should be bucketed under for underlying-level risk.

        An option and its underlying are the same risk. Netting a long call
        against a short stock position only works if both hash to the same
        bucket, so every instrument answers this question, not just derivatives.
        """
        return self.underlying_id or self.instrument_id


@dataclass(frozen=True, slots=True)
class PositionSnapshot:
    """One open position, marked.

    ``quantity`` is signed. ``price`` is the mark, not the entry.
    """

    instrument: InstrumentRef
    quantity: float
    price: float
    avg_entry_price: float = 0.0
    marked_at: datetime | None = None
    # Options only: the vol the mark implies, carried so that stress
    # revaluation does not have to re-solve it per scenario.
    implied_vol: float | None = None
    underlying_price: float | None = None

    @property
    def market_value(self) -> float:
        """Signed notional. Negative for shorts, which is what nets correctly."""
        return self.quantity * self.price * self.instrument.multiplier

    @property
    def gross_value(self) -> float:
        return abs(self.market_value)

    @property
    def is_long(self) -> bool:
        return self.quantity > 0

    @property
    def unrealized_pnl(self) -> float:
        return (self.price - self.avg_entry_price) * self.quantity * self.instrument.multiplier


@dataclass(frozen=True, slots=True)
class AccountSnapshot:
    """Everything the pre-trade gate needs about an account, read once.

    The gate takes this as an argument rather than fetching it, which is what
    lets the hot path run against a warm cache and what lets every rule be
    tested in isolation with a hand-built snapshot.
    """

    account_id: UUID
    equity: float
    cash_settled: float
    cash_unsettled: float = 0.0
    cash_reserved: float = 0.0
    buying_power: float = 0.0
    day_trade_buying_power: float = 0.0
    margin_loan: float = 0.0
    maintenance_margin: float = 0.0
    max_leverage: float = 1.0
    options_level: int = 0
    shorting_enabled: bool = False
    crypto_enabled: bool = False
    pdt_restricted: bool = False
    day_trades_used_5d: int = 0
    trading_blocked: bool = False
    trading_blocked_reason: str | None = None
    # P&L windows the loss limits compare against. Negative means a loss.
    pnl_day: float = 0.0
    pnl_week: float = 0.0
    high_water_mark: float = 0.0
    positions: tuple[PositionSnapshot, ...] = ()
    as_of: datetime | None = None

    # ── Derived book aggregates ────────────────────────────────────────────
    @property
    def long_market_value(self) -> float:
        return sum(p.market_value for p in self.positions if p.quantity > 0)

    @property
    def short_market_value(self) -> float:
        """Negative number, matching book.equity_snapshot's sign convention."""
        return sum(p.market_value for p in self.positions if p.quantity < 0)

    @property
    def gross_exposure(self) -> float:
        return sum(p.gross_value for p in self.positions)

    @property
    def net_exposure(self) -> float:
        return sum(p.market_value for p in self.positions)

    @property
    def leverage(self) -> float:
        """Gross exposure over equity. Zero-equity accounts report infinity.

        Returning 0.0 for a wiped-out account would read as "no leverage" and
        pass every leverage limit at the exact moment it should fail them.
        """
        if self.equity <= 0:
            return float("inf") if self.gross_exposure > 0 else 0.0
        return self.gross_exposure / self.equity

    @property
    def drawdown(self) -> float:
        """Fractional drawdown from the high-water mark, as a positive number."""
        if self.high_water_mark <= 0:
            return 0.0
        return max(0.0, (self.high_water_mark - self.equity) / self.high_water_mark)

    def position_for(self, instrument_id: UUID) -> PositionSnapshot | None:
        for p in self.positions:
            if p.instrument.instrument_id == instrument_id:
                return p
        return None

    def exposure_by_sector(self) -> dict[str, float]:
        out: dict[str, float] = {}
        for p in self.positions:
            key = p.instrument.sector or "unclassified"
            out[key] = out.get(key, 0.0) + p.market_value
        return out


@dataclass(frozen=True, slots=True)
class ProposedOrder:
    """An order that has not happened yet.

    ``reference_price`` is what the gate values the order at: the limit price
    for a limit order, the last mark otherwise. It is supplied by the caller
    rather than fetched, because the gate must value the order at the same
    price the order ticket showed the user.
    """

    account_id: UUID
    instrument: InstrumentRef
    side: Side
    quantity: float
    order_type: OrderType = "market"
    reference_price: float = 0.0
    limit_price: float | None = None
    stop_price: float | None = None
    portfolio_id: UUID | None = None
    is_day_trade: bool = False
    # Set when the order is a liquidation the risk engine itself requested.
    # Those must pass even through an engaged kill switch, or a tripped desk
    # can never flatten.
    is_risk_liquidation: bool = False
    client_order_id: str | None = None
    metadata: dict[str, str] = field(default_factory=dict)

    @property
    def signed_quantity(self) -> float:
        return self.quantity if self.side == "buy" else -self.quantity

    @property
    def price(self) -> float:
        """Price to value the order at.

        A limit order can only execute at its limit or better, so the limit is
        the conservative valuation for a buy. For a market order the caller's
        reference price is all there is.
        """
        if self.order_type in ("limit", "stop_limit", "limit_on_close") and self.limit_price:
            return self.limit_price
        return self.reference_price

    @property
    def notional(self) -> float:
        """Absolute notional, including the contract multiplier."""
        return abs(self.quantity) * self.price * self.instrument.multiplier

    @property
    def signed_notional(self) -> float:
        return self.signed_quantity * self.price * self.instrument.multiplier
