"""Pre-trade decision types.

The shape of :class:`PretradeDecision` is the whole point of this package. A
gate that returns ``True``/``False`` cannot answer the two questions that
actually get asked — "why was my order rejected?" and "how close was it?" — and
cannot be audited at all. So every rule that ran reports its observed value,
the limit it was compared against and its verdict, whether or not it was the
rule that rejected the order.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime
from enum import StrEnum
from typing import Any
from uuid import UUID, uuid4

from helios_risk.models import Severity


class RuleId(StrEnum):
    """Stable identifiers. These end up in mobile UI strings and in alerts, so
    they are renamed only with a migration, never casually."""

    KILL_SWITCH = "kill_switch"
    ACCOUNT_TRADING_BLOCKED = "account_trading_blocked"
    ORDER_SANITY = "order_sanity"
    BUYING_POWER = "buying_power"
    POSITION_CONCENTRATION = "position_concentration"
    GROSS_EXPOSURE = "gross_exposure"
    NET_EXPOSURE = "net_exposure"
    LEVERAGE = "leverage"
    INSTRUMENT_CAP = "instrument_cap"
    SECTOR_CAP = "sector_cap"
    DAILY_LOSS = "daily_loss"
    WEEKLY_LOSS = "weekly_loss"
    MAX_DRAWDOWN = "max_drawdown"
    PDT_DAY_TRADES = "pdt_day_trades"
    OPTIONS_LEVEL = "options_level"
    SHORTABILITY = "shortability"
    ADV_PARTICIPATION = "adv_participation"


class Verdict(StrEnum):
    PASS = "pass"
    WARN = "warn"
    BREACH = "breach"
    # A rule that could not be evaluated. Never silently a pass: an unevaluable
    # buying-power check is a reason to refuse, and an unevaluable ADV check is
    # a reason to say so in the decision.
    SKIPPED = "skipped"


class Decision(StrEnum):
    APPROVED = "approved"
    APPROVED_WITH_WARNINGS = "approved_with_warnings"
    REJECTED = "rejected"


@dataclass(frozen=True, slots=True)
class RuleEvaluation:
    """One rule's verdict, with the numbers that produced it.

    ``observed`` and ``limit`` are in ``unit`` — money in the account's base
    currency, ``ratio`` for fractions of equity, ``count`` for integers. The
    mobile client formats from the unit; it does not parse the message.
    """

    rule: RuleId
    verdict: Verdict
    message: str
    observed: float | None = None
    limit: float | None = None
    unit: str = "money"
    severity: Severity = Severity.HARD
    # Fraction of the limit consumed, for the "how close was it" progress bars.
    utilisation: float | None = None
    detail: dict[str, Any] = field(default_factory=dict)

    @property
    def blocking(self) -> bool:
        """A breach blocks; a soft rule never produces one.

        The mapping from "limit exceeded" to a verdict happens once, in
        :func:`helios_risk.limits.rules.verdict_for`, so that a rule marked soft
        cannot accidentally reject an order from one code path and warn from
        another.
        """
        return self.verdict is Verdict.BREACH


@dataclass(frozen=True, slots=True)
class LimitSet:
    """The configured limits for one account.

    ``None`` means "no limit configured", which is different from a limit of
    zero and is reported as a skipped rule rather than a pass. Defaults here are
    deliberately conservative: an account with no explicit configuration should
    be tightly bounded, not unbounded.
    """

    account_id: UUID
    # Exposure, all as fractions of equity unless the name says money.
    max_position_pct: float | None = 0.20
    max_gross_leverage: float | None = 1.0
    max_net_leverage: float | None = 1.0
    max_leverage: float | None = 1.0
    max_order_notional: float | None = None
    min_order_notional: float | None = None
    # Per-name and per-sector caps. The dicts override the defaults for the
    # keys they contain.
    max_instrument_notional: float | None = None
    instrument_notional_overrides: dict[str, float] = field(default_factory=dict)
    max_sector_pct: float | None = 0.40
    sector_pct_overrides: dict[str, float] = field(default_factory=dict)
    # Loss limits, positive money amounts meaning "this much loss is too much".
    max_daily_loss: float | None = None
    max_weekly_loss: float | None = None
    max_drawdown_pct: float | None = 0.25
    # Participation: an order larger than this share of ADV cannot be executed
    # at anything like the reference price, so it is a warning by default.
    max_adv_participation: float | None = 0.10
    # Severity overrides, so a desk can demote a rule to a warning without
    # editing code. Absent means the rule's own default.
    severity_overrides: dict[RuleId, Severity] = field(default_factory=dict)

    def severity_for(self, rule: RuleId, default: Severity) -> Severity:
        return self.severity_overrides.get(rule, default)

    def instrument_notional_cap(self, symbol: str) -> float | None:
        return self.instrument_notional_overrides.get(symbol, self.max_instrument_notional)

    def sector_cap(self, sector: str) -> float | None:
        return self.sector_pct_overrides.get(sector, self.max_sector_pct)


@dataclass(frozen=True, slots=True)
class PretradeDecision:
    """The explainable result of the gate."""

    decision_id: UUID
    decision: Decision
    account_id: UUID
    evaluations: tuple[RuleEvaluation, ...]
    evaluated_at: datetime
    latency_ms: float
    latency_budget_ms: float
    # Set when this decision itself tripped the kill switch.
    kill_switch_engaged: bool = False
    notes: tuple[str, ...] = ()

    @property
    def approved(self) -> bool:
        return self.decision is not Decision.REJECTED

    @property
    def within_budget(self) -> bool:
        return self.latency_ms <= self.latency_budget_ms

    @property
    def breaches(self) -> tuple[RuleEvaluation, ...]:
        return tuple(e for e in self.evaluations if e.verdict is Verdict.BREACH)

    @property
    def blocking_breaches(self) -> tuple[RuleEvaluation, ...]:
        return tuple(e for e in self.evaluations if e.blocking)

    @property
    def warnings(self) -> tuple[RuleEvaluation, ...]:
        return tuple(e for e in self.evaluations if e.verdict is Verdict.WARN)

    @property
    def rejection_reason(self) -> str | None:
        blocking = self.blocking_breaches
        if not blocking:
            return None
        return "; ".join(f"{e.rule.value}: {e.message}" for e in blocking)

    def evaluation(self, rule: RuleId) -> RuleEvaluation | None:
        for e in self.evaluations:
            if e.rule is rule:
                return e
        return None

    @staticmethod
    def build(
        account_id: UUID,
        evaluations: list[RuleEvaluation],
        latency_ms: float,
        latency_budget_ms: float,
        *,
        kill_switch_engaged: bool = False,
        notes: tuple[str, ...] = (),
    ) -> PretradeDecision:
        blocking = [e for e in evaluations if e.blocking]
        warnings = [e for e in evaluations if e.verdict is Verdict.WARN]
        if blocking:
            decision = Decision.REJECTED
        elif warnings:
            decision = Decision.APPROVED_WITH_WARNINGS
        else:
            decision = Decision.APPROVED
        return PretradeDecision(
            decision_id=uuid4(),
            decision=decision,
            account_id=account_id,
            evaluations=tuple(evaluations),
            evaluated_at=datetime.now(UTC),
            latency_ms=latency_ms,
            latency_budget_ms=latency_budget_ms,
            kill_switch_engaged=kill_switch_engaged,
            notes=notes,
        )
