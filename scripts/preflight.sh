#!/usr/bin/env bash
# Verify required tooling exists and a Docker daemon with enough headroom is
# reachable. Starts the dedicated colima VM if that is the chosen provider.
#
# Usage: scripts/preflight.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

log "Checking required tools"
need kubectl "Install with: brew install kubectl"
need helm    "Install with: brew install helm"
need kind    "Install with: brew install kind"
need docker  "Install Docker Desktop, or: brew install docker colima"
ok "kubectl, helm, kind, docker present"

# --- Resolve which Docker daemon we use -------------------------------------
provider="$DOCKER_PROVIDER"
if [[ "$provider" == "auto" ]]; then
  if docker info >/dev/null 2>&1; then
    provider="existing"
  elif command -v colima >/dev/null 2>&1; then
    provider="colima"
  else
    die "no reachable Docker daemon, and colima is not installed. Start Docker Desktop or: brew install colima"
  fi
fi

if [[ "$provider" == "colima" ]]; then
  need colima "Install with: brew install colima"
  if colima status --profile "$COLIMA_PROFILE" >/dev/null 2>&1; then
    ok "colima profile '$COLIMA_PROFILE' already running"
  else
    log "Starting colima profile '$COLIMA_PROFILE' (${VM_CPUS} CPU / ${VM_MEMORY_GIB}GiB / ${VM_DISK_GIB}GiB disk)"
    dim "  A dedicated profile is used so your existing Docker setup is left untouched."
    colima start --profile "$COLIMA_PROFILE" \
      --cpu "$VM_CPUS" --memory "$VM_MEMORY_GIB" --disk "$VM_DISK_GIB" \
      --runtime docker
    ok "colima profile '$COLIMA_PROFILE' started"
  fi
  # kind and docker both honour DOCKER_CONTEXT. common.sh picks this up on its
  # own for subsequent scripts once the profile's socket exists; set it here too
  # so the checks below in *this* process use the right daemon.
  export DOCKER_CONTEXT="colima-${COLIMA_PROFILE}"
  dim "  DOCKER_CONTEXT=$DOCKER_CONTEXT"
fi

docker info >/dev/null 2>&1 || die "Docker daemon is not reachable."

# --- Check headroom ---------------------------------------------------------
cpus="$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)"
mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
mem_gib=$(( mem_bytes / 1073741824 ))

log "Docker daemon: ${cpus} CPU / ${mem_gib}GiB RAM available"

min_cpus=4
min_mem=8
if [[ "$LOW_RESOURCE_MODE" != "true" ]]; then
  min_cpus=6; min_mem=16
fi

hint=""
[[ "$LOW_RESOURCE_MODE" == "true" ]] || hint=" (or set LOW_RESOURCE_MODE=true in .env)"

(( cpus >= min_cpus ))   || warn "Docker has ${cpus} CPU; ${min_cpus}+ recommended${hint}."
(( mem_gib >= min_mem )) || warn "Docker has ${mem_gib}GiB RAM; ${min_mem}GiB+ recommended${hint}."

if (( cpus >= min_cpus && mem_gib >= min_mem )); then
  ok "Resource headroom looks sufficient"
fi

# --- Check the host port is free --------------------------------------------
if ! cluster_exists; then
  if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$HOST_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    die "port $HOST_PORT is already in use. Set HOST_PORT in .env to something else."
  fi
  ok "Host port $HOST_PORT is free"
fi

ok "Preflight passed"
