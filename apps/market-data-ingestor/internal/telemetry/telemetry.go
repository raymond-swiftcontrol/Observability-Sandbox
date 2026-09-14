// Package telemetry wires OpenTelemetry traces, metrics and logs.
//
// This repository doubles as an observability sandbox, so instrumentation is
// treated as a feature rather than as decoration. Three choices are worth
// calling out:
//
//   - Metrics are exported twice: OTLP to the collector, and a Prometheus
//     /metrics endpoint. The scrape endpoint means the service is debuggable
//     with curl when the collector is the thing that is broken.
//   - Logs carry trace_id/span_id pulled from the context. Without that, a
//     latency spike in Tempo has no path to the log line that explains it.
//   - The trace exporter is optional. A missing collector must not stop the
//     ingestor from ingesting; it degrades to a no-op tracer and says so once.
package telemetry

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	promexp "go.opentelemetry.io/otel/exporters/prometheus"
	"go.opentelemetry.io/otel/metric"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
	"go.opentelemetry.io/otel/trace"
)

// Options configures Setup.
type Options struct {
	ServiceName    string
	ServiceVersion string
	Namespace      string
	Environment    string
	OTLPEndpoint   string
	SamplerRatio   float64
	MetricInterval time.Duration
	LogLevel       string
}

// Provider owns the exporters and hands out tracers, meters and the scrape
// handler. Shutdown is idempotent.
type Provider struct {
	Tracer  trace.Tracer
	Meter   metric.Meter
	Logger  *slog.Logger
	Metrics *Metrics

	registry  *prometheus.Registry
	shutdowns []func(context.Context) error
}

// Setup builds the telemetry stack. A failure to reach the OTLP collector is
// reported through the returned logger but is never fatal.
func Setup(ctx context.Context, opts Options) (*Provider, error) {
	res, err := resource.Merge(resource.Default(), resource.NewWithAttributes(
		semconv.SchemaURL,
		semconv.ServiceName(opts.ServiceName),
		semconv.ServiceVersion(orDefault(opts.ServiceVersion, "dev")),
		semconv.ServiceNamespace(opts.Namespace),
		attribute.String("deployment.environment", opts.Environment),
	))
	if err != nil {
		return nil, fmt.Errorf("build otel resource: %w", err)
	}

	p := &Provider{registry: prometheus.NewRegistry()}
	p.Logger = newLogger(opts.LogLevel, opts.ServiceName)

	// ── traces ──
	var tp *sdktrace.TracerProvider
	if opts.OTLPEndpoint != "" {
		exp, err := otlptracegrpc.New(ctx,
			otlptracegrpc.WithEndpointURL(opts.OTLPEndpoint),
			otlptracegrpc.WithTimeout(5*time.Second),
		)
		if err != nil {
			// Deliberately non-fatal: see package doc.
			p.Logger.Warn("otlp trace exporter unavailable, tracing disabled",
				slog.String("endpoint", opts.OTLPEndpoint), slog.Any("error", err))
			tp = sdktrace.NewTracerProvider(sdktrace.WithResource(res))
		} else {
			tp = sdktrace.NewTracerProvider(
				sdktrace.WithResource(res),
				sdktrace.WithBatcher(exp, sdktrace.WithMaxQueueSize(8192)),
				// ParentBased so a sampled request from the API gateway keeps
				// its whole downstream trace, independent of our ratio.
				sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.TraceIDRatioBased(opts.SamplerRatio))),
			)
		}
	} else {
		tp = sdktrace.NewTracerProvider(sdktrace.WithResource(res))
	}
	otel.SetTracerProvider(tp)
	p.shutdowns = append(p.shutdowns, tp.Shutdown)
	p.Tracer = tp.Tracer("github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor")

	// ── metrics ──
	readers := []sdkmetric.Option{}
	promReader, err := promexp.New(promexp.WithRegisterer(p.registry))
	if err != nil {
		return nil, fmt.Errorf("build prometheus exporter: %w", err)
	}
	readers = append(readers, sdkmetric.WithReader(promReader))

	if opts.OTLPEndpoint != "" {
		mexp, err := otlpmetricgrpc.New(ctx,
			otlpmetricgrpc.WithEndpointURL(opts.OTLPEndpoint),
			otlpmetricgrpc.WithTimeout(5*time.Second),
		)
		if err != nil {
			p.Logger.Warn("otlp metric exporter unavailable, scrape endpoint only",
				slog.String("endpoint", opts.OTLPEndpoint), slog.Any("error", err))
		} else {
			readers = append(readers, sdkmetric.WithReader(
				sdkmetric.NewPeriodicReader(mexp, sdkmetric.WithInterval(opts.MetricInterval))))
		}
	}

	mpOpts := append([]sdkmetric.Option{sdkmetric.WithResource(res)}, readers...)
	mp := sdkmetric.NewMeterProvider(mpOpts...)
	otel.SetMeterProvider(mp)
	p.shutdowns = append(p.shutdowns, mp.Shutdown)
	p.Meter = mp.Meter("github.com/raymond-swiftcontrol/helios/apps/market-data-ingestor")

	p.Metrics, err = NewMetrics(p.Meter)
	if err != nil {
		return nil, fmt.Errorf("register metrics: %w", err)
	}
	return p, nil
}

// MetricsHandler returns the Prometheus scrape handler.
func (p *Provider) MetricsHandler() http.Handler {
	return promhttp.HandlerFor(p.registry, promhttp.HandlerOpts{EnableOpenMetrics: true})
}

// Shutdown flushes exporters. Errors are joined so one broken exporter does not
// hide another.
func (p *Provider) Shutdown(ctx context.Context) error {
	var firstErr error
	for i := len(p.shutdowns) - 1; i >= 0; i-- {
		if err := p.shutdowns[i](ctx); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

// ── logging ──────────────────────────────────────────────────────────────────

type traceHandler struct{ slog.Handler }

// Handle stamps trace_id and span_id onto every record emitted with a context
// that carries a recording span. This is the join key between Loki and Tempo.
func (h traceHandler) Handle(ctx context.Context, r slog.Record) error {
	if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
		r.AddAttrs(
			slog.String("trace_id", sc.TraceID().String()),
			slog.String("span_id", sc.SpanID().String()),
		)
	}
	return h.Handler.Handle(ctx, r)
}

func (h traceHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return traceHandler{h.Handler.WithAttrs(attrs)}
}

func (h traceHandler) WithGroup(name string) slog.Handler {
	return traceHandler{h.Handler.WithGroup(name)}
}

func newLogger(level, service string) *slog.Logger {
	var lv slog.Level
	switch level {
	case "debug":
		lv = slog.LevelDebug
	case "warn":
		lv = slog.LevelWarn
	case "error":
		lv = slog.LevelError
	default:
		lv = slog.LevelInfo
	}
	base := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: lv})
	l := slog.New(traceHandler{base}).With(slog.String("service", service))
	slog.SetDefault(l)
	return l
}

func orDefault(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

// KV is a small helper for the attribute sets used on the hot path, kept here
// so callers do not import otel/attribute everywhere.
func KV(k, v string) attribute.KeyValue { return attribute.String(k, v) }
