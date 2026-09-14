"""Typed error envelopes.

Every non-2xx response from this service has the same body shape, because the
mobile client has to render errors without special-casing each endpoint:

    {"error": {"code": "...", "message": "...", "details": {...},
               "trace_id": "...", "request_id": "..."}}
"""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field

ErrorCode = Literal[
    "validation_error",
    "not_found",
    "conflict",
    "limit_breach",
    "kill_switch_engaged",
    "market_data_stale",
    "convergence_failure",
    "dependency_unavailable",
    "internal_error",
]


class ErrorBody(BaseModel):
    code: ErrorCode
    message: str
    details: dict[str, Any] = Field(default_factory=dict)
    trace_id: str | None = None
    request_id: str | None = None


class ErrorEnvelope(BaseModel):
    error: ErrorBody


class HeliosRiskError(Exception):
    """Base class for errors that map to a known status code and envelope."""

    code: ErrorCode = "internal_error"
    status_code: int = 500

    def __init__(self, message: str, **details: Any) -> None:
        super().__init__(message)
        self.message = message
        self.details = details


class NotFoundError(HeliosRiskError):
    code: ErrorCode = "not_found"
    status_code = 404


class ConflictError(HeliosRiskError):
    code: ErrorCode = "conflict"
    status_code = 409


class ValidationError(HeliosRiskError):
    code: ErrorCode = "validation_error"
    status_code = 422


class KillSwitchEngagedError(HeliosRiskError):
    """Trading is halted at some scope covering the request."""

    code: ErrorCode = "kill_switch_engaged"
    status_code = 423  # Locked — the request was well-formed, the desk is not open


class StaleMarketDataError(HeliosRiskError):
    """A risk number was requested against marks older than the tolerance.

    Returning a VaR computed from yesterday's prices without saying so is worse
    than returning nothing: the caller has no way to tell the difference.
    """

    code: ErrorCode = "market_data_stale"
    status_code = 409


class ConvergenceError(HeliosRiskError):
    """A solver failed to converge.

    Implied vol in particular must never silently return its last iterate: a
    wrong vol propagates into every greek and then into delta-adjusted
    exposure, where it is invisible.
    """

    code: ErrorCode = "convergence_failure"
    status_code = 422


class DependencyUnavailableError(HeliosRiskError):
    code: ErrorCode = "dependency_unavailable"
    status_code = 503
