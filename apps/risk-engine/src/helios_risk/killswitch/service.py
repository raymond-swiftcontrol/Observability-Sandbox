"""The kill-switch service.

State lives in memory and is rebuilt from the audit trail on start. That is a
deliberate choice for the order path: consulting the switch is the first thing
the pre-trade gate does on every order, and a database round trip inside that
check would put Postgres availability in series with the ability to *stop*
trading. The trail is durable; the latch is fast.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from datetime import UTC, datetime
from uuid import UUID

from helios_risk.killswitch.models import (
    KillSwitchAction,
    KillSwitchEvent,
    KillSwitchReason,
    KillSwitchScope,
    KillSwitchState,
)
from helios_risk.logging import get_logger
from helios_risk.telemetry import KILLSWITCH_ACTIVE

log = get_logger("helios_risk.killswitch")

GLOBAL_SCOPE_ID = "*"


class KillSwitchService:
    """Account-, desk- and global-level trading halts.

    Not thread-safe by design: the service runs single-threaded inside the
    asyncio loop, and adding a lock to the order path's first check would cost
    more than it protects. Every mutation happens in a coroutine, so the only
    interleaving points are awaits, and there are none inside a transition.
    """

    def __init__(self, desk_of: Mapping[str, str] | None = None) -> None:
        self._states: dict[tuple[KillSwitchScope, str], KillSwitchState] = {}
        self._trail: list[KillSwitchEvent] = []
        # account public/uuid string -> desk id. Injected rather than queried:
        # desk membership changes rarely and the gate cannot afford a lookup.
        self._desk_of: dict[str, str] = dict(desk_of or {})

    # ── Membership ─────────────────────────────────────────────────────────
    def assign_desk(self, account_id: UUID | str, desk_id: str) -> None:
        self._desk_of[str(account_id)] = desk_id

    def desk_for(self, account_id: UUID | str) -> str | None:
        return self._desk_of.get(str(account_id))

    # ── Transitions ────────────────────────────────────────────────────────
    def engage(
        self,
        scope: KillSwitchScope,
        scope_id: str | UUID,
        reason: KillSwitchReason,
        detail: str,
        actor: str,
        *,
        automatic: bool = False,
        allow_liquidation: bool = True,
    ) -> KillSwitchState:
        """Engage (or re-engage with a new reason) a switch. Idempotent by key.

        Re-engaging an already-engaged switch does not reset ``engaged_at`` —
        the first trip is the one that matters for the incident timeline — but
        it does append an event, so a second, different reason is not lost.
        """
        key = (scope, str(scope_id))
        existing = self._states.get(key)
        state = KillSwitchState(
            scope=scope,
            scope_id=str(scope_id),
            reason=reason,
            detail=detail,
            engaged_at=existing.engaged_at if existing else datetime.now(UTC),
            engaged_by=existing.engaged_by if existing else actor,
            automatic=existing.automatic if existing else automatic,
            allow_liquidation=allow_liquidation and (
                existing.allow_liquidation if existing else True
            ),
        )
        self._states[key] = state
        self._trail.append(
            KillSwitchEvent.now(
                KillSwitchAction.RE_ENGAGED if existing else KillSwitchAction.ENGAGED,
                scope,
                str(scope_id),
                reason,
                detail,
                actor,
                automatic=automatic,
            )
        )
        KILLSWITCH_ACTIVE.labels(scope=scope.value, scope_id=str(scope_id)).set(1)
        log.warning(
            "kill_switch_engaged",
            scope=scope.value,
            scope_id=str(scope_id),
            reason=reason.value,
            detail=detail,
            actor=actor,
            automatic=automatic,
        )
        return state

    def release(
        self,
        scope: KillSwitchScope,
        scope_id: str | UUID,
        actor: str,
        detail: str = "",
    ) -> bool:
        """Release a switch. Returns False when nothing was engaged.

        Releasing is never implicit. An automatic trip caused by a loss limit
        stays engaged until a human clears it, even if the account's P&L
        recovers, because the condition that produced it was a control failure
        and not a market move.
        """
        key = (scope, str(scope_id))
        state = self._states.pop(key, None)
        if state is None:
            self._trail.append(
                KillSwitchEvent.now(
                    KillSwitchAction.RELEASE_REFUSED,
                    scope,
                    str(scope_id),
                    KillSwitchReason.MANUAL,
                    detail or "no switch engaged at this scope",
                    actor,
                )
            )
            return False
        self._trail.append(
            KillSwitchEvent.now(
                KillSwitchAction.RELEASED,
                scope,
                str(scope_id),
                state.reason,
                detail or f"released after {state.reason.value}",
                actor,
                automatic=False,
            )
        )
        KILLSWITCH_ACTIVE.labels(scope=scope.value, scope_id=str(scope_id)).set(0)
        log.info("kill_switch_released", scope=scope.value, scope_id=str(scope_id), actor=actor)
        return True

    # ── Queries ────────────────────────────────────────────────────────────
    def status_for_account(self, account_id: UUID | str) -> KillSwitchState | None:
        """The binding switch for an account, widest scope first.

        Order matters: a global halt is reported in preference to an account
        halt, because "everything is stopped" is the more useful message and
        releasing the account switch would not let the order through anyway.
        """
        account_key = str(account_id)
        global_state = self._states.get((KillSwitchScope.GLOBAL, GLOBAL_SCOPE_ID))
        if global_state is not None:
            return global_state
        desk = self._desk_of.get(account_key)
        if desk is not None:
            desk_state = self._states.get((KillSwitchScope.DESK, desk))
            if desk_state is not None:
                return desk_state
        return self._states.get((KillSwitchScope.ACCOUNT, account_key))

    def is_halted(self, account_id: UUID | str) -> bool:
        return self.status_for_account(account_id) is not None

    def active(self) -> list[KillSwitchState]:
        return list(self._states.values())

    def audit_trail(self, limit: int | None = None) -> list[KillSwitchEvent]:
        """Newest last. The trail is append-only; this returns a copy."""
        return list(self._trail) if limit is None else list(self._trail[-limit:])

    def restore(self, events: Iterable[KillSwitchEvent]) -> None:
        """Rebuild latch state by replaying a durable trail at start-up."""
        for event in events:
            self._trail.append(event)
            key = (event.scope, event.scope_id)
            if event.action in (KillSwitchAction.ENGAGED, KillSwitchAction.RE_ENGAGED):
                self._states[key] = KillSwitchState(
                    scope=event.scope,
                    scope_id=event.scope_id,
                    reason=event.reason,
                    detail=event.detail,
                    engaged_at=event.ts,
                    engaged_by=event.actor,
                    automatic=event.automatic,
                )
            elif event.action is KillSwitchAction.RELEASED:
                self._states.pop(key, None)
