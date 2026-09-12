#!/usr/bin/env bash
# Forward-only SQL migration runner.
#
#   ./scripts/db-migrate.sh up          apply all pending migrations
#   ./scripts/db-migrate.sh up 3        apply the next 3
#   ./scripts/db-migrate.sh down 1      roll back the last 1 (needs a .down.sql)
#   ./scripts/db-migrate.sh status      show applied/pending
#
# Each migration runs in a single transaction together with its bookkeeping row,
# so a failure leaves the ledger consistent. Checksums detect edited migrations.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS_DIR="${ROOT}/db/migrations"
# shellcheck disable=SC1091
[[ -f "${ROOT}/.env" ]] && set -a && source "${ROOT}/.env" && set +a

DATABASE_URL="${DATABASE_URL:-postgresql://helios:helios_dev_only@localhost:5432/helios?sslmode=disable}"
PSQL=(psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -q --no-psqlrc)

log()  { printf '\033[36m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

ensure_ledger() {
  "${PSQL[@]}" <<'SQL'
CREATE SCHEMA IF NOT EXISTS helios_meta;
CREATE TABLE IF NOT EXISTS helios_meta.schema_migrations (
  version      text PRIMARY KEY,
  name         text        NOT NULL,
  checksum     text        NOT NULL,
  applied_at   timestamptz NOT NULL DEFAULT now(),
  applied_by   text        NOT NULL DEFAULT current_user,
  duration_ms  integer     NOT NULL DEFAULT 0
);
SQL
}

checksum() { sha256sum "$1" | cut -d' ' -f1; }
version_of() { basename "$1" | cut -d_ -f1; }

applied_versions() {
  "${PSQL[@]}" -At -c "SELECT version FROM helios_meta.schema_migrations ORDER BY version"
}

verify_checksums() {
  local drift=0
  while IFS='|' read -r version stored; do
    local file
    file=$(find "${MIGRATIONS_DIR}" -maxdepth 1 -name "${version}_*.sql" ! -name '*.down.sql' | head -1)
    [[ -z "${file}" ]] && { printf '  missing file for applied version %s\n' "${version}" >&2; drift=1; continue; }
    local actual; actual=$(checksum "${file}")
    if [[ "${actual}" != "${stored}" ]]; then
      printf '  checksum drift: %s (migrations are immutable — add a new one)\n' "$(basename "${file}")" >&2
      drift=1
    fi
  done < <("${PSQL[@]}" -At -F'|' -c "SELECT version, checksum FROM helios_meta.schema_migrations")
  [[ "${drift}" -eq 0 ]] || fail "refusing to continue with schema drift"
}

cmd_up() {
  local limit="${1:-0}" count=0
  local -a already
  mapfile -t already < <(applied_versions)
  for file in "${MIGRATIONS_DIR}"/*.sql; do
    [[ "${file}" == *.down.sql ]] && continue
    local version; version=$(version_of "${file}")
    local name; name=$(basename "${file}" .sql)
    if printf '%s\n' "${already[@]:-}" | grep -qx "${version}"; then continue; fi
    [[ "${limit}" -gt 0 && "${count}" -ge "${limit}" ]] && break

    log "applying ${name}"
    local start; start=$(date +%s%3N)
    local sum; sum=$(checksum "${file}")
    {
      echo 'BEGIN;'
      cat "${file}"
      printf "\nINSERT INTO helios_meta.schema_migrations(version,name,checksum,duration_ms) VALUES ('%s','%s','%s', (extract(epoch from clock_timestamp())*1000)::int - %s);\n" \
        "${version}" "${name}" "${sum}" "${start}"
      echo 'COMMIT;'
    } | "${PSQL[@]}" -f - || fail "migration ${name} failed"
    ok "${name} ($(( $(date +%s%3N) - start ))ms)"
    count=$((count + 1))
  done
  [[ "${count}" -eq 0 ]] && ok "database already up to date" || ok "applied ${count} migration(s)"
}

cmd_down() {
  local n="${1:-1}"
  for _ in $(seq 1 "${n}"); do
    local version; version=$("${PSQL[@]}" -At -c \
      "SELECT version FROM helios_meta.schema_migrations ORDER BY version DESC LIMIT 1")
    [[ -z "${version}" ]] && { ok "nothing to roll back"; return; }
    local down; down=$(find "${MIGRATIONS_DIR}" -maxdepth 1 -name "${version}_*.down.sql" | head -1)
    [[ -z "${down}" ]] && fail "no down migration for ${version} (irreversible by design)"
    log "reverting $(basename "${down}")"
    {
      echo 'BEGIN;'
      cat "${down}"
      printf "\nDELETE FROM helios_meta.schema_migrations WHERE version = '%s';\n" "${version}"
      echo 'COMMIT;'
    } | "${PSQL[@]}" -f - || fail "rollback of ${version} failed"
    ok "reverted ${version}"
  done
}

cmd_status() {
  "${PSQL[@]}" -c "SELECT version, name, applied_at, duration_ms FROM helios_meta.schema_migrations ORDER BY version"
  log "pending:"
  local -a already; mapfile -t already < <(applied_versions)
  local pending=0
  for file in "${MIGRATIONS_DIR}"/*.sql; do
    [[ "${file}" == *.down.sql ]] && continue
    local version; version=$(version_of "${file}")
    printf '%s\n' "${already[@]:-}" | grep -qx "${version}" || { echo "  $(basename "${file}")"; pending=1; }
  done
  [[ "${pending}" -eq 0 ]] && echo "  (none)"
}

ensure_ledger
case "${1:-up}" in
  up)     verify_checksums; cmd_up "${2:-0}" ;;
  down)   cmd_down "${2:-1}" ;;
  status) cmd_status ;;
  verify) verify_checksums; ok "checksums match" ;;
  *)      fail "usage: $0 {up [n]|down [n]|status|verify}" ;;
esac
