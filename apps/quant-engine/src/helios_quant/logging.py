"""structlog configuration: JSON in deployment, human-readable locally.

Every log line carries the active trace and span id when one exists, because a
log line that cannot be joined to a trace is nearly useless during an incident.
"""

from __future__ import annotations

import logging
import sys
from typing import Any

import structlog
from opentelemetry import trace


def _add_trace_context(
    _logger: object, _name: str, event_dict: structlog.typing.EventDict
) -> structlog.typing.EventDict:
    span = trace.get_current_span()
    ctx = span.get_span_context()
    if ctx.is_valid:
        event_dict["trace_id"] = format(ctx.trace_id, "032x")
        event_dict["span_id"] = format(ctx.span_id, "016x")
    return event_dict


def configure_logging(level: str = "info", *, json_output: bool = True) -> None:
    """Install the shared processor chain. Idempotent — safe to call from tests."""
    numeric = getattr(logging, level.upper(), logging.INFO)
    logging.basicConfig(format="%(message)s", stream=sys.stdout, level=numeric, force=True)

    processors: list[structlog.typing.Processor] = [
        structlog.contextvars.merge_contextvars,
        structlog.stdlib.add_log_level,
        structlog.processors.TimeStamper(fmt="iso", utc=True),
        _add_trace_context,
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
    ]
    processors.append(
        structlog.processors.JSONRenderer() if json_output else structlog.dev.ConsoleRenderer()
    )

    structlog.configure(
        processors=processors,
        wrapper_class=structlog.make_filtering_bound_logger(numeric),
        logger_factory=structlog.PrintLoggerFactory(),
        cache_logger_on_first_use=True,
    )


def get_logger(name: str, **initial: Any) -> structlog.stdlib.BoundLogger:
    """A bound logger. ``name`` lands in the ``logger`` key for Loki queries."""
    logger: structlog.stdlib.BoundLogger = structlog.get_logger(logger=name, **initial)
    return logger
