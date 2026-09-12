#!/usr/bin/env bash
# Block until every container in the compose project reports healthy.
set -Eeuo pipefail
TIMEOUT="${TIMEOUT:-180}"
deadline=$(( $(date +%s) + TIMEOUT ))

while :; do
  unhealthy=$(docker ps --filter 'label=com.docker.compose.project=helios' \
      --format '{{.Names}}\t{{.Status}}' | grep -Ev 'healthy|Exited \(0\)' || true)
  [[ -z "${unhealthy}" ]] && { printf '\033[32m✓\033[0m stack healthy\n'; exit 0; }
  if (( $(date +%s) > deadline )); then
    printf '\033[31m✗\033[0m timed out after %ss; still not healthy:\n%s\n' "${TIMEOUT}" "${unhealthy}" >&2
    exit 1
  fi
  printf '\r  waiting… %s' "$(echo "${unhealthy}" | wc -l) container(s)"
  sleep 3
done
