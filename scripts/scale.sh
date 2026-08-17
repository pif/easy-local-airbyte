#!/usr/bin/env bash
# Stop or start Airbyte without destroying anything. Useful for reclaiming
# laptop resources, and to recover from an aborted restore.
#
#   scripts/scale.sh down   scale all Airbyte deployments to 0 (Postgres stays up)
#   scripts/scale.sh up     restore previous replica counts (or 1 if unknown)

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

action="${1:-}"
[[ "$action" == "up" || "$action" == "down" ]] || die "usage: scripts/scale.sh up|down"

require_release

state_file="${REPO_ROOT}/.restore-scale-state"

if [[ "$action" == "down" ]]; then
  log "Scaling Airbyte deployments to 0"
  kcn get deployments -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.replicas}{"\n"}{end}' \
    > "$state_file" 2>/dev/null || true
  while read -r dep replicas; do
    [[ -n "$dep" ]] || continue
    dim "  $dep: $replicas -> 0"
    kcn scale deployment "$dep" --replicas=0 >/dev/null
  done < "$state_file"
  ok "Airbyte stopped. Postgres is still running, so 'make backup' still works."
  dim "  restart with: make scale-up"
  exit 0
fi

log "Scaling Airbyte deployments up"
if [[ -f "$state_file" ]]; then
  while read -r dep replicas; do
    [[ -n "$dep" ]] || continue
    [[ "$replicas" == "0" ]] && replicas=1
    dim "  $dep -> $replicas"
    kcn scale deployment "$dep" --replicas="$replicas" >/dev/null
  done < "$state_file"
  rm -f "$state_file"
else
  warn "No saved replica counts; scaling every deployment to 1."
  while read -r dep; do
    [[ -n "$dep" ]] || continue
    kcn scale "$dep" --replicas=1 >/dev/null
  done < <(kcn get deployments -o name 2>/dev/null)
fi

log "Waiting for deployments to become available (up to 5 minutes)"
kcn wait --for=condition=available --timeout=300s deployment --all >/dev/null 2>&1 \
  && ok "Airbyte is back up at http://localhost:${HOST_PORT}" \
  || warn "Some deployments are not ready yet -- check: make status"
