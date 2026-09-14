"""Kill-switch value types.

A kill switch is a latch, not a flag: it is engaged with a reason and an actor,
it stays engaged until someone explicitly releases it, and both transitions are
appended to an audit trail that is never rewritten. "Who stopped the desk, when
and why" is the first question asked after an incident and the last thing that
should depend on log retention.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime
from enum import StrEnum
from typing import Any
from uuid import UUID, uuid4


class KillSwitchScope(StrEnum):
    """Scopes nest: a desk halt implies every account under it is halted."""

    GLOBAL = "global"
    DESK = "desk"
    ACCOUNT = "account"


class KillSwitchReason(StrEnum):
    MANUAL = "manual"
    DAILY_LOSS_LIMIT = "daily_loss_limit"
    WEEKLY_LOSS_LIMIT = "weekly_loss_limit"
    DRAWDOWN_LIMIT = "drawdown_limit"
    LEVERAGE_LIMIT = "leverage_limit"
    CONCENTRATION_LIMIT = "concentration_limit"
    MARKET_DATA_STALE = "market_data_stale"
    RECONCILIATION_BREAK = "reconciliation_break"
    BROKER_DISCONNECTED = "broker_disconnected"
    OPERATIONAL = "operational"


class KillSwitchAction(StrEnum):
    ENGAGED = "engaged"
    RELEASED = "released"
    RE_ENGAGED = "re_engaged"
    RELEASE_REFUSED = "release_refused"


@dataclass(frozen=True, slots=True)
class KillSwitchState:
    scope: KillSwitchScope
    scope_id: str
    reason: KillSwitchReason
    detail: str
    engaged_at: datetime
    engaged_by: str
    # Auto-engaged switches came from a breached hard limit rather than a
    # person. They are released the same way, but the distinction is what tells
    # a reviewer whether the system or a human stopped trading.
    automatic: bool = False
    # Even a halted desk must be able to flatten. Set false only for a halt
    # where we do not trust our own position view (e.g. a reconciliation break).
    allow_liquidation: bool = True
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True, slots=True)
class KillSwitchEvent:
    """One immutable line of the audit trail."""

    id: UUID
    ts: datetime
    action: KillSwitchAction
    scope: KillSwitchScope
    scope_id: str
    reason: KillSwitchReason
    detail: str
    actor: str
    automatic: bool = False
    metadata: dict[str, Any] = field(default_factory=dict)

    @staticmethod
    def now(
        action: KillSwitchAction,
        scope: KillSwitchScope,
        scope_id: str,
        reason: KillSwitchReason,
        detail: str,
        actor: str,
        *,
        automatic: bool = False,
        metadata: dict[str, Any] | None = None,
    ) -> KillSwitchEvent:
        return KillSwitchEvent(
            id=uuid4(),
            ts=datetime.now(UTC),
            action=action,
            scope=scope,
            scope_id=scope_id,
            reason=reason,
            detail=detail,
            actor=actor,
            automatic=automatic,
            metadata=metadata or {},
        )


def account_scope_id(account_id: UUID) -> str:
    return str(account_id)
