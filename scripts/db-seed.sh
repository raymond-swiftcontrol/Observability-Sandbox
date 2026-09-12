#!/usr/bin/env bash
# Load reference data then demo data. Idempotent: every seed file uses
# ON CONFLICT DO NOTHING / DO UPDATE so re-running is safe.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "${ROOT}/.env" ]] && set -a && source "${ROOT}/.env" && set +a
DATABASE_URL="${DATABASE_URL:-postgresql://helios:helios_dev_only@localhost:5432/helios?sslmode=disable}"

for f in "${ROOT}"/db/seeds/*.sql; do
  printf '\033[36m▸\033[0m seeding %s\n' "$(basename "$f")"
  psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -q --no-psqlrc -f "$f"
done

# Synthetic price history is generated rather than stored as SQL: 8k instruments
# × 2y of daily bars would be a ~400MB fixture.
if [[ "${SKIP_BARS:-0}" != "1" ]]; then
  printf '\033[36m▸\033[0m generating demo bar history (set SKIP_BARS=1 to skip)\n'
  python3 "${ROOT}/scripts/seed_bars.py" --years 2 --universe sp500 --interval 1d
fi
printf '\033[32m✓\033[0m seed complete\n'
