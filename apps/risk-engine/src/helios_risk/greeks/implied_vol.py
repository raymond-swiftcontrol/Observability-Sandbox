"""Implied volatility: Newton with a guaranteed-bracketing bisection fallback.

Newton on vega is fast where vega is meaningful and useless where it is not —
deep in or out of the money, vega collapses and the Newton step explodes. The
solver therefore always maintains a bracket and falls back to bisection
whenever a Newton step would leave it.

The contract that matters: **this function either converges to the stated
tolerance or raises.** It never returns its last iterate. An implied vol that
is quietly wrong propagates into every greek, into delta-adjusted exposure and
into the stress revaluation, where nothing distinguishes it from a real number.
"""

from __future__ import annotations

import math
from typing import Final

from helios_risk.errors import ConvergenceError, ValidationError
from helios_risk.greeks import black_scholes as bs
from helios_risk.greeks.binomial import crr_price
from helios_risk.models import OptionType

MIN_VOL: Final = 1e-6
MAX_VOL: Final = 5.0  # 500% — beyond this the quote is a data error, not a vol
DEFAULT_TOL: Final = 1e-8
DEFAULT_MAX_ITER: Final = 100


def _no_arbitrage_bounds(
    S: float, K: float, t: float, r: float, option_type: OptionType, q: float
) -> tuple[float, float]:
    """(lower, upper) on a European price. Outside these, no vol exists."""
    df_r, df_q = math.exp(-r * t), math.exp(-q * t)
    if option_type == "call":
        return max(0.0, S * df_q - K * df_r), S * df_q
    return max(0.0, K * df_r - S * df_q), K * df_r


def implied_vol(
    target_price: float,
    S: float,
    K: float,
    t: float,
    r: float,
    option_type: OptionType,
    q: float = 0.0,
    *,
    tol: float = DEFAULT_TOL,
    max_iter: int = DEFAULT_MAX_ITER,
) -> float:
    """Solve BSM for sigma. Raises rather than returning an unconverged value."""
    if t <= 0:
        raise ValidationError(
            "an expired option has no implied volatility", time_to_expiry=t
        )
    if S <= 0 or K <= 0:
        raise ValidationError("spot and strike must be positive", spot=S, strike=K)

    lower, upper = _no_arbitrage_bounds(S, K, t, r, option_type, q)
    if target_price < lower - 1e-10:
        raise ValidationError(
            "option price is below its no-arbitrage floor; no volatility can produce it",
            price=target_price,
            floor=lower,
        )
    if target_price > upper + 1e-10:
        raise ValidationError(
            "option price is above its no-arbitrage ceiling; no volatility can produce it",
            price=target_price,
            ceiling=upper,
        )
    if abs(target_price - lower) <= tol:
        # Exactly at intrinsic: the limit as sigma goes to zero. Returning
        # MIN_VOL rather than 0 keeps every downstream division safe.
        return MIN_VOL

    def f(sigma: float) -> float:
        return bs.price(S, K, t, r, sigma, option_type, q) - target_price

    lo, hi = MIN_VOL, MAX_VOL
    f_lo, f_hi = f(lo), f(hi)
    if f_lo > 0 or f_hi < 0:
        # Price is monotonically increasing in sigma, so this means the target
        # sits outside [price(MIN_VOL), price(MAX_VOL)] despite passing the
        # arbitrage bounds — a 500%-vol quote, or a bad rate.
        raise ConvergenceError(
            "target price is not attainable within the supported volatility range",
            price=target_price,
            vol_range=[MIN_VOL, MAX_VOL],
            price_range=[target_price + f_lo, target_price + f_hi],
        )

    # Brenner-Subrahmanyam: for an at-the-money option, price ~ 0.4 * S * sigma
    # * sqrt(t). A bad guess costs iterations, never correctness.
    sigma = max(MIN_VOL, min(MAX_VOL, math.sqrt(2.0 * math.pi / t) * target_price / S))

    for _ in range(max_iter):
        value = f(sigma)
        if abs(value) < tol:
            return sigma
        if value > 0:
            hi = sigma
        else:
            lo = sigma

        vega = bs.greeks(S, K, t, r, sigma, option_type, q).vega
        step_ok = vega > 1e-10
        if step_ok:
            candidate = sigma - value / vega
            step_ok = lo < candidate < hi and math.isfinite(candidate)
        sigma = candidate if step_ok else 0.5 * (lo + hi)

        if hi - lo < tol * 1e-2:
            # The bracket has collapsed. Accept only if the price matches;
            # otherwise the function is flat here and there is no solution.
            if abs(f(sigma)) < max(tol, 1e-6):
                return sigma
            break

    raise ConvergenceError(
        "implied volatility failed to converge",
        price=target_price,
        spot=S,
        strike=K,
        time_to_expiry=t,
        last_sigma=sigma,
        bracket=[lo, hi],
        iterations=max_iter,
    )


def implied_vol_american(
    target_price: float,
    S: float,
    K: float,
    t: float,
    r: float,
    option_type: OptionType,
    q: float = 0.0,
    *,
    steps: int = 128,
    tol: float = 1e-6,
    max_iter: int = 80,
) -> float:
    """Implied vol against a CRR American price, by bisection only.

    No Newton: there is no analytic vega on a tree, and a bumped vega costs two
    extra trees per iteration — more than bisection's extra iterations. The
    tolerance is looser than the European solver's because the tree itself has
    discretisation error of that order, and claiming 1e-8 against a 1e-6 price
    would be false precision.
    """
    if t <= 0:
        raise ValidationError("an expired option has no implied volatility", time_to_expiry=t)

    def f(sigma: float) -> float:
        return crr_price(S, K, t, r, sigma, option_type, q, steps=steps, american=True) - (
            target_price
        )

    lo, hi = MIN_VOL, MAX_VOL
    f_lo, f_hi = f(lo), f(hi)
    if f_lo > 0 or f_hi < 0:
        raise ConvergenceError(
            "target American price is not attainable within the supported volatility range",
            price=target_price,
            vol_range=[MIN_VOL, MAX_VOL],
        )

    for _ in range(max_iter):
        mid = 0.5 * (lo + hi)
        value = f(mid)
        if abs(value) < tol or (hi - lo) < tol:
            return mid
        if value > 0:
            hi = mid
        else:
            lo = mid

    raise ConvergenceError(
        "American implied volatility failed to converge",
        price=target_price,
        bracket=[lo, hi],
        iterations=max_iter,
    )
