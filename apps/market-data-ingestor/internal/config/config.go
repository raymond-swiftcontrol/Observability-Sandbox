// Package config loads the ingestor's configuration from the environment and
// validates it eagerly.
//
// The bias throughout is to fail at startup rather than at the first tick: a
// bad Kafka topic name or a zero flush interval discovered under load is an
// incident, discovered during `docker compose up` it is a typo. Every problem
// found is reported together so an operator fixes one round of mistakes, not
// one mistake per restart.
package config

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// Mode selects where market data comes from. Mirrors MARKET_DATA_MODE.
type Mode string

// Supported ingestion modes.
const (
	ModeLive      Mode = "live"
	ModeReplay    Mode = "replay"
	ModeSynthetic Mode = "synthetic"
)

// Config is the fully resolved runtime configuration.
type Config struct {
	Env      string
	LogLevel string
	Mode     Mode

	Service   ServiceConfig
	Database  DatabaseConfig
	Kafka     KafkaConfig
	Telemetry TelemetryConfig
	Vendors   VendorConfig
	Aggregate AggregateConfig
	Book      BookConfig
	Symbols   []string
}

// ServiceConfig covers the process' own listeners.
type ServiceConfig struct {
	GRPCAddr    string
	HTTPAddr    string // health, readiness and /metrics
	ShutdownMax time.Duration
}

// DatabaseConfig covers the TimescaleDB sink and the reference-data reads.
type DatabaseConfig struct {
	URL              string
	PoolMax          int32
	StatementTimeout time.Duration
	// BatchRows and BatchInterval bound a CopyFrom batch on both size and age,
	// so a quiet symbol set still lands within BatchInterval.
	BatchRows     int
	BatchInterval time.Duration
	// BufferRows is the in-memory backlog tolerated while the database is
	// unavailable before the writer starts shedding (and counting) rows.
	BufferRows int
	// SymbolCacheTTL bounds staleness of reference.instrument_vendor_map.
	SymbolCacheTTL         time.Duration
	SymbolNegativeCacheTTL time.Duration
}

// KafkaConfig covers the event backbone producer.
type KafkaConfig struct {
	Brokers       []string
	ClientID      string
	TopicTicks    string
	TopicQuotes   string
	TopicBars     string
	TopicBook     string
	TopicDLQ      string
	MaxBuffered   int
	ProduceTimout time.Duration
	Compression   string
}

// TelemetryConfig covers OTel export.
type TelemetryConfig struct {
	OTLPEndpoint   string
	ServiceName    string
	Namespace      string
	SamplerRatio   float64
	MetricInterval time.Duration
}

// VendorConfig holds per-vendor credentials and endpoints.
type VendorConfig struct {
	Enabled []string

	PolygonURL    string
	PolygonAPIKey string

	AlpacaURL    string
	AlpacaKeyID  string
	AlpacaSecret string

	BinanceURL    string
	BinanceKey    string
	BinanceSecret string

	SimURL string
	// SimSeed makes the synthetic generator reproducible; two runs with the
	// same seed and symbol set produce byte-identical tapes, which is what
	// makes the sandbox usable as a regression fixture.
	SimSeed     int64
	SimRate     int
	HeartbeatTO time.Duration

	// Backoff and breaker settings shared by every adapter.
	BackoffMin       time.Duration
	BackoffMax       time.Duration
	BackoffJitter    float64
	BreakerThreshold int
	BreakerCooldown  time.Duration
}

// AggregateConfig tunes the tick→bar aggregator.
type AggregateConfig struct {
	Interval time.Duration
	// Grace is how long after a bucket closes a late tick is still folded in.
	// Beyond it the tick is counted as late-dropped rather than silently
	// mutating a bar a consumer has already persisted.
	Grace time.Duration
	// CloseCheck is the ticker period that drives bucket close. It must divide
	// into Grace comfortably or a quiet symbol closes late.
	CloseCheck time.Duration
}

// BookConfig tunes the L2 book manager.
type BookConfig struct {
	Depth          int
	SnapshotEvery  time.Duration
	MaxGapResyncs  int
	StaleAfter     time.Duration
	PublishOnDelta bool
}

// Error aggregates every validation failure found in one pass.
type Error struct{ Problems []string }

func (e *Error) Error() string {
	return fmt.Sprintf("invalid configuration:\n  - %s", strings.Join(e.Problems, "\n  - "))
}

type loader struct{ problems []string }

func (l *loader) fail(format string, args ...any) {
	l.problems = append(l.problems, fmt.Sprintf(format, args...))
}

