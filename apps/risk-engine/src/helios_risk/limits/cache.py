"""The warm cache that keeps the gate's latency budget achievable.

The gate's arithmetic is microseconds; loading an account snapshot from
Postgres is milliseconds. Caching the snapshot is therefore not an
optimisation, it is what makes the budget meaningful.

The trade-off is explicit: for ``ttl_seconds`` after a load, the gate decides
against a slightly stale view of buying power and positions. One second is the
default because a fill changes the snapshot and fills arrive on a Kafka topic
this service consumes — :meth:`AccountRiskCache.invalidate` is called on every
fill, so the TTL is a backstop for events we missed, not the primary
freshness mechanism.
"""

from __future__ import annotations

import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from uuid import UUID

from helios_risk.limits.models import LimitSet
from helios_risk.models import AccountSnapshot

SnapshotLoader = Callable[[UUID], Awaitable[tuple[AccountSnapshot, LimitSet]]]


@dataclass(slots=True)
class _Entry:
    snapshot: AccountSnapshot
    limits: LimitSet
    loaded_at: float


class AccountRiskCache:
    """TTL cache of ``(AccountSnapshot, LimitSet)`` keyed by account.

    Uses ``time.monotonic``: a wall-clock step (NTP, a container resuming from
    a snapshot) must not make an entry immortal or instantly stale.
    """

    def __init__(self, loader: SnapshotLoader, ttl_seconds: float = 1.0) -> None:
        self._loader = loader
        self._ttl = ttl_seconds
        self._entries: dict[UUID, _Entry] = {}
        self.hits = 0
        self.misses = 0

    async def get(self, account_id: UUID) -> tuple[AccountSnapshot, LimitSet]:
        now = time.monotonic()
        entry = self._entries.get(account_id)
        if entry is not None and (now - entry.loaded_at) < self._ttl:
            self.hits += 1
            return entry.snapshot, entry.limits
        self.misses += 1
        snapshot, limits = await self._loader(account_id)
        self._entries[account_id] = _Entry(snapshot, limits, time.monotonic())
        return snapshot, limits

    def put(self, account_id: UUID, snapshot: AccountSnapshot, limits: LimitSet) -> None:
        """Seed the cache from an event stream (a fill, a mark update)."""
        self._entries[account_id] = _Entry(snapshot, limits, time.monotonic())

    def invalidate(self, account_id: UUID) -> None:
        self._entries.pop(account_id, None)

    def clear(self) -> None:
        self._entries.clear()

    @property
    def size(self) -> int:
        return len(self._entries)
