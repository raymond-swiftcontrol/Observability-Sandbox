"""Portfolio-level greek aggregation with underlying bucketing.

Summing delta across a book is only meaningful inside a bucket. A delta of
+1,000 on AAPL and -1,000 on XOM is a pair trade, not a flat book, and reporting
"net delta 0" would be actively misleading. So positions are grouped by
:attr:`helios_risk.models.InstrumentRef.risk_underlying_id` — which maps an
option onto its underlying — aggregated inside the bucket, and only the
dollar-denominated measures (delta notional, dollar gamma, vega, theta) are
summed across buckets, because those *are* additive.

Scaling happens exactly once, here: per-unit greeks from the pricer are
multiplied by ``quantity x multiplier``. Doing it in the pricer instead would
make every analytic reference value untestable against a textbook.
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field
from datetime import date
from uuid import UUID

from helios_risk.greeks import black_scholes as bs
from helios_risk.greeks.binomial import crr_greeks
from helios_risk.models import PositionSnapshot

# A year for discounting purposes. Option maturities are quoted in calendar
# time, not trading time; using 252 here would misprice every expiry by ~30%.
DAYS_PER_YEAR = 365.0


@dataclass(frozen=True, slots=True)
class PositionGreeks:
    """One position's contribution, already scaled by quantity and multiplier."""

    position: PositionSnapshot
    greeks: bs.Greeks
    underlying_id: UUID
    underlying_price: float
    # Signed exposure the delta represents, in underlying currency.
    delta_notional: float
    pricing_model: str

    @property
    def symbol(self) -> str:
        return self.position.instrument.symbol


@dataclass(frozen=True, slots=True)
class UnderlyingBucket:
    """Every position whose risk resolves to the same underlying."""

    underlying_id: UUID
    underlying_symbol: str
    underlying_price: float
    positions: tuple[PositionGreeks, ...]
    delta: float  # underlying-equivalent units (shares)
    delta_notional: float
    gamma: float  # d2V/dS2, in currency per unit^2
    vega: float  # per 1.00 of vol
    theta: float  # per year
    rho: float
    market_value: float

    @property
    def dollar_gamma_1pct(self) -> float:
        """P&L from convexity alone on a 1% move in the underlying.

        Raw gamma is in units of currency per squared price, which nobody can
        size a risk limit against. This is the number a trader recognises.
        """
        move = 0.01 * self.underlying_price
        return 0.5 * self.gamma * move * move

    @property
    def theta_per_day(self) -> float:
        return self.theta / DAYS_PER_YEAR

    @property
    def vega_per_point(self) -> float:
        """Vega for a one-percentage-point change in implied vol."""
        return self.vega / 100.0


@dataclass(frozen=True, slots=True)
class PortfolioGreeks:
    buckets: tuple[UnderlyingBucket, ...]
    delta_notional: float
    gross_delta_notional: float
    dollar_gamma_1pct: float
    vega: float
    theta: float
    rho: float
    market_value: float
    unpriced: tuple[str, ...] = field(default=())

    @property
    def vega_per_point(self) -> float:
        return self.vega / 100.0

    @property
    def theta_per_day(self) -> float:
        return self.theta / DAYS_PER_YEAR

    def bucket_for(self, underlying_id: UUID) -> UnderlyingBucket | None:
        for b in self.buckets:
            if b.underlying_id == underlying_id:
                return b
        return None