func (l *loader) str(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return def
}

func (l *loader) required(key string) string {
	v := os.Getenv(key)
	if strings.TrimSpace(v) == "" {
		l.fail("%s is required", key)
	}
	return v
}

func (l *loader) duration(key string, def time.Duration) time.Duration {
	raw, ok := os.LookupEnv(key)
	if !ok || raw == "" {
		return def
	}
	d, err := time.ParseDuration(raw)
	if err != nil {
		l.fail("%s=%q is not a duration: %v", key, raw, err)
		return def
	}
	if d <= 0 {
		l.fail("%s=%q must be positive", key, raw)
		return def
	}
	return d
}

func (l *loader) int(key string, def int) int {
	raw, ok := os.LookupEnv(key)
	if !ok || raw == "" {
		return def
	}
	v, err := strconv.Atoi(raw)
	if err != nil {
		l.fail("%s=%q is not an integer: %v", key, raw, err)
		return def
	}
	return v
}

func (l *loader) float(key string, def float64) float64 {
	raw, ok := os.LookupEnv(key)
	if !ok || raw == "" {
		return def
	}
	v, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		l.fail("%s=%q is not a number: %v", key, raw, err)
		return def
	}
	return v
}

func (l *loader) list(key, def string) []string {
	raw := l.str(key, def)
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// Load reads the process environment. The returned error is an *Error listing
// every problem; callers should print it and exit non-zero.
func Load() (*Config, error) {
	l := &loader{}

	// MARKET_DATA_MODE in .env.example carries a trailing comment on the same
	// line for some shells' benefit, so trim anything past a '#'.
	rawMode := strings.TrimSpace(strings.SplitN(l.str("MARKET_DATA_MODE", string(ModeSynthetic)), "#", 2)[0])
	mode := Mode(rawMode)
	switch mode {
	case ModeLive, ModeReplay, ModeSynthetic:
	default:
		l.fail("MARKET_DATA_MODE=%q must be one of live|replay|synthetic", rawMode)
		mode = ModeSynthetic
	}

	cfg := &Config{
		Env:      l.str("HELIOS_ENV", "local"),
		LogLevel: strings.ToLower(l.str("LOG_LEVEL", "info")),
		Mode:     mode,
		Service: ServiceConfig{
			GRPCAddr:    normaliseAddr(l.str("MARKET_DATA_GRPC", ":9400")),
			HTTPAddr:    normaliseAddr(l.str("MARKET_DATA_HTTP_ADDR", ":"+strconv.Itoa(l.int("PROMETHEUS_PORT", 9464)))),
			ShutdownMax: l.duration("SHUTDOWN_GRACE", 20*time.Second),
		},
		Database: DatabaseConfig{
			URL:                    l.str("DATABASE_URL", ""),
			PoolMax:                int32(l.int("DATABASE_POOL_MAX", 20)),
			StatementTimeout:       time.Duration(l.int("DATABASE_STATEMENT_TIMEOUT_MS", 15000)) * time.Millisecond,
			BatchRows:              l.int("MD_DB_BATCH_ROWS", 5000),
			BatchInterval:          l.duration("MD_DB_BATCH_INTERVAL", 2*time.Second),
			BufferRows:             l.int("MD_DB_BUFFER_ROWS", 200000),
			SymbolCacheTTL:         l.duration("MD_SYMBOL_CACHE_TTL", 10*time.Minute),
			SymbolNegativeCacheTTL: l.duration("MD_SYMBOL_NEGATIVE_CACHE_TTL", 30*time.Second),
		},
		Kafka: KafkaConfig{
			Brokers:       l.list("KAFKA_BROKERS", "localhost:19092"),
			ClientID:      l.str("KAFKA_CLIENT_ID", "helios-market-data-ingestor"),
			TopicTicks:    l.str("KAFKA_TOPIC_TICKS", "md.ticks.v1"),
			TopicQuotes:   l.str("KAFKA_TOPIC_QUOTES", "md.ticks.v1"),
			TopicBars:     l.str("KAFKA_TOPIC_BARS", "md.bars.v1"),
			TopicBook:     l.str("KAFKA_TOPIC_BOOK", "md.book.snapshots.v1"),
			TopicDLQ:      l.str("KAFKA_TOPIC_DLQ", "helios.dlq.v1"),
			MaxBuffered:   l.int("MD_KAFKA_MAX_BUFFERED", 50000),
			ProduceTimout: l.duration("MD_KAFKA_PRODUCE_TIMEOUT", 10*time.Second),
			Compression:   l.str("MD_KAFKA_COMPRESSION", "zstd"),
		},
		Telemetry: TelemetryConfig{
			OTLPEndpoint:   l.str("OTEL_EXPORTER_OTLP_ENDPOINT", ""),
			ServiceName:    l.str("OTEL_SERVICE_NAME", "market-data-ingestor"),
			Namespace:      l.str("OTEL_SERVICE_NAMESPACE", "helios"),
			SamplerRatio:   l.float("OTEL_TRACES_SAMPLER_ARG", 0.25),
			MetricInterval: l.duration("OTEL_METRIC_EXPORT_INTERVAL", 15*time.Second),
		},
		Vendors: VendorConfig{
			Enabled:          l.list("MD_VENDORS", ""),
			PolygonURL:       l.str("VENDOR_POLYGON_URL", "wss://socket.polygon.io/stocks"),
			PolygonAPIKey:    l.str("VENDOR_POLYGON_API_KEY", ""),
			AlpacaURL:        l.str("VENDOR_ALPACA_URL", "wss://stream.data.alpaca.markets/v2/iex"),
			AlpacaKeyID:      l.str("VENDOR_ALPACA_KEY_ID", ""),
			AlpacaSecret:     l.str("VENDOR_ALPACA_SECRET", ""),
			BinanceURL:       l.str("VENDOR_BINANCE_URL", "wss://stream.binance.com:9443/stream"),
			BinanceKey:       l.str("VENDOR_BINANCE_KEY", ""),
			BinanceSecret:    l.str("VENDOR_BINANCE_SECRET", ""),
			SimURL:           l.str("VENDOR_SIM_URL", ""),
			SimSeed:          int64(l.int("MD_SIM_SEED", 20240914)),
			SimRate:          l.int("MD_SIM_RATE", 20),
			HeartbeatTO:      l.duration("MD_HEARTBEAT_TIMEOUT", 30*time.Second),
			BackoffMin:       l.duration("MD_BACKOFF_MIN", 250*time.Millisecond),
			BackoffMax:       l.duration("MD_BACKOFF_MAX", 30*time.Second),
			BackoffJitter:    l.float("MD_BACKOFF_JITTER", 0.3),
			BreakerThreshold: l.int("MD_BREAKER_THRESHOLD", 5),
			BreakerCooldown:  l.duration("MD_BREAKER_COOLDOWN", 60*time.Second),
		},
		Aggregate: AggregateConfig{
			Interval:   l.duration("MD_BAR_INTERVAL", time.Minute),
			Grace:      l.duration("MD_BAR_GRACE", 3*time.Second),
			CloseCheck: l.duration("MD_BAR_CLOSE_CHECK", time.Second),
		},
		Book: BookConfig{
			Depth:          l.int("MD_BOOK_DEPTH", 10),
			SnapshotEvery:  l.duration("MD_BOOK_SNAPSHOT_EVERY", 5*time.Second),
			MaxGapResyncs:  l.int("MD_BOOK_MAX_RESYNCS", 20),
			StaleAfter:     l.duration("MD_BOOK_STALE_AFTER", time.Minute),
			PublishOnDelta: l.str("MD_BOOK_PUBLISH_ON_DELTA", "false") == "true",
		},
		Symbols: l.list("MD_SYMBOLS", "AAPL,MSFT,NVDA,SPY,BTC-USD,ETH-USD"),
	}

	if len(cfg.Vendors.Enabled) == 0 {
		// Synthetic and replay both run entirely off the local generator, which
		// is what lets `docker compose up` work with no vendor credentials.
		if mode == ModeLive {
			cfg.Vendors.Enabled = []string{"polygon"}
		} else {
			cfg.Vendors.Enabled = []string{"sim"}
		}
	}

	l.validate(cfg)

	if len(l.problems) > 0 {
		return nil, &Error{Problems: l.problems}
	}
	return cfg, nil
}

func (l *loader) validate(cfg *Config) {
	switch cfg.LogLevel {
	case "debug", "info", "warn", "error":
	default:
		l.fail("LOG_LEVEL=%q must be one of debug|info|warn|error", cfg.LogLevel)
	}
	if len(cfg.Kafka.Brokers) == 0 {
		l.fail("KAFKA_BROKERS must list at least one broker")
	}
	for _, t := range []struct{ name, val string }{
		{"KAFKA_TOPIC_TICKS", cfg.Kafka.TopicTicks},
		{"KAFKA_TOPIC_BARS", cfg.Kafka.TopicBars},
		{"KAFKA_TOPIC_BOOK", cfg.Kafka.TopicBook},
		{"KAFKA_TOPIC_DLQ", cfg.Kafka.TopicDLQ},
	} {
		if strings.TrimSpace(t.val) == "" {
			l.fail("%s must not be empty", t.name)
		}
	}
	if cfg.Kafka.MaxBuffered <= 0 {
		l.fail("MD_KAFKA_MAX_BUFFERED must be positive; an unbounded producer buffer turns broker downtime into an OOM")
	}
	if cfg.Telemetry.SamplerRatio < 0 || cfg.Telemetry.SamplerRatio > 1 {
		l.fail("OTEL_TRACES_SAMPLER_ARG=%v must be within [0,1]", cfg.Telemetry.SamplerRatio)
	}
	if cfg.Database.BatchRows <= 0 {
		l.fail("MD_DB_BATCH_ROWS must be positive")
	}
	if cfg.Database.BufferRows < cfg.Database.BatchRows {
		l.fail("MD_DB_BUFFER_ROWS (%d) must be at least MD_DB_BATCH_ROWS (%d)", cfg.Database.BufferRows, cfg.Database.BatchRows)
	}
	if cfg.Aggregate.CloseCheck >= cfg.Aggregate.Interval {
		l.fail("MD_BAR_CLOSE_CHECK (%s) must be shorter than MD_BAR_INTERVAL (%s), otherwise a quiet symbol's bar closes a whole bucket late",
			cfg.Aggregate.CloseCheck, cfg.Aggregate.Interval)
	}
	if cfg.Aggregate.Grace >= cfg.Aggregate.Interval {
		l.fail("MD_BAR_GRACE (%s) must be shorter than MD_BAR_INTERVAL (%s)", cfg.Aggregate.Grace, cfg.Aggregate.Interval)
	}
	if cfg.Book.Depth <= 0 || cfg.Book.Depth > 1000 {
		l.fail("MD_BOOK_DEPTH=%d must be within [1,1000]", cfg.Book.Depth)
	}
	if cfg.Vendors.BackoffJitter < 0 || cfg.Vendors.BackoffJitter > 1 {
		l.fail("MD_BACKOFF_JITTER=%v must be within [0,1]", cfg.Vendors.BackoffJitter)
	}
	if cfg.Vendors.BackoffMin > cfg.Vendors.BackoffMax {
		l.fail("MD_BACKOFF_MIN (%s) must not exceed MD_BACKOFF_MAX (%s)", cfg.Vendors.BackoffMin, cfg.Vendors.BackoffMax)
	}
	if cfg.Vendors.BreakerThreshold <= 0 {
		l.fail("MD_BREAKER_THRESHOLD must be positive")
	}
	if cfg.Vendors.SimRate <= 0 {
		l.fail("MD_SIM_RATE must be positive")
	}
	if len(cfg.Symbols) == 0 {
		l.fail("MD_SYMBOLS must list at least one symbol")
	}

	seen := map[string]bool{}
	for _, v := range cfg.Vendors.Enabled {
		if seen[v] {
			l.fail("MD_VENDORS lists %q twice", v)
		}
		seen[v] = true
		switch v {
		case "sim":
		case "polygon":
			if cfg.Mode == ModeLive && cfg.Vendors.PolygonAPIKey == "" {
				l.fail("VENDOR_POLYGON_API_KEY is required when polygon is enabled in live mode")
			}
		case "alpaca":
			if cfg.Mode == ModeLive && (cfg.Vendors.AlpacaKeyID == "" || cfg.Vendors.AlpacaSecret == "") {
				l.fail("VENDOR_ALPACA_KEY_ID and VENDOR_ALPACA_SECRET are required when alpaca is enabled in live mode")
			}
		case "binance":
			// Binance market data streams are public; no credential check.
		default:
			l.fail("MD_VENDORS contains unknown vendor %q (want sim|polygon|alpaca|binance)", v)
		}
	}
	if cfg.Mode != ModeLive && !seen["sim"] {
		l.fail("MARKET_DATA_MODE=%s requires the sim vendor to be enabled", cfg.Mode)
	}
}

// normaliseAddr accepts both "host:port" and a bare ":port".
func normaliseAddr(v string) string {
	if v == "" {
		return v
	}
	if !strings.Contains(v, ":") {
		return ":" + v
	}
	return v
}

// ErrNoDatabase is returned by sinks when DATABASE_URL was left empty. The
// service still runs — Kafka-only operation is a legitimate deployment — but
// the readiness probe reports the degraded state rather than lying.
var ErrNoDatabase = errors.New("config: DATABASE_URL is not set")
