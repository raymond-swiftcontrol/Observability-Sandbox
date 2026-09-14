"""Runtime configuration, read from the environment that ``.env.example`` documents."""

from __future__ import annotations

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Process configuration.

    Field names mirror the environment variable names in ``.env.example`` so that
    a reader can grep either one and find the other.
    """

    model_config = SettingsConfigDict(
        env_file=(".env", "../../.env"), extra="ignore", case_sensitive=False
    )

    helios_env: str = "local"
    log_level: str = "info"
    service_name: str = "risk-engine"
    port: int = 8200

    database_url: str = "postgresql://helios:helios_dev_only@localhost:5432/helios?sslmode=disable"
    database_pool_max: int = 20
    database_statement_timeout_ms: int = 15_000

    redis_url: str = "redis://localhost:6379/0"

    otel_exporter_otlp_endpoint: str = "http://localhost:4317"
    otel_service_namespace: str = "helios"
    otel_traces_sampler_arg: float = 0.25
    otel_sdk_disabled: bool = False
    prometheus_port: int = 9464

    # ── Risk policy defaults ────────────────────────────────────────────────
    # The pre-trade gate's wall-clock budget. Exceeding it does not fail the
    # order — a slow risk check that rejects is worse than a slow risk check
    # that passes — but it is recorded on the decision and alerted on.
    pretrade_latency_budget_ms: float = 5.0
    # How long a cached account snapshot may be reused on the hot path. Longer
    # means fewer round trips and a staler view of buying power.
    limit_cache_ttl_seconds: float = 1.0

    # FINRA pattern-day-trader threshold. Below this equity an account is
    # capped at 3 day trades in a rolling 5 business days.
    pdt_equity_threshold: float = 25_000.0
    pdt_max_day_trades: int = 3

    # Continuously compounded risk-free rate used by the option pricers when a
    # caller does not supply one. Wrong here means wrong greeks everywhere, so
    # it is configuration rather than a literal in black_scholes.py.
    default_risk_free_rate: float = 0.04
    default_dividend_yield: float = 0.0
    trading_days_per_year: int = 252


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Process-wide settings. Cached: parsing the environment per request is waste."""
    return Settings()
