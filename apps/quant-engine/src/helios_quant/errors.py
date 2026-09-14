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
    "lookahead_violation",
    "insufficient_history",
    "infeasible_problem",
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


class HeliosError(Exception):
    """Base class for errors that map to a known status code and envelope."""

    code: ErrorCode = "internal_error"
    status_code: int = 500

    def __init__(self, message: str, **details: Any) -> None:
        super().__init__(message)
        self.message = message
        self.details = details


class NotFoundError(HeliosError):
    code: ErrorCode = "not_found"
    status_code = 404


class ConflictError(HeliosError):
    code: ErrorCode = "conflict"
    status_code = 409


class ValidationError(HeliosError):
    code: ErrorCode = "validation_error"
    status_code = 422


class LookaheadError(HeliosError):
    """Raised when a computation is asked for data it could not have had.

    This is deliberately an error and not a warning. A silently-tolerated
    lookahead produces a backtest that looks better than reality, which is the
    most expensive class of bug this service can ship.
    """

    code: ErrorCode = "lookahead_violation"
    status_code = 422


class InsufficientHistoryError(HeliosError):
    """A feature or estimator was given fewer observations than its lookback."""

    code: ErrorCode = "insufficient_history"
    status_code = 422


class InfeasibleProblemError(HeliosError):
    """An optimiser's constraint set admits no solution."""

    code: ErrorCode = "infeasible_problem"
    status_code = 422


class DependencyUnavailableError(HeliosError):
    code: ErrorCode = "dependency_unavailable"
    status_code = 503
