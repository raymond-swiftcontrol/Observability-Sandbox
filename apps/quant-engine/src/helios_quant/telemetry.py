"""OpenTelemetry bootstrap and the Prometheus registry the ``/metrics`` route serves."""

from __future__ import annotations

from typing import TYPE_CHECKING

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.trace.sampling import ParentBased, TraceIdRatioBased
from prometheus_client import CollectorRegistry, Counter, Histogram

from helios_quant.config import Settings

if TYPE_CHECKING:  # pragma: no cover - import cycle only exists for the annotation
    from fastapi import FastAPI

REGISTRY = CollectorRegistry()

HTTP_REQUESTS = Counter(
    "helios_quant_http_requests_total",
    "HTTP requests handled",
    ["method", "route", "status"],
    registry=REGISTRY,
)
HTTP_LATENCY = Histogram(
    "helios_quant_http_request_duration_seconds",
    "HTTP request duration",
    ["method", "route"],
    # Buckets chosen around the surfaces that matter: a feature read should be
    # single-digit ms, a synchronous backtest submit is allowed ~1s.
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0),
    registry=REGISTRY,
)
BACKTESTS_RUN = Counter(
    "helios_quant_backtests_total",
    "Backtests executed, by engine and outcome",
    ["engine", "outcome"],
    registry=REGISTRY,
)
FEATURE_ROWS = Counter(
    "helios_quant_feature_rows_total",
    "Feature rows written to the point-in-time store",
    ["feature"],
    registry=REGISTRY,
)

_initialised = False


def setup_tracing(settings: Settings) -> None:
    """Install a tracer provider. No-op when already installed or disabled."""
    global _initialised
    if _initialised or settings.otel_sdk_disabled:
        return
    resource = Resource.create(
        {
            "service.name": settings.service_name,
            "service.namespace": settings.otel_service_namespace,
            "deployment.environment": settings.helios_env,
        }
    )
    provider = TracerProvider(
        resource=resource,
        # ParentBased keeps a sampled trace intact across services: sampling the
        # gateway's decision again here would produce orphaned spans.
        sampler=ParentBased(TraceIdRatioBased(settings.otel_traces_sampler_arg)),
    )
    provider.add_span_processor(
        BatchSpanProcessor(OTLPSpanExporter(endpoint=settings.otel_exporter_otlp_endpoint))
    )
    trace.set_tracer_provider(provider)
    _initialised = True


def instrument_app(app: FastAPI) -> None:
    """Attach FastAPI and asyncpg instrumentation; tolerate missing extras."""
    from opentelemetry.instrumentation.asyncpg import AsyncPGInstrumentor
    from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

    FastAPIInstrumentor.instrument_app(app, excluded_urls="healthz,readyz,metrics")
    AsyncPGInstrumentor().instrument()


def tracer() -> trace.Tracer:
    return trace.get_tracer("helios_quant")
