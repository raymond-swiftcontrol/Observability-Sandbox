"""Cox-Ross-Rubinstein binomial tree for American exercise.

Analytic BSM prices a European claim; an American option is worth at least as
much because of the early-exercise right, and for an American put that
difference is material — it is not a rounding correction that can be ignored.

The tree is recombining and the backward induction is vectorised over each
time slice, so the cost is O(steps^2) in arithmetic but O(steps) in memory.
``steps=256`` is the default: CRR converges as O(1/steps) with an oscillation
between odd and even step counts, and at 256 the residual against a fine tree
is well inside a tick for the strikes and maturities this desk trades.

Greeks come off the tree for delta, gamma and theta — those three are available
for free from nodes the induction already computed — and from a central
difference for vega and rho. Bumping uses the *same* tree size, so most of the
discretisation error cancels between the two legs; bumping against trees of
different sizes is how a vega picks up a spurious few percent.
"""

from __future__ import annotations

import math

import numpy as np
import numpy.typing as npt

from helios_risk.greeks.black_scholes import Greeks
from helios_risk.models import OptionType

VEGA_BUMP = 0.01  # 1 vol point, central
RHO_BUMP = 1e-4  # 1 basis point, central


def crr_price(
    S: float,
    K: float,
    t: float,
    r: float,
    sigma: float,
    option_type: OptionType,
    q: float = 0.0,
    *,
    steps: int = 256,
    american: bool = True,
) -> float:
    """Value an option on a CRR tree. ``american=False`` gives the European value."""
    return _crr(S, K, t, r, sigma, option_type, q, steps=steps, american=american)[0]


def crr_greeks(
    S: float,
    K: float,
    t: float,
    r: float,
    sigma: float,
    option_type: OptionType,
    q: float = 0.0,
    *,
    steps: int = 256,
    american: bool = True,
) -> Greeks:
    """Tree greeks. Units match :mod:`helios_risk.greeks.black_scholes`."""
    px, delta, gamma, theta = _crr(
        S, K, t, r, sigma, option_type, q, steps=steps, american=american
    )

    if t <= 0 or sigma <= 0:
        return Greeks(price=px, delta=delta, gamma=gamma, vega=0.0, theta=0.0, rho=0.0)

    up = _crr(S, K, t, r, sigma + VEGA_BUMP, option_type, q, steps=steps, american=american)[0]
    down_sigma = max(sigma - VEGA_BUMP, 1e-8)
    down = _crr(S, K, t, r, down_sigma, option_type, q, steps=steps, american=american)[0]
    vega = (up - down) / (sigma + VEGA_BUMP - down_sigma)

    r_up = _crr(S, K, t, r + RHO_BUMP, sigma, option_type, q, steps=steps, american=american)[0]
    r_down = _crr(S, K, t, r - RHO_BUMP, sigma, option_type, q, steps=steps, american=american)[0]
    rho = (r_up - r_down) / (2.0 * RHO_BUMP)

    return Greeks(price=px, delta=delta, gamma=gamma, vega=vega, theta=theta, rho=rho)


def _crr(
    S: float,
    K: float,
    t: float,
    r: float,
    sigma: float,
    option_type: OptionType,
    q: float,
    *,
    steps: int,
    american: bool,
) -> tuple[float, float, float, float]:
    """Returns ``(price, delta, gamma, theta)``.

    Delta and gamma are read off the step-1 and step-2 nodes, and theta from
    the centre node two steps in, which is the standard Hull construction: at
    step 2 the middle node has the same underlying price as the root, so the
    value difference across ``2 dt`` is a clean time derivative.
    """
    if S <= 0 or K <= 0:
        raise ValueError("spot and strike must be positive")
    if steps < 2:
        raise ValueError("a CRR tree needs at least 2 steps to produce greeks")

    if t <= 0 or sigma <= 0:
        intrinsic = max(S - K, 0.0) if option_type == "call" else max(K - S, 0.0)
        in_money = (S > K) if option_type == "call" else (S < K)
        delta = (1.0 if option_type == "call" else -1.0) if in_money else 0.0
        return intrinsic, delta, 0.0, 0.0

    dt = t / steps
    u = math.exp(sigma * math.sqrt(dt))
    d = 1.0 / u
    growth = math.exp((r - q) * dt)
    p = (growth - d) / (u - d)
    if not (0.0 < p < 1.0):
        # Happens when the drift per step exceeds what one volatility step can
        # span. Silently clipping p to [0,1] produces a tree that prices, and
        # prices wrongly, so this fails loudly with the fix in the message.
        raise ValueError(
            f"CRR risk-neutral probability {p:.4f} is outside (0,1) for "
            f"sigma={sigma:.4f}, r-q={r - q:.4f}, dt={dt:.6f}; "
            "increase `steps` or reject the input"
        )
    disc = math.exp(-r * dt)

    # Terminal underlying prices: S * u^(2j - steps) for j = 0..steps.
    j = np.arange(steps + 1, dtype=np.float64)
    prices: npt.NDArray[np.float64] = S * u ** (2.0 * j - steps)
    values: npt.NDArray[np.float64] = (
        np.maximum(prices - K, 0.0) if option_type == "call" else np.maximum(K - prices, 0.0)
    )

    level_two: npt.NDArray[np.float64] = np.zeros(3, dtype=np.float64)
    level_one: npt.NDArray[np.float64] = np.zeros(2, dtype=np.float64)

    for step in range(steps - 1, -1, -1):
        values = disc * (p * values[1:] + (1.0 - p) * values[:-1])
        if american:
            k = np.arange(step + 1, dtype=np.float64)
            node_prices: npt.NDArray[np.float64] = S * u ** (2.0 * k - step)
            exercise = (
                node_prices - K if option_type == "call" else K - node_prices
            )
            values = np.maximum(values, exercise)
        if step == 2:
            level_two = values.copy()
        elif step == 1:
            level_one = values.copy()

    px = float(values[0])
    s_up, s_down = S * u, S * d
    delta = float(level_one[1] - level_one[0]) / (s_up - s_down)

    s_uu, s_dd = S * u * u, S * d * d
    upper = (float(level_two[2]) - float(level_two[1])) / (s_uu - S)
    lower = (float(level_two[1]) - float(level_two[0])) / (S - s_dd)
    gamma = (upper - lower) / (0.5 * (s_uu - s_dd))

    # The middle node at step 2 sits at the root's underlying price, so this is
    # a pure time derivative. Per year, matching the analytic theta.
    theta = (float(level_two[1]) - px) / (2.0 * dt)
    return px, delta, gamma, theta
