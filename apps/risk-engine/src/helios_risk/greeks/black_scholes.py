"""Black-Scholes-Merton analytic pricing and greeks.

Merton's continuous-dividend form throughout: an equity index carries a
dividend yield and an FX option carries a foreign rate, and both enter the same
way. Setting ``q = 0`` recovers plain Black-Scholes, so there is one code path
rather than two that can drift apart.

Conventions, stated once because every greek library picks differently and
mixing conventions is how a vega gets reported 100x too large:

* ``t`` is time to expiry in **years**.
* ``sigma``, ``r`` and ``q`` are **annualised, continuously compounded**.
* ``vega`` is per **1.00** of vol (i.e. 100 vol points). Divide by 100 for the
  "per vol point" number a trader quotes.
* ``theta`` is per **year**. Divide by 365 for a calendar-day theta.
* ``rho`` is per **1.00** of rate.
* ``charm`` is ``d(delta)/dt`` where ``t`` is time to expiry, so a position
  losing delta as expiry approaches has positive charm here. The sign is
  pinned by a finite-difference test rather than by assertion.

Degenerate inputs are not errors. At ``t <= 0`` an option is worth its
intrinsic value and its delta is a step function; at ``sigma <= 0`` the
underlying is deterministic. Both are returned exactly rather than nudged, so a
portfolio containing an expiring option still aggregates.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from helios_risk.models import OptionType

_INV_SQRT_2PI = 1.0 / math.sqrt(2.0 * math.pi)
_INV_SQRT_2 = 1.0 / math.sqrt(2.0)


def norm_cdf(x: float) -> float:
    """Standard normal CDF via ``erfc``.

    ``erfc`` rather than ``0.5 * (1 + erf(x/sqrt2))`` because the latter loses
    all relative precision in the left tail, which is exactly where a deep
    out-of-the-money option's delta lives.
    """
    return 0.5 * math.erfc(-x * _INV_SQRT_2)


def norm_pdf(x: float) -> float:
    return _INV_SQRT_2PI * math.exp(-0.5 * x * x)


@dataclass(frozen=True, slots=True)
class Greeks:
    """Per-unit-of-underlying greeks. Scaling by contract size happens later."""

    price: float
    delta: float
    gamma: float
    vega: float
    theta: float
    rho: float
    vanna: float = 0.0
    volga: float = 0.0
    charm: float = 0.0

    def scaled(self, factor: float) -> Greeks:
        """Multiply every sensitivity by ``factor`` (quantity x contract size)."""
        return Greeks(
            price=self.price * factor,
            delta=self.delta * factor,
            gamma=self.gamma * factor,
            vega=self.vega * factor,
            theta=self.theta * factor,
            rho=self.rho * factor,
            vanna=self.vanna * factor,
            volga=self.volga * factor,
            charm=self.charm * factor,
        )


def d1_d2(S: float, K: float, t: float, r: float, sigma: float, q: float) -> tuple[float, float]:
    sqrt_t = math.sqrt(t)
    d1 = (math.log(S / K) + (r - q + 0.5 * sigma * sigma) * t) / (sigma * sqrt_t)
    return d1, d1 - sigma * sqrt_t


def forward(S: float, t: float, r: float, q: float) -> float:
    """The forward price. Every degenerate branch below prices off this."""
    return S * math.exp((r - q) * t)


def price(
    S: float,
    K: float,
    t: float,
    r: float,
    sigma: float,
    option_type: OptionType,
    q: float = 0.0,
) -> float:
    """European option value under BSM."""
    if S <= 0 or K <= 0:
        raise ValueError("spot and strike must be positive")
    if t <= 0 or sigma <= 0:
        # Deterministic: the option is worth the discounted payoff of the
        # forward. At t == 0 the forward is the spot and this is the intrinsic.
        f = forward(S, t, r, q) if t > 0 else S
        payoff = max(f - K, 0.0) if option_type == "call" else max(K - f, 0.0)
        return math.exp(-r * max(t, 0.0)) * payoff
    d1, d2 = d1_d2(S, K, t, r, sigma, q)
    df_r = math.exp(-r * t)
    df_q = math.exp(-q * t)
    if option_type == "call":
        return S * df_q * norm_cdf(d1) - K * df_r * norm_cdf(d2)
    return K * df_r * norm_cdf(-d2) - S * df_q * norm_cdf(-d1)


def greeks(
    S: float,
    K: float,
    t: float,
    r: float,
    sigma: float,
    option_type: OptionType,
    q: float = 0.0,
) -> Greeks:
    """Analytic greeks. See the module docstring for units."""
    if S <= 0 or K <= 0:
        raise ValueError("spot and strike must be positive")

    if t <= 0 or sigma <= 0:
        return _degenerate_greeks(S, K, t, r, sigma, option_type, q)

    sqrt_t = math.sqrt(t)
    d1, d2 = d1_d2(S, K, t, r, sigma, q)
    df_r = math.exp(-r * t)
    df_q = math.exp(-q * t)
    pdf_d1 = norm_pdf(d1)

    # Shared between calls and puts: the underlying's diffusion does not know
    # which side of the contract you are on.
    gamma = df_q * pdf_d1 / (S * sigma * sqrt_t)
    vega = S * df_q * pdf_d1 * sqrt_t
    vanna = -df_q * pdf_d1 * d2 / sigma
    volga = vega * d1 * d2 / sigma
    # d(d1)/dt with t = time to expiry.
    dd1_dt = -math.log(S / K) / (2.0 * sigma * t * sqrt_t) + (r - q + 0.5 * sigma * sigma) / (
        2.0 * sigma * sqrt_t
    )

    if option_type == "call":
        n_d1, n_d2 = norm_cdf(d1), norm_cdf(d2)
        px = S * df_q * n_d1 - K * df_r * n_d2
        delta = df_q * n_d1
        theta = (
            -S * df_q * pdf_d1 * sigma / (2.0 * sqrt_t)
            - r * K * df_r * n_d2
            + q * S * df_q * n_d1
        )
        rho = K * t * df_r * n_d2
        charm = -q * df_q * n_d1 + df_q * pdf_d1 * dd1_dt
    else:
        n_md1, n_md2 = norm_cdf(-d1), norm_cdf(-d2)
        px = K * df_r * n_md2 - S * df_q * n_md1
        delta = -df_q * n_md1
        theta = (
            -S * df_q * pdf_d1 * sigma / (2.0 * sqrt_t)
            + r * K * df_r * n_md2
            - q * S * df_q * n_md1
        )
        rho = -K * t * df_r * n_md2
        charm = q * df_q * n_md1 + df_q * pdf_d1 * dd1_dt

    return Greeks(
        price=px,
        delta=delta,
        gamma=gamma,
        vega=vega,
        theta=theta,
        rho=rho,
        vanna=vanna,
        volga=volga,
        charm=charm,
    )


def _degenerate_greeks(
    S: float,
    K: float,
    t: float,
    r: float,
    sigma: float,
    option_type: OptionType,
    q: float,
) -> Greeks:
    """Expiry, or zero vol: the payoff is a step and the greeks are its derivative.

    Delta is reported as the indicator of being in the money, which is the
    right-hand limit. An exactly-at-the-money expiring option has no delta
    limit at all; 0.5 is returned because it is the only choice that keeps
    put-call parity (``delta_call - delta_put == 1``) intact.
    """
    f = forward(S, t, r, q) if t > 0 else S
    df = math.exp(-r * max(t, 0.0))
    if option_type == "call":
        intrinsic = max(f - K, 0.0)
        delta = 1.0 if f > K else (0.5 if f == K else 0.0)
    else:
        intrinsic = max(K - f, 0.0)
        delta = -1.0 if f < K else (-0.5 if f == K else 0.0)
    return Greeks(
        price=df * intrinsic,
        delta=delta * math.exp(-q * max(t, 0.0)),
        gamma=0.0,
        vega=0.0,
        theta=0.0,
        rho=0.0,
    )


def put_call_parity_residual(
    call_price: float,
    put_price: float,
    S: float,
    K: float,
    t: float,
    r: float,
    q: float = 0.0,
) -> float:
    """``C - P - (S e^-qt - K e^-rt)``. Zero for an arbitrage-free European pair.

    Exposed rather than kept in the tests because it is the cheapest possible
    sanity check on a vendor's option marks, and the stress module uses it to
    refuse a chain that does not price.
    """
    return call_price - put_price - (S * math.exp(-q * t) - K * math.exp(-r * t))
