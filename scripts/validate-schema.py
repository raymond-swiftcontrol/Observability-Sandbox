#!/usr/bin/env python3
"""Validate db/migrations against a live PostgreSQL, statement by statement.

Production runs TimescaleDB. This validator exists so the *relational* content
of every migration — domains, tables, constraints, indexes, triggers,
functions, views, grants — can be checked on a vanilla Postgres 16, which is
what CI runners and most developer machines actually have. Timescale-specific
DDL is either shimmed (db/testing/timescale-shim.sql) or rewritten to its
closest vanilla equivalent, and every rewrite is reported so the gap is
visible rather than silent.

Executing statement-by-statement rather than piping the whole file to psql is
deliberate: a failure then points at one statement instead of one file, which
is the difference between a two-minute fix and a bisect.

Usage:
    scripts/validate-schema.py [--database-url URL] [--keep] [--verbose]

Exit status is non-zero if any statement fails.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

try:
    import psycopg2
    from psycopg2 import errors as pg_errors
except ImportError:  # pragma: no cover - surfaced to the operator, not tested
    sys.exit("psycopg2 is required: pip install psycopg2-binary")

ROOT = Path(__file__).resolve().parent.parent
MIGRATIONS = ROOT / "db" / "migrations"
SHIM = ROOT / "db" / "testing" / "timescale-shim.sql"

# ── Statement splitting ─────────────────────────────────────────────────────
# A naive split on ';' breaks on dollar-quoted function bodies, which this
# schema is full of. Track the dollar-quote tag and only split at top level.
DOLLAR_TAG = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)?\$")


def split_statements(sql: str) -> list[str]:
    statements: list[str] = []
    buf: list[str] = []
    i = 0
    tag: str | None = None
    n = len(sql)

    while i < n:
        ch = sql[i]

        if tag is None:
            # Line comment
            if sql.startswith("--", i):
                end = sql.find("\n", i)
                end = n if end == -1 else end
                buf.append(sql[i:end])
                i = end
                continue
            # Block comment
            if sql.startswith("/*", i):
                end = sql.find("*/", i)
                end = n if end == -1 else end + 2
                buf.append(sql[i:end])
                i = end
                continue
            # Single-quoted literal
            if ch == "'":
                j = i + 1
                while j < n:
                    if sql[j] == "'":
                        if j + 1 < n and sql[j + 1] == "'":
                            j += 2
                            continue
                        break
                    j += 1
                buf.append(sql[i : j + 1])
                i = j + 1
                continue
            # Dollar-quote open
            m = DOLLAR_TAG.match(sql, i)
            if m:
                tag = m.group(0)
                buf.append(tag)
                i = m.end()
                continue
            if ch == ";":
                stmt = "".join(buf).strip()
                if stmt:
                    statements.append(stmt)
                buf = []
                i += 1
                continue
        else:
            # Inside a dollar-quoted body: only its matching tag closes it.
            if sql.startswith(tag, i):
                buf.append(tag)
                i += len(tag)
                tag = None
                continue

        buf.append(ch)
        i += 1

    tail = "".join(buf).strip()
    if tail:
        statements.append(tail)
    return statements


# ── Timescale-specific rewrites ─────────────────────────────────────────────
RE_CREATE_EXT_TS = re.compile(r"^\s*CREATE\s+EXTENSION.*timescaledb", re.I | re.S)
RE_ALTER_COMPRESS = re.compile(
    r"^\s*ALTER\s+TABLE\s+(?P<table>[\w.]+)\s+SET\s*\(\s*timescaledb\.", re.I | re.S
)
RE_CAGG = re.compile(r"WITH\s*\(\s*timescaledb\.continuous[^)]*\)", re.I)
RE_WITH_NO_DATA = re.compile(r"\bWITH\s+NO\s+DATA\b", re.I)


@dataclass
class Rewrite:
    migration: str
    kind: str
    detail: str


@dataclass
class Failure:
    migration: str
    index: int
    statement: str
    error: str


@dataclass
class Report:
    applied: int = 0
    skipped: int = 0
    rewrites: list[Rewrite] = field(default_factory=list)
    failures: list[Failure] = field(default_factory=list)


RE_LEADING_COMMENTS = re.compile(r"^(?:\s*(?:--[^\n]*\n|/\*.*?\*/\s*))+", re.S)


def strip_leading_comments(stmt: str) -> str:
    """Drop leading comment lines so the statement's verb is at position 0.

    Every statement here carries a comment block above it, so matching on
    ``^ALTER TABLE`` against the raw text silently never fires — which is how a
    validator quietly stops validating.
    """
    return RE_LEADING_COMMENTS.sub("", stmt, count=1).lstrip()


def transform(stmt: str, migration: str, report: Report) -> str | None:
    """Return the statement to execute, or None to skip it."""
    head = strip_leading_comments(stmt)

    if RE_CREATE_EXT_TS.match(head):
        report.rewrites.append(
            Rewrite(migration, "skip", "CREATE EXTENSION timescaledb (shimmed)")
        )
        return None

    m = RE_ALTER_COMPRESS.match(head)
    if m:
        # Compression settings have no vanilla equivalent. Skipping is correct:
        # they change storage, never the logical schema under test.
        report.rewrites.append(
            Rewrite(migration, "skip", f"compression settings on {m.group('table')}")
        )
        return None

    if RE_CAGG.search(stmt):
        # A continuous aggregate becomes an ordinary materialised view. The
        # SELECT — which is the part that can actually be wrong — is still
        # planned and validated against the real column types.
        stmt = RE_CAGG.sub("", stmt)
        report.rewrites.append(
            Rewrite(migration, "rewrite", "continuous aggregate -> materialized view")
        )

    return stmt


def run(conn, path: Path, report: Report, verbose: bool) -> None:
    sql = path.read_text()
    statements = split_statements(sql)
    name = path.name

    for idx, raw in enumerate(statements, start=1):
        stmt = transform(raw, name, report)
        if stmt is None:
            report.skipped += 1
            continue

        with conn.cursor() as cur:
            try:
                cur.execute(stmt)
                conn.commit()
                report.applied += 1
                if verbose:
                    first = " ".join(stmt.split())[:90]
                    print(f"    ok  [{idx:>3}] {first}")
            except Exception as exc:  # noqa: BLE001 - we report every failure kind
                conn.rollback()
                first = " ".join(stmt.split())[:400]
                report.failures.append(
                    Failure(name, idx, first, f"{type(exc).__name__}: {exc}".strip())
                )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--database-url",
        default=os.environ.get(
            "VALIDATE_DATABASE_URL",
            "postgresql://helios:helios_dev_only@127.0.0.1:5432/helios_schema_check",
        ),
    )
    parser.add_argument("--keep", action="store_true", help="keep the database afterwards")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    target = args.database_url
    dbname = target.rsplit("/", 1)[-1].split("?")[0]
    admin_url = target.rsplit("/", 1)[0] + "/postgres"

    admin = psycopg2.connect(admin_url)
    admin.autocommit = True
    with admin.cursor() as cur:
        cur.execute(
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = %s",
            (dbname,),
        )
        cur.execute(f'DROP DATABASE IF EXISTS "{dbname}"')
        cur.execute(f'CREATE DATABASE "{dbname}"')
    admin.close()

    conn = psycopg2.connect(target)
    report = Report()

    print(f"▸ loading Timescale shim")
    run(conn, SHIM, report, args.verbose)
    if report.failures:
        print("✗ the shim itself failed to load; aborting")
        for f in report.failures:
            print(f"  [{f.index}] {f.error}\n      {f.statement}")
        return 2

    files = sorted(p for p in MIGRATIONS.glob("*.sql") if not p.name.endswith(".down.sql"))
    for path in files:
        before = len(report.failures)
        print(f"▸ {path.name}")
        run(conn, path, report, args.verbose)
        new = len(report.failures) - before
        if new:
            print(f"  ✗ {new} statement(s) failed")

    # Sanity check: the schema should be non-trivially populated. A migration
    # set that "passes" because every statement was skipped is not a pass.
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT count(*) FROM pg_class c
              JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE c.relkind IN ('r','p') AND n.nspname NOT IN
                   ('pg_catalog','information_schema','ts_shim','public')
            """
        )
        tables = cur.fetchone()[0]
        cur.execute(
            """
            SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname NOT IN ('pg_catalog','information_schema','ts_shim','public')
            """
        )
        functions = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM ts_shim.hypertable")
        hypertables = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM ts_shim.policy")
        policies = cur.fetchone()[0]

    conn.close()
    if not args.keep:
        admin = psycopg2.connect(admin_url)
        admin.autocommit = True
        with admin.cursor() as cur:
            cur.execute(f'DROP DATABASE IF EXISTS "{dbname}"')
        admin.close()

    print()
    print("─" * 68)
    print(f"  statements applied : {report.applied}")
    print(f"  skipped (timescale): {report.skipped}")
    print(f"  rewritten          : {sum(1 for r in report.rewrites if r.kind == 'rewrite')}")
    print(f"  tables created     : {tables}")
    print(f"  functions created  : {functions}")
    print(f"  hypertables declared: {hypertables}")
    print(f"  ts policies declared: {policies}")
    print("─" * 68)

    if report.failures:
        print(f"\n✗ {len(report.failures)} failing statement(s):\n")
        for f in report.failures:
            print(f"  {f.migration} [stmt {f.index}]")
            print(f"    {f.error}")
            print(f"    SQL: {f.statement}\n")
        return 1

    print("\n✓ every migration statement applied cleanly")
    print("  Note: compression, chunking, retention and continuous-aggregate")
    print("  behaviour are NOT covered here — they need a real TimescaleDB run.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
