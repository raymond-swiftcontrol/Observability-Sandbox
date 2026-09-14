"""Initial margin / buying-power requirement for a proposed order.

Buying power as reported by ``book.cash_balance.buying_power`` is already
leverage-adjusted: for a margin account it is roughly equity x 2 under Reg T.
The requirement computed here is therefore the *full* notional of the opening
quantity, not notional x 50%. Applying the margin rate on both sides is a
double count that silently doubles how much a customer can buy, and it is the
single easiest mistake to make in this file.

Options are the exception, because their requirement is not proportional to
premium at all.
"""

from __future__ import annotations

from helios_risk.models import InstrumentRef, Side

# Reg T naked-short-option minimums. The requirement is the greater of two
# formulas, plus premium received; the second floor is what stops a deep
# out-of-the-money short from requiring nothing at all.
NAKED_OPTION_UNDERLYING_RATE = 0.20
NAKED_OPTION_FLOOR_RATE = 0.10
# Fallback when the underlying mark is unavailable. Deliberately punitive: a
# requirement we cannot compute should not be cheap.
NAKED_OPTION_STRIKE_FALLBACK_RATE = 0.30


def initial_requirement(
    instrument: InstrumentRef,
    opening_quantity: float,
    price: float,
    side: Side,
    *,
    underlying_price: float | None = None,
) -> float:
    """Buying power consumed by opening ``opening_quantity`` units.

    ``opening_quantity`` is the part of the order that increases exposure;
    closing quantity consumes nothing (it releases). Always non-negative.
    """
    if opening_quantity <= 0:
        return 0.0

    notional = opening_quantity * price * instrument.multiplier

    if instrument.option is None:
        # Cash and margin both settle against the reported buying power, which
        # is why this is the plain notional. Shorts consume the same as longs:
        # the short-sale proceeds are collateral, not spendable cash.
        return notional

    terms = instrument.option
    if side == "buy":
        # A long option cannot lose more than the premium, so the premium is
        # the requirement. This is also why long options are available at a
        # lower options level than short ones.
        return notional

    # Short option, opening. Reg T: 20% of the underlying less the amount out
    # of the money, floored at 10% of the underlying, plus premium received.
    contracts = opening_quantity
    size = terms.contract_size
    if underlying_price is None or underlying_price <= 0:
        return max(
            notional,
            NAKED_OPTION_STRIKE_FALLBACK_RATE * terms.strike * size * contracts,
        )

    if terms.option_type == "call":
        out_of_money = max(0.0, terms.strike - underlying_price)
    else:
        out_of_money = max(0.0, underlying_price - terms.strike)

    primary = NAKED_OPTION_UNDERLYING_RATE * underlying_price - out_of_money
    floor = NAKED_OPTION_FLOOR_RATE * (
        underlying_price if terms.option_type == "call" else terms.strike
    )
    per_share = max(primary, floor)
    return (per_share * size * contracts) + notional