def position_greeks(
    position: PositionSnapshot,
    as_of: date,
    *,
    risk_free_rate: float,
    dividend_yield: float = 0.0,
    binomial_steps: int = 256,
) -> PositionGreeks:
    """Greeks for one position, scaled by quantity and contract multiplier.

    A non-derivative has delta 1 per unit by definition and no other
    sensitivity; it is included rather than skipped so that a stock hedge
    against an option shows up in the same bucket and nets.
    """
    instrument = position.instrument
    multiplier = instrument.multiplier
    terms = instrument.option

    if terms is None:
        scaled = bs.Greeks(
            price=position.price,
            delta=1.0,
            gamma=0.0,
            vega=0.0,
            theta=0.0,
            rho=0.0,
        ).scaled(position.quantity * multiplier)
        return PositionGreeks(
            position=position,
            greeks=scaled,
            underlying_id=instrument.risk_underlying_id,
            underlying_price=position.price,
            delta_notional=scaled.delta * position.price,
            pricing_model="linear",
        )

    spot = position.underlying_price
    sigma = position.implied_vol
    if spot is None or spot <= 0 or sigma is None or sigma <= 0:
        # Refusing to guess. An option marked without an underlying price or a
        # vol has no computable greeks, and inventing a 20% vol to fill the gap
        # produces a delta that looks authoritative and is not.
        raise ValueError(
            f"{instrument.symbol}: option position needs both an underlying price "
            "and an implied vol to produce greeks"
        )

    t = max((terms.expiration - as_of).days, 0) / DAYS_PER_YEAR
    if terms.exercise_style == "european":
        per_unit = bs.greeks(
            spot, terms.strike, t, risk_free_rate, sigma, terms.option_type, dividend_yield
        )
        model = "black_scholes_merton"
    else:
        # American (and Bermudan, conservatively priced as American): the early
        # exercise premium is real for puts and for calls on a dividend payer.
        per_unit = crr_greeks(
            spot,
            terms.strike,
            t,
            risk_free_rate,
            sigma,
            terms.option_type,
            dividend_yield,
            steps=binomial_steps,
            american=True,
        )
        model = "crr_binomial"

    scaled = per_unit.scaled(position.quantity * multiplier)
    return PositionGreeks(
        position=position,
        greeks=scaled,
        underlying_id=instrument.risk_underlying_id,
        underlying_price=spot,
        delta_notional=scaled.delta * spot,
        pricing_model=model,
    )


def aggregate(
    positions: Iterable[PositionSnapshot],
    as_of: date,
    *,
    risk_free_rate: float,
    dividend_yield: float = 0.0,
    binomial_steps: int = 256,
    underlying_symbols: dict[UUID, str] | None = None,
) -> PortfolioGreeks:
    """Bucket by underlying, aggregate, and report anything that would not price.

    Positions that cannot be priced are named in ``unpriced`` rather than
    dropped. A portfolio greek total that silently excludes three option
    positions is worse than no total at all.
    """
    symbols = underlying_symbols or {}
    by_underlying: dict[UUID, list[PositionGreeks]] = {}
    unpriced: list[str] = []

    for position in positions:
        try:
            pg = position_greeks(
                position,
                as_of,
                risk_free_rate=risk_free_rate,
                dividend_yield=dividend_yield,
                binomial_steps=binomial_steps,
            )
        except ValueError as exc:
            unpriced.append(f"{position.instrument.symbol}: {exc}")
            continue
        by_underlying.setdefault(pg.underlying_id, []).append(pg)

    buckets: list[UnderlyingBucket] = []
    for underlying_id, members in by_underlying.items():
        buckets.append(_build_bucket(underlying_id, members, symbols))

    buckets.sort(key=lambda b: -abs(b.delta_notional))
    return PortfolioGreeks(
        buckets=tuple(buckets),
        delta_notional=sum(b.delta_notional for b in buckets),
        gross_delta_notional=sum(abs(b.delta_notional) for b in buckets),
        dollar_gamma_1pct=sum(b.dollar_gamma_1pct for b in buckets),
        vega=sum(b.vega for b in buckets),
        theta=sum(b.theta for b in buckets),
        rho=sum(b.rho for b in buckets),
        market_value=sum(b.market_value for b in buckets),
        unpriced=tuple(unpriced),
    )


def _build_bucket(
    underlying_id: UUID,
    members: Sequence[PositionGreeks],
    symbols: dict[UUID, str],
) -> UnderlyingBucket:
    # The underlying price is the same for every member by construction, but
    # marks can disagree by a tick between the stock feed and the option feed.
    # The cash position's own mark wins when there is one.
    spot = next(
        (m.underlying_price for m in members if m.position.instrument.option is None),
        members[0].underlying_price,
    )
    symbol = symbols.get(
        underlying_id,
        next(
            (m.symbol for m in members if m.position.instrument.option is None),
            members[0].symbol,
        ),
    )
    return UnderlyingBucket(
        underlying_id=underlying_id,
        underlying_symbol=symbol,
        underlying_price=spot,
        positions=tuple(members),
        delta=sum(m.greeks.delta for m in members),
        delta_notional=sum(m.delta_notional for m in members),
        gamma=sum(m.greeks.gamma for m in members),
        vega=sum(m.greeks.vega for m in members),
        theta=sum(m.greeks.theta for m in members),
        rho=sum(m.greeks.rho for m in members),
        market_value=sum(m.position.market_value for m in members),
    )
