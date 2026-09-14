"""Runtime configuration, read from the environment that ``.env.example`` documents."""

from __future__ import annotations

from functools import lru_cache

from pydantic import Field, field_validator
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
    service_name: str = "quant-engine"
    port: int = 8100

    database_url: str = "postgresql://helios:helios_dev_only@localhost:5432/helios?sslmode=disable"
    database_pool_max: int = 20
    database_statement_timeout_ms: int = 15_000

    redis_url: str = "redis://localhost:6379/0"
    kafka_brokers: str = "localhost:19092"
    kafka_client_id: str = "helios-quant-engine"
    kafka_topic_signals: str = "strategy.signals.v1"

    s3_endpoint: str = "http://localhost:9000"
    s3_region: str = "us-east-1"
    s3_bucket_features: str = "helios-feature-store"
    s3_bucket_artifacts: str = "helios-artifacts"
    s3_access_key_id: str = "minioadmin"
    s3_secret_access_key: str = "minioadmin"

    otel_exporter_otlp_endpoint: str = "http://localhost:4317"
    otel_service_namespace: str = "helios"
    otel_traces_sampler_arg: float = 0.25
    otel_sdk_disabled: bool = False
    prometheus_port: int = 9464

    # Risk-free rate used by Sharpe and friends when a caller does not supply one.
    # A wrong default here silently shifts every Sharpe in the system, so it is
    # configuration rather than a literal buried in performance/stats.py.
    default_risk_free_rate: float = 0.0
    trading_days_per_year: int = 252

    @field_validator("database_url")
    @classmethod
    def _asyncpg_driver(cls, v: str) -> str:
        """asyncpg needs the ``postgresql+asyncpg`` scheme and rejects libpq options.

        ``sslmode`` is a libpq spelling; asyncpg calls it ``ssl``. Rather than
        translate it here and get it subtly wrong, the parameter is dropped and
        TLS is configured on the engine's connect_args.
        """
        url = v.replace("postgresql+asyncpg://", "postgresql://")
        base, _, query = url.partition("?")
        kept = [kv for kv in query.split("&") if kv and not kv.startswith("sslmode=")]
        out = base.replace("postgresql://", "postgresql+asyncpg://", 1)
        return f"{out}?{'&'.join(kept)}" if kept else out

    @property
    def sslmode(self) -> str:
        """The libpq sslmode the original URL asked for, preserved for connect_args."""
        return "disable" if "sslmode=disable" in self._raw_database_url else "prefer"

    _raw_database_url: str = Field(default="", exclude=True)


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Process-wide settings. Cached: parsing the environment per request is waste."""
    return Settings()
