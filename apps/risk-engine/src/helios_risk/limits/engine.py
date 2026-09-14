"""The pre-trade gate.

**Latency budget: 5 ms at p99, measured across rule evaluation only** (the
constant lives in ``Settings.pretrade_latency_budget_ms`` and is asserted by
``tests/test_pretrade_latency.py``). The budget covers the arithmetic, not the
account load — which is why :class:`helios_risk.limits.cache.AccountRiskCache`
exists and why :meth:`PretradeGate.evaluate` takes the snapshot as an argument
instead of fetching one. An order that waits on Postgres inside the gate has
already blown the budget no matter how fast the rules are.

Exceeding the budget never changes the decision. A gate that fails open under
load lets through exactly the orders it exists to stop, and a gate that fails
closed turns a slow database into an outage; so it decides on the numbers it
has and records the overrun on the decision for the SLO to catch.
"""

from __future__ import annotations

import time
from collections.abc import Sequence
from uuid import UUID

from helios_risk.config import Settings
from helios_risk.killswitch.models import KillSwitchReason, KillSwitchScope
from helios_risk.killswitch.service import KillSwitchService
from helios_risk.limits.models import (
    Decision,
    LimitSet,
    PretradeDecision,
    RuleEvaluation,
    RuleId,
    Verdict,
)
from helios_risk.limits.rules import ALL_RULES, PretradeContext, Rule
from helios_risk.logging import get_logger
from helios_risk.models import AccountSnapshot, ProposedOrder, Severity
from helios_risk.telemetry import LIMIT_BREACHES, PRETRADE_DECISIONS, PRETRADE_LATENCY

log = get_logger("helios_risk.pretrade")

# Breaching one of these does not merely reject the order: it means the book is
# already outside its mandate, so the account is halted until a human looks.
AUTO_HALT_REASONS: dict[RuleId, KillSwitchReason] = {
    RuleId.DAILY_LOSS: KillSwitchReason.DAILY_LOSS_LIMIT,
    RuleId.WEEKLY_LOSS: KillSwitchReason.WEEKLY_LOSS_LIMIT,
    RuleId.MAX_DRAWDOWN: KillSwitchReason.DRAWDOWN_LIMIT,
    RuleId.LEVERAGE: KillSwitchReason.LEVERAGE_LIMIT,
    RuleId.POSITION_CONCENTRATION: KillSwitchReason.CONCENTRATION_LIMIT,
}


class PretradeGate:
    """Evaluates an order against every configured rule and explains itself."""

    def __init__(
        self,
        kill_switch: KillSwitchService,
        settings: Settings,
        rules: Sequence[Rule] = ALL_RULES,
    ) -> None:
        self._kill_switch = kill_switch
        self._settings = settings
        self._rules = tuple(rules)

    @property
    def latency_budget_ms(self) -> float:
        return self._settings.pretrade_latency_budget_ms

    def evaluate(
        self,
        order: ProposedOrder,
        account: AccountSnapshot,
        limits: LimitSet,
    ) -> PretradeDecision:
        """Run every rule. Never raises; a rule that explodes is reported.

        Rules are pure functions over a prepared context, but a defensive
        boundary is still worth its cost here: one bad rule must not take the
        order path down, and "rule X raised" is itself a useful decision line.
        """
        started = time.perf_counter()
        state = self._kill_switch.status_for_account(account.account_id)
        ctx = PretradeContext(
            order=order,
            account=account,
            limits=limits,
            kill_switch=state,
            pdt_equity_threshold=self._settings.pdt_equity_threshold,
            pdt_max_day_trades=self._settings.pdt_max_day_trades,
        )

        evaluations: list[RuleEvaluation] = []
        for rule in self._rules:
            try:
                evaluations.append(rule(ctx))
            except Exception as exc:  # noqa: BLE001 - the gate must not fall over
                evaluations.append(
                    RuleEvaluation(
                        rule=_rule_id_of(rule),
                        verdict=Verdict.BREACH,
                        message=f"rule raised {type(exc).__name__}: {exc}",
                        severity=Severity.HARD,
                    )
                )
                log.error(
                    "pretrade_rule_error",
                    rule=getattr(rule, "__name__", "?"),
                    error=str(exc),
                )

        elapsed_ms = (time.perf_counter() - started) * 1_000.0
        PRETRADE_LATENCY.observe(elapsed_ms / 1_000.0)

        engaged = self._maybe_halt(account.account_id, evaluations)
        notes: tuple[str, ...] = ()
        if elapsed_ms > self.latency_budget_ms:
            notes = (
                f"evaluation took {elapsed_ms:.2f}ms against a "
                f"{self.latency_budget_ms:.2f}ms budget",
            )

        decision = PretradeDecision.build(
            account_id=account.account_id,
            evaluations=evaluations,
            latency_ms=elapsed_ms,
            latency_budget_ms=self.latency_budget_ms,
            kill_switch_engaged=engaged,
            notes=notes,
        )

        PRETRADE_DECISIONS.labels(verdict=decision.decision.value).inc()
        for breach in decision.breaches:
            LIMIT_BREACHES.labels(rule=breach.rule.value, severity=breach.severity.value).inc()

        if decision.decision is Decision.REJECTED:
            log.warning(
                "pretrade_rejected",
                account_id=str(account.account_id),
                symbol=order.instrument.symbol,
                side=order.side,
                quantity=order.quantity,
                reason=decision.rejection_reason,
                latency_ms=round(elapsed_ms, 3),
            )
        else:
            log.info(
                "pretrade_approved",
                account_id=str(account.account_id),
                symbol=order.instrument.symbol,
                side=order.side,
                quantity=order.quantity,
                warnings=len(decision.warnings),
                latency_ms=round(elapsed_ms, 3),
            )
        return decision

    def _maybe_halt(self, account_id: UUID, evaluations: list[RuleEvaluation]) -> bool:
        """Trip the kill switch on a critical breach.

        Done inside the gate rather than by a downstream consumer because the
        breach is discovered here, and the next order — which may be
        microseconds behind this one — must already see the halt.
        """
        engaged = False
        for ev in evaluations:
            if ev.verdict is not Verdict.BREACH or ev.severity is not Severity.CRITICAL:
                continue
            reason = AUTO_HALT_REASONS.get(ev.rule)
            if reason is None:
                continue
            self._kill_switch.engage(
                KillSwitchScope.ACCOUNT,
                account_id,
                reason,
                ev.message,
                actor="risk-engine/pretrade",
                automatic=True,
            )
            engaged = True
        return engaged


def _rule_id_of(rule: Rule) -> RuleId:
    """Best-effort mapping from a failed callable back to its rule id."""
    name = getattr(rule, "__name__", "").removesuffix("_rule")
    try:
        return RuleId(name)
    except ValueError:
        return RuleId.ORDER_SANITY
