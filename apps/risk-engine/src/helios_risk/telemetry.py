"""OpenTelemetry bootstrap and the Prometheus registry the ``/metrics`` route serves."""

from __future__ import annotations

from typing import TYPE_CHECKING

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.trace.sampling import ParentBased, TraceIdRatioBased
from prometheus_client import CollectorRegistry, Counter, Gauge, Histogram

from helios_risk.config import Settings

if TYPE_CHECKING:  # pragma: no cover - import cycle only exists for the annotation
    from fastapi import FastAPI

REGISTRY = CollectorRegistry()

HTTP_REQUESTS = Counter(
    "helios_risk_http_requests_total",
    "HTTP requests handled",
    ["method", "route", "status"],
    registry=REGISTRY,
)
HTTP_LATENCY = Histogram(
    "helios_risk_http_request_duration_seconds",
    "HTTP request duration",
    ["method", "route"],
    # Buckets are tight at the bottom: the pre-trade gate lives in the first
    # three of them and a histogram that starts at 5ms cannot show that.
    buckets=(0.0005, 0.001, 0.002, 0.005, 0.01, 0.025, 0.05, 0.1, 0.5, 1.0),
    registry=REGISTRY,
)
PRETRADE_DECISIONS = Counter(
    "helios_risk_pretrade_decisions_total",
    "Pre-trade gate decisions by verdict",
    ["verdict"],
    registry=REGISTRY,
)
PRETRADE_LATENCY = Histogram(
    "helios_risk_pretrade_duration_seconds",
    "Pre-trade gate evaluation time, excluding transport",
    buckets=(0.0001, 0.00025, 0.0005, 0.001, 0.002, 0.005, 0.01, 0.025, 0.05),
    registry=REGISTRY,
)
LIMIT_BREACHES = Counter(
    "helios_risk_limit_breaches_total",
    "Limit rules that evaluated to breach, by rule",
    ["rule", "severity"],
    registry=REGISTRY,
)
KILLSWITCH_ACTIVE = Gauge(
    "helios_risk_killswitch_active",
    "1 when a kill switch is engaged at the given scope",
    ["scope", "scope_id"],
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
        # ParentBased keeps a sampled trace intact across services: the order
        # path's trace starts at the gateway and must not be re-diced here.
        sampler=ParentBased(TraceIdRatioBased(settings.otel_traces_sampler_arg)),
    )
    provider.add_span_processor(
        BatchSpanProcessor(OTLPSpanExporter(endpoint=settings.otel_exporter_otlp_endpoint))
    )
    trace.set_tracer_provider(provider)
    _initialised = True


def instrument_app(app: FastAPI) -> None:
    """Attach FastAPI and asyncpg instrumentation."""
    from opentelemetry.instrumentation.asyncpg import AsyncPGInstrumentor
    from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

    FastAPIInstrumentor.instrument_app(app, excluded_urls="healthz,readyz,metrics")
    # opentelemetry-instrumentation-asyncpg ships no annotations for its
    # instrumentor constructor; the call is correct, the stub is absent.
    AsyncPGInstrumentor().instrument()  # type: ignore[no-untyped-call]


def tracer() -> trace.Tracer:
    return trace.get_tracer("helios_risk")
