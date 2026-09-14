"""The individual pre-trade rules.

Each rule is a pure function of a :class:`PretradeContext` and returns exactly
one :class:`RuleEvaluation`. None of them raise, none of them short-circuit and
none of them look anything up: the gate evaluates all of them on every order so
that the decision is complete, and a rule that cannot be evaluated says so
(``Verdict.SKIPPED``) rather than quietly passing.

The exposure rules all evaluate the *projected* book — what the account would
look like if this order filled in full — not the current one. Checking current
exposure against a limit approves the order that breaches it, which is the
whole failure mode the gate exists to prevent.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field

from helios_risk.killswitch.models import KillSwitchState
from helios_risk.limits.margin import initial_requirement
from helios_risk.limits.models import LimitSet, RuleEvaluation, RuleId, Verdict
from helios_risk.models import AccountSnapshot, ProposedOrder, Severity

# Options levels, as the brokerage industry numbers them. Level 0 is "no
# options"; the mapping from a position to a required level is in
# ``options_level_rule``.
LEVEL_COVERED = 1
LEVEL_LONG = 2
LEVEL_SPREAD = 3
LEVEL_NAKED = 4


@dataclass(slots=True)
class PretradeContext:
    """Everything the rules need, computed once.

    Deriving the projection here rather than per rule is both a latency win and
    a correctness one: seventeen rules each recomputing "what would the book
    look like" is seventeen chances for them to disagree.
    """

    order: ProposedOrder
    account: AccountSnapshot
    limits: LimitSet
    kill_switch: KillSwitchState | None = None
    pdt_equity_threshold: float = 25_000.0
    pdt_max_day_trades: int = 3

    existing_quantity: float = field(init=False, default=0.0)
    projected_quantity: float = field(init=False, default=0.0)
    opening_quantity: float = field(init=False, default=0.0)
    closing_quantity: float = field(init=False, default=0.0)
    delta_value: float = field(init=False, default=0.0)
    position_value_before: float = field(init=False, default=0.0)
    position_value_after: float = field(init=False, default=0.0)
    gross_after: float = field(init=False, default=0.0)
    net_after: float = field(init=False, default=0.0)
    sector_value_before: float = field(init=False, default=0.0)
    sector_value_after: float = field(init=False, default=0.0)
    underlying_price: float | None = field(init=False, default=None)

    def __post_init__(self) -> None:
        order = self.order
        existing = self.account.position_for(order.instrument.instrument_id)
        self.existing_quantity = existing.quantity if existing else 0.0
        self.projected_quantity = self.existing_quantity + order.signed_quantity

        # Split the order into the part that closes existing exposure and the
        # part that opens new exposure. Only the opening part consumes buying
        # power, and only it needs a short locate or an options level.
        if self.existing_quantity == 0.0 or (
            self.projected_quantity * self.existing_quantity > 0
            and abs(self.projected_quantity) > abs(self.existing_quantity)
        ):
            self.opening_quantity = abs(order.quantity)
            self.closing_quantity = 0.0
        elif self.projected_quantity * self.existing_quantity >= 0:
            # Reducing, or flattening exactly: nothing opens.
            self.opening_quantity = 0.0
            self.closing_quantity = abs(order.quantity)
        else:
            # Crossing through zero: close everything, open the remainder.
            self.closing_quantity = abs(self.existing_quantity)
            self.opening_quantity = abs(self.projected_quantity)

        # The incremental quantity is valued at the order's own price and the
        # rest of the book stays at its marks. This is the same arithmetic the
        # order ticket showed the user, so the gate and the UI agree about what
        # the order is worth.
        self.delta_value = order.signed_notional
        self.position_value_before = existing.market_value if existing else 0.0
        self.position_value_after = self.position_value_before + self.delta_value

        self.gross_after = (
            self.account.gross_exposure
            - abs(self.position_value_before)
            + abs(self.position_value_after)
        )
        self.net_after = self.account.net_exposure + self.delta_value

        sector = order.instrument.sector or "unclassified"
        self.sector_value_before = sum(
            p.market_value
            for p in self.account.positions
            if (p.instrument.sector or "unclassified") == sector
        )
        self.sector_value_after = self.sector_value_before + self.delta_value

        if existing is not None and existing.underlying_price is not None:
            self.underlying_price = existing.underlying_price

    @property
    def equity(self) -> float:
        """Equity is unchanged by a fill.

        Buying an asset swaps cash for securities of equal value; only the
        commission moves equity, and it is immaterial against any limit
        expressed as a fraction of equity. Modelling it here would add a term
        that no reviewer can check against the account statement.
        """
        return self.account.equity

    @property
    def reduces_exposure(self) -> bool:
        return abs(self.projected_quantity) < abs(self.existing_quantity)


Rule = Callable[[PretradeContext], RuleEvaluation]


def verdict_for(exceeded: bool, severity: Severity) -> Verdict:
    """The single place "limit exceeded" becomes a verdict."""
    if not exceeded:
        return Verdict.PASS
    return Verdict.WARN if severity is Severity.SOFT else Verdict.BREACH


def _utilisation(observed: float, limit: float | None) -> float | None:
    if limit is None or limit == 0:
        return None
    return abs(observed) / abs(limit)


def _skipped(rule: RuleId, message: str, severity: Severity = Severity.HARD) -> RuleEvaluation:
    return RuleEvaluation(
        rule=rule, verdict=Verdict.SKIPPED, message=message, severity=severity
    )


# ── Gate-level rules ─────────────────────────────────────────────────────────
def kill_switch_rule(ctx: PretradeContext) -> RuleEvaluation:
    state = ctx.kill_switch
    if state is None:
        return RuleEvaluation(
            rule=RuleId.KILL_SWITCH, verdict=Verdict.PASS, message="no kill switch engaged"
        )
    # A halted desk must still be able to flatten, otherwise engaging the
    # switch during a loss event traps the position it was engaged to protect.
    liquidating = ctx.order.is_risk_liquidation and ctx.reduces_exposure
    if liquidating and state.allow_liquidation:
        return RuleEvaluation(
            rule=RuleId.KILL_SWITCH,
            verdict=Verdict.WARN,
            message=f"{state.scope.value} halted ({state.reason.value}); liquidation permitted",
            severity=Severity.SOFT,
            detail={"scope": state.scope.value, "reason": state.reason.value},
        )
    return RuleEvaluation(
        rule=RuleId.KILL_SWITCH,
        verdict=Verdict.BREACH,
        message=f"{state.scope.value} kill switch engaged: {state.reason.value} — {state.detail}",
        severity=Severity.HARD,
        detail={
            "scope": state.scope.value,
            "scope_id": state.scope_id,
            "reason": state.reason.value,
            "engaged_at": state.engaged_at.isoformat(),
            "engaged_by": state.engaged_by,
        },
    )


def account_blocked_rule(ctx: PretradeContext) -> RuleEvaluation:
    acct = ctx.account
    if not acct.trading_blocked:
        return RuleEvaluation(
            rule=RuleId.ACCOUNT_TRADING_BLOCKED,
            verdict=Verdict.PASS,
            message="account is not blocked",
        )
    return RuleEvaluation(
        rule=RuleId.ACCOUNT_TRADING_BLOCKED,
        verdict=Verdict.BREACH,
        message=acct.trading_blocked_reason or "trading blocked on the account",
        severity=Severity.HARD,
    )


def order_sanity_rule(ctx: PretradeContext) -> RuleEvaluation:
    order = ctx.order
    limits = ctx.limits
    problems: list[str] = []
    if order.quantity <= 0:
        problems.append("quantity must be positive")
    if order.price <= 0:
        problems.append("no usable reference price")
    notional = order.notional
    if limits.min_order_notional is not None and 0 < notional < limits.min_order_notional:
        problems.append(f"notional {notional:,.2f} below minimum {limits.min_order_notional:,.2f}")
    if limits.max_order_notional is not None and notional > limits.max_order_notional:
        problems.append(f"notional {notional:,.2f} above maximum {limits.max_order_notional:,.2f}")
    if problems:
        return RuleEvaluation(
            rule=RuleId.ORDER_SANITY,
            verdict=Verdict.BREACH,
            message="; ".join(problems),
            observed=notional,
            limit=limits.max_order_notional,
            severity=Severity.HARD,
        )
    return RuleEvaluation(
        rule=RuleId.ORDER_SANITY,
        verdict=Verdict.PASS,
        message="order is well formed",
        observed=notional,
        limit=limits.max_order_notional,
        utilisation=_utilisation(notional, limits.max_order_notional),
    )


# ── Capital ──────────────────────────────────────────────────────────────────
def buying_power_rule(ctx: PretradeContext) -> RuleEvaluation:
    order = ctx.order
    required = initial_requirement(
        order.instrument,
        ctx.opening_quantity,
        order.price,
        order.side,
        underlying_price=ctx.underlying_price,
    )
    # Day trades draw on a separate, larger pool under Reg T. Using the
    # overnight figure for a day trade under-reports available capital; using
    # the day-trade figure for a position held overnight over-reports it.
    available = (
        ctx.account.day_trade_buying_power if order.is_day_trade else ctx.account.buying_power
    )
    severity = ctx.limits.severity_for(RuleId.BUYING_POWER, Severity.HARD)
    exceeded = required > available
    return RuleEvaluation(
        rule=RuleId.BUYING_POWER,
        verdict=verdict_for(exceeded, severity),
        message=(
            f"requires {required:,.2f}, {available:,.2f} available"
            if exceeded
            else f"{required:,.2f} of {available:,.2f} buying power"
        ),
        observed=required,
        limit=available,
        unit="money",
        severity=severity,
        utilisation=_utilisation(required, available),
        detail={
            "opening_quantity": ctx.opening_quantity,
            "closing_quantity": ctx.closing_quantity,
            "pool": "day_trade" if order.is_day_trade else "overnight",
        },
    )


# ── Exposure ─────────────────────────────────────────────────────────────────
def position_concentration_rule(ctx: PretradeContext) -> RuleEvaluation:
    limit = ctx.limits.max_position_pct
    severity = ctx.limits.severity_for(RuleId.POSITION_CONCENTRATION, Severity.HARD)
    if limit is None:
        return _skipped(RuleId.POSITION_CONCENTRATION, "no concentration limit configured")
    if ctx.equity <= 0:
        return RuleEvaluation(
            rule=RuleId.POSITION_CONCENTRATION,
            verdict=Verdict.BREACH,
            message="account has no positive equity to concentrate",
            observed=abs(ctx.position_value_after),
            limit=0.0,
            unit="ratio",
            severity=severity,
        )
    observed = abs(ctx.position_value_after) / ctx.equity
    exceeded = observed > limit
    return RuleEvaluation(
        rule=RuleId.POSITION_CONCENTRATION,
        verdict=verdict_for(exceeded, severity),
        message=(
            f"{ctx.order.instrument.symbol} would be {observed:.1%} of equity "
            f"(limit {limit:.1%})"
        ),
        observed=observed,
        limit=limit,
        unit="ratio",
        severity=severity,
        utilisation=_utilisation(observed, limit),
    )


def gross_exposure_rule(ctx: PretradeContext) -> RuleEvaluation:
    limit = ctx.limits.max_gross_leverage
    severity = ctx.limits.severity_for(RuleId.GROSS_EXPOSURE, Severity.HARD)
    if limit is None:
        return _skipped(RuleId.GROSS_EXPOSURE, "no gross exposure limit configured")
    if ctx.equity <= 0:
        return RuleEvaluation(
            rule=RuleId.GROSS_EXPOSURE,
            verdict=Verdict.BREACH,
            message="no positive equity",
            observed=float("inf"),
            limit=limit,
            unit="ratio",
            severity=severity,
        )
    observed = ctx.gross_after / ctx.equity
    exceeded = observed > limit
    return RuleEvaluation(
        rule=RuleId.GROSS_EXPOSURE,
        verdict=verdict_for(exceeded, severity),
        message=f"projected gross {observed:.2f}x equity (limit {limit:.2f}x)",
        observed=observed,
        limit=limit,
        unit="ratio",
        severity=severity,
        utilisation=_utilisation(observed, limit),
        detail={"gross_after": ctx.gross_after, "equity": ctx.equity},
    )


def net_exposure_rule(ctx: PretradeContext) -> RuleEvaluation:
    limit = ctx.limits.max_net_leverage
    severity = ctx.limits.severity_for(RuleId.NET_EXPOSURE, Severity.HARD)
    if limit is None:
        return _skipped(RuleId.NET_EXPOSURE, "no net exposure limit configured")
    if ctx.equity <= 0:
        return RuleEvaluation(
            rule=RuleId.NET_EXPOSURE,
            verdict=Verdict.BREACH,
            message="no positive equity",
            observed=float("inf"),
            limit=limit,
            unit="ratio",
            severity=severity,
        )
    # Absolute value: a net short book of -1.5x is exactly as exposed to a
    # market move as a net long one, in the opposite direction.
    observed = abs(ctx.net_after) / ctx.equity
    exceeded = observed > limit
    return RuleEvaluation(
        rule=RuleId.NET_EXPOSURE,
        verdict=verdict_for(exceeded, severity),
        message=f"projected |net| {observed:.2f}x equity (limit {limit:.2f}x)",
        observed=observed,
        limit=limit,
        unit="ratio",
        severity=severity,
        utilisation=_utilisation(observed, limit),
        detail={"net_after": ctx.net_after},
    )


def leverage_rule(ctx: PretradeContext) -> RuleEvaluation:
    # Two limits bind: what the account type permits and what the desk
    # configured. The tighter one wins — a desk can be stricter than the broker
    # but never looser.
    configured = ctx.limits.max_leverage
    account_max = ctx.account.max_leverage
    candidates = [x for x in (configured, account_max) if x is not None]
    severity = ctx.limits.severity_for(RuleId.LEVERAGE, Severity.HARD)
    if not candidates:
        return _skipped(RuleId.LEVERAGE, "no leverage limit configured")
    limit = min(candidates)
    if ctx.equity <= 0:
        return RuleEvaluation(
            rule=RuleId.LEVERAGE,
            verdict=Verdict.BREACH,
            message="no positive equity",
            observed=float("inf"),
            limit=limit,
            unit="ratio",
            severity=severity,
        )
    observed = ctx.gross_after / ctx.equity
    exceeded = observed > limit
    return RuleEvaluation(
        rule=RuleId.LEVERAGE,
        verdict=verdict_for(exceeded, severity),
        message=f"projected leverage {observed:.2f}x (limit {limit:.2f}x)",
        observed=observed,
        limit=limit,
        unit="ratio",
        severity=severity,
        utilisation=_utilisation(observed, limit),
        detail={"account_max": account_max, "configured_max": configured},
    )


def instrument_cap_rule(ctx: PretradeContext) -> RuleEvaluation:
    symbol = ctx.order.instrument.symbol
    limit = ctx.limits.instrument_notional_cap(symbol)
    severity = ctx.limits.severity_for(RuleId.INSTRUMENT_CAP, Severity.HARD)
    if limit is None:
        return _skipped(RuleId.INSTRUMENT_CAP, f"no per-instrument cap for {symbol}")
    observed = abs(ctx.position_value_after)
    exceeded = observed > limit
    return RuleEvaluation(
        rule=RuleId.INSTRUMENT_CAP,
        verdict=verdict_for(exceeded, severity),
        message=f"{symbol} position would be {observed:,.2f} (cap {limit:,.2f})",
        observed=observed,
        limit=limit,
        unit="money",
        severity=severity,
        utilisation=_utilisation(observed, limit),
    )


def sector_cap_rule(ctx: PretradeContext) -> RuleEvaluation:
    sector = ctx.order.instrument.sector or "unclassified"
    limit = ctx.limits.sector_cap(sector)
    severity = ctx.limits.severity_for(RuleId.SECTOR_CAP, Severity.HARD)
    if limit is None:
        return _skipped(RuleId.SECTOR_CAP, f"no cap configured for sector {sector}")
    if ctx.equity <= 0:
        return RuleEvaluation(
            rule=RuleId.SECTOR_CAP,
            verdict=Verdict.BREACH,
            message="no positive equity",
            observed=abs(ctx.sector_value_after),
            limit=limit,
            unit="ratio",
            severity=severity,
        )
    # Net, not gross, within the sector: a long and a short in the same sector
    # genuinely offset each other's sector-factor exposure, which is the risk
    # this cap is about.
    observed = abs(ctx.sector_value_after) / ctx.equity
    exceeded = observed > limit
    return RuleEvaluation(
        rule=RuleId.SECTOR_CAP,
        verdict=verdict_for(exceeded, severity),
        message=f"sector {sector} would be {observed:.1%} of equity (limit {limit:.1%})",
        observed=observed,
        limit=limit,
        unit="ratio",
        severity=severity,
        utilisation=_utilisation(observed, limit),
        detail={"sector": sector},
    )


# ── Loss limits ──────────────────────────────────────────────────────────────
def daily_loss_rule(ctx: PretradeContext) -> RuleEvaluation:
    limit = ctx.limits.max_daily_loss
    severity = ctx.limits.severity_for(RuleId.DAILY_LOSS, Severity.CRITICAL)
    if limit is None:
        return _skipped(RuleId.DAILY_LOSS, "no daily loss limit configured", severity)
    loss = max(0.0, -ctx.account.pnl_day)
    exceeded = loss > limit
    return RuleEvaluation(
        rule=RuleId.DAILY_LOSS,
        verdict=verdict_for(exceeded, severity),
        message=f"day P&L {ctx.account.pnl_day:,.2f}, loss limit {limit:,.2f}",
        observed=loss,
        limit=limit,
        unit="money",
        severity=severity,
        utilisation=_utilisation(loss, limit),
    )


def weekly_loss_rule(ctx: PretradeContext) -> RuleEvaluation:
    limit = ctx.limits.max_weekly_loss
    severity = ctx.limits.severity_for(RuleId.WEEKLY_LOSS, Severity.CRITICAL)
    if limit is None:
        return _skipped(RuleId.WEEKLY_LOSS, "no weekly loss limit configured", severity)
    loss = max(0.0, -ctx.account.pnl_week)
    exceeded = loss > limit
    return RuleEvaluation(
        rule=RuleId.WEEKLY_LOSS,
        verdict=verdict_for(exceeded, severity),
        message=f"week P&L {ctx.account.pnl_week:,.2f}, loss limit {limit:,.2f}",
        observed=loss,
        limit=limit,
        unit="money",
        severity=severity,
        utilisation=_utilisation(loss, limit),
    )


def max_drawdown_rule(ctx: PretradeContext) -> RuleEvaluation:
    limit = ctx.limits.max_drawdown_pct
    severity = ctx.limits.severity_for(RuleId.MAX_DRAWDOWN, Severity.CRITICAL)
    if limit is None:
        return _skipped(RuleId.MAX_DRAWDOWN, "no drawdown limit configured", severity)
    if ctx.account.high_water_mark <= 0:
        return _skipped(
            RuleId.MAX_DRAWDOWN, "no high-water mark recorded for this account", severity
        )
    observed = ctx.account.drawdown
    exceeded = observed > limit
    return RuleEvaluation(
        rule=RuleId.MAX_DRAWDOWN,
        verdict=verdict_for(exceeded, severity),
        message=f"drawdown {observed:.1%} from high-water mark (limit {limit:.1%})",
        observed=observed,
        limit=limit,
        unit="ratio",
        severity=severity,
        utilisation=_utilisation(observed, limit),
        detail={"high_water_mark": ctx.account.high_water_mark, "equity": ctx.equity},
    )


# ── Eligibility ──────────────────────────────────────────────────────────────
def pdt_rule(ctx: PretradeContext) -> RuleEvaluation:
    acct = ctx.account
    severity = ctx.limits.severity_for(RuleId.PDT_DAY_TRADES, Severity.HARD)
    used = acct.day_trades_used_5d
    limit = float(ctx.pdt_max_day_trades)
    # The rule only bites below the equity threshold; above it the account is
    # a pattern day trader by designation and unrestricted in count.
    if acct.equity >= ctx.pdt_equity_threshold and not acct.pdt_restricted:
        return RuleEvaluation(
            rule=RuleId.PDT_DAY_TRADES,
            verdict=Verdict.PASS,
            message=f"equity {acct.equity:,.2f} is above the PDT threshold",
            observed=float(used),
            limit=None,
            unit="count",
            severity=severity,
        )
    if not ctx.order.is_day_trade:
        return RuleEvaluation(
            rule=RuleId.PDT_DAY_TRADES,
            verdict=Verdict.PASS,
            message=f"{used} of {ctx.pdt_max_day_trades} day trades used; order is not one",
            observed=float(used),
            limit=limit,
            unit="count",
            severity=severity,
            utilisation=_utilisation(float(used), limit),
        )
    exceeded = used >= ctx.pdt_max_day_trades
    return RuleEvaluation(
        rule=RuleId.PDT_DAY_TRADES,
        verdict=verdict_for(exceeded, severity),
        message=(
            f"day trade {used + 1} of {ctx.pdt_max_day_trades} allowed in a rolling "
            f"5 business days below {ctx.pdt_equity_threshold:,.0f} equity"
        ),
        observed=float(used + 1),
        limit=limit,
        unit="count",
        severity=severity,
        utilisation=_utilisation(float(used + 1), limit),
    )


def options_level_rule(ctx: PretradeContext) -> RuleEvaluation:
    order = ctx.order
    severity = ctx.limits.severity_for(RuleId.OPTIONS_LEVEL, Severity.HARD)
    terms = order.instrument.option
    if terms is None:
        return _skipped(RuleId.OPTIONS_LEVEL, "not an options order", severity)

    held = ctx.account.options_level
    if ctx.opening_quantity == 0:
        return RuleEvaluation(
            rule=RuleId.OPTIONS_LEVEL,
            verdict=Verdict.PASS,
            message="closing an options position requires no level",
            observed=float(held),
            limit=0.0,
            unit="count",
            severity=severity,
        )

    if order.side == "buy":
        required = LEVEL_LONG
        kind = "long option"
    else:
        # Coverage decides the level. A short call covered by the underlying,
        # or a short put fully cash-secured, is the lowest tier; anything else
        # is naked and sits at the top. Spreads (level 3) cannot be recognised
        # from a single leg — a multi-leg ticket must be evaluated as a unit,
        # which the gate does not yet do, so a leg that looks naked is treated
        # as naked. That is the conservative direction to be wrong in.
        covered = _short_option_is_covered(ctx)
        required = LEVEL_COVERED if covered else LEVEL_NAKED
        kind = "covered short option" if covered else "uncovered short option"

    exceeded = held < required
    return RuleEvaluation(
        rule=RuleId.OPTIONS_LEVEL,
        verdict=verdict_for(exceeded, severity),
        message=f"{kind} requires options level {required}; account has {held}",
        observed=float(held),
        limit=float(required),
        unit="count",
        severity=severity,
        detail={"required_level": required, "strategy": kind},
    )


def _short_option_is_covered(ctx: PretradeContext) -> bool:
    terms = ctx.order.instrument.option
    if terms is None:
        return False
    contracts = ctx.opening_quantity
    if terms.option_type == "call":
        underlying_id = ctx.order.instrument.underlying_id
        if underlying_id is None:
            return False
        held = ctx.account.position_for(underlying_id)
        if held is None or held.quantity <= 0:
            return False
        return held.quantity >= contracts * terms.contract_size
    # Cash-secured put: enough settled cash to buy the stock if assigned.
    return ctx.account.cash_settled >= terms.strike * terms.contract_size * contracts


def shortability_rule(ctx: PretradeContext) -> RuleEvaluation:
    order = ctx.order
    severity = ctx.limits.severity_for(RuleId.SHORTABILITY, Severity.HARD)
    if order.instrument.option is not None:
        # Writing an option is not a short sale and needs no locate; the
        # options-level rule governs it.
        return _skipped(RuleId.SHORTABILITY, "options are governed by the options level", severity)
    if ctx.projected_quantity >= 0:
        return RuleEvaluation(
            rule=RuleId.SHORTABILITY,
            verdict=Verdict.PASS,
            message="order does not result in a short position",
            severity=severity,
        )
    problems: list[str] = []
    if not ctx.account.shorting_enabled:
        problems.append("shorting is not enabled on the account")
    if not order.instrument.is_shortable:
        problems.append(f"{order.instrument.symbol} is not shortable (no borrow)")
    if problems:
        return RuleEvaluation(
            rule=RuleId.SHORTABILITY,
            verdict=Verdict.BREACH,
            message="; ".join(problems),
            observed=ctx.projected_quantity,
            unit="quantity",
            severity=severity,
        )
    return RuleEvaluation(
        rule=RuleId.SHORTABILITY,
        verdict=Verdict.PASS,
        message=f"{order.instrument.symbol} is shortable at "
        f"{order.instrument.short_borrow_rate_bps:.0f}bps",
        observed=ctx.projected_quantity,
        unit="quantity",
        severity=severity,
    )


def adv_participation_rule(ctx: PretradeContext) -> RuleEvaluation:
    limit = ctx.limits.max_adv_participation
    severity = ctx.limits.severity_for(RuleId.ADV_PARTICIPATION, Severity.SOFT)
    if limit is None:
        return _skipped(RuleId.ADV_PARTICIPATION, "no participation limit configured", severity)
    adv = ctx.order.instrument.adv_30d
    if adv is None or adv <= 0:
        # An unknown ADV is reported, not assumed. Assuming infinite liquidity
        # is how an order for 40% of a day's volume passes a risk check.
        return _skipped(
            RuleId.ADV_PARTICIPATION,
            f"no ADV on record for {ctx.order.instrument.symbol}",
            severity,
        )
    observed = abs(ctx.order.quantity) / adv
    exceeded = observed > limit
    return RuleEvaluation(
        rule=RuleId.ADV_PARTICIPATION,
        verdict=verdict_for(exceeded, severity),
        message=f"order is {observed:.1%} of 30d ADV (limit {limit:.1%})",
        observed=observed,
        limit=limit,
        unit="ratio",
        severity=severity,
        utilisation=_utilisation(observed, limit),
    )


# Evaluation order is the order the mobile client renders them in: the reasons
# a trader is most likely to hit come first.
ALL_RULES: tuple[Rule, ...] = (
    kill_switch_rule,
    account_blocked_rule,
    order_sanity_rule,
    buying_power_rule,
    position_concentration_rule,
    gross_exposure_rule,
    net_exposure_rule,
    leverage_rule,
    instrument_cap_rule,
    sector_cap_rule,
    daily_loss_rule,
    weekly_loss_rule,
    max_drawdown_rule,
    pdt_rule,
    options_level_rule,
    shortability_rule,
    adv_participation_rule,
)

__all__ = [
    "ALL_RULES",
    "AccountSnapshot",
    "LimitSet",
    "PretradeContext",
    "ProposedOrder",
    "Rule",
    "verdict_for",
]
