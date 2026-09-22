#!/usr/bin/env bash
# Shared configuration and helpers for all easy-local-airbyte scripts.
# Sourced, not executed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# ---------------------------------------------------------------------------
# Configuration. Every value can be overridden in .env or the environment.
# ---------------------------------------------------------------------------
if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

: "${CLUSTER_NAME:=easy-local-airbyte}"
: "${KUBE_CONTEXT:=kind-${CLUSTER_NAME}}"
: "${NAMESPACE:=airbyte}"
: "${RELEASE:=airbyte}"

# Chart 2.x is the "v2" chart line from https://airbytehq.github.io/charts.
: "${CHART_VERSION:=2.2.0}"
: "${CHART_REPO_NAME:=airbyte-v2}"
: "${CHART_REPO_URL:=https://airbytehq.github.io/charts}"
: "${CHART_REF:=${CHART_REPO_NAME}/airbyte}"

# Host port that http://localhost:<port> maps to (kind extraPortMapping -> ingress :80).
: "${HOST_PORT:=8000}"

# Replicates abctl's `--low-resource-mode`. See config/values/low-resource.yaml.
: "${LOW_RESOURCE_MODE:=true}"

# In low-resource mode abctl also disables the connector-builder service.
# On chart 2.x that service is `manifestServer`. Set to false to keep the
# Connector Builder UI working at the cost of ~1 extra pod.
: "${DISABLE_CONNECTOR_BUILDER:=true}"

# Bundled (internal) Postgres, as templated by the chart's airbyte-db.yaml.
: "${PG_STATEFULSET:=airbyte-db}"
: "${PG_POD:=airbyte-db-0}"
: "${PG_CONTAINER:=airbyte-db-container}"
: "${PG_USER:=airbyte}"
: "${PG_PASSWORD:=airbyte}"
: "${PG_DATABASE:=db-airbyte}"
# Postgres PVC size for the bundled database. Install-time only: to grow an
# existing install, edit the PVC directly.
: "${PG_VOLUME_SIZE:=10Gi}"

# Databases Temporal auto-creates inside the same Postgres server. They are
# part of a complete backup, which is why backups use pg_dumpall.
: "${TEMPORAL_DATABASES:=temporal temporal_visibility}"

: "${BACKUP_DIR:=${REPO_ROOT}/backups}"
: "${HELM_TIMEOUT:=30m}"

# Docker/VM backing kind. On macOS we default to a dedicated colima profile so
# we never resize or clobber the user's existing Docker setup.
: "${DOCKER_PROVIDER:=auto}"     # auto | colima | existing
: "${COLIMA_PROFILE:=airbyte}"
: "${VM_CPUS:=6}"
: "${VM_MEMORY_GIB:=12}"
: "${VM_DISK_GIB:=60}"

: "${KIND_NODE_IMAGE:=kindest/node:v1.33.1}"
: "${INGRESS_NGINX_CHART_VERSION:=4.11.3}"

# Admin password for the initial Airbyte user. Generated into .env on first
# install so it stays stable across upgrades.
: "${AIRBYTE_ADMIN_PASSWORD:=}"

export CLUSTER_NAME KUBE_CONTEXT NAMESPACE RELEASE CHART_VERSION HOST_PORT

# ---------------------------------------------------------------------------
# Docker context resolution
# ---------------------------------------------------------------------------
# Both `docker` and `kind` honour DOCKER_CONTEXT, so pointing every script at
# the dedicated colima profile here means none of them touch the user's default
# Docker setup. Done with a cheap socket-path check rather than shelling out to
# colima, so sourcing this file stays fast. A DOCKER_CONTEXT or DOCKER_HOST
# already set in the environment always wins.
if [[ -z "${DOCKER_CONTEXT:-}" && -z "${DOCKER_HOST:-}" && "$DOCKER_PROVIDER" != "existing" ]]; then
  if [[ -S "${HOME}/.colima/${COLIMA_PROFILE}/docker.sock" ]]; then
    export DOCKER_CONTEXT="colima-${COLIMA_PROFILE}"
  fi
fi

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'
else
  C_RESET=''; C_BLUE=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_DIM=''
fi

log()   { printf '%s==>%s %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
ok()    { printf '%s ok %s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf '%swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%sfail%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }
dim()   { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed.${2:+ $2}"
}

# Generate a random alphanumeric password.
#
# The `|| true` is load-bearing. `head -c` closes the pipe as soon as it has
# enough bytes, which kills the upstream `tr` with SIGPIPE (exit 141). Under
# `set -o pipefail` that makes the whole pipeline fail, and because this runs in
# a command substitution feeding an assignment, `set -e` would abort the script
# right here -- having generated a perfectly good password.
gen_password() {
  local pw
  pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24 || true)"
  if (( ${#pw} < 24 )); then
    pw="$(openssl rand -hex 12 2>/dev/null || true)"
  fi
  (( ${#pw} >= 16 )) || die "unable to generate a random password"
  printf '%s' "$pw"
}

# Test whether a gzipped file is a plausible pg_dumpall script.
#
# Reads the header into a variable first rather than piping into `grep -q`.
# `grep -q` exits on first match and `head` exits once satisfied, both of which
# SIGPIPE the upstream `gzip`; with pipefail the pipeline then reports failure
# even though the pattern DID match, inverting the check.
is_pg_dumpall_archive() {
  local file="$1" header
  gzip -t "$file" 2>/dev/null || return 1
  header="$(gzip -dc "$file" 2>/dev/null | head -100 || true)"
  case "$header" in
    *"PostgreSQL database cluster dump"*) return 0 ;;
    *) return 1 ;;
  esac
}

confirm() {
  # confirm <prompt>  -- auto-yes when ASSUME_YES=1 or stdin is not a TTY.
  local prompt="$1" reply
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    dim "  (--yes) $prompt -> yes"
    return 0
  fi
  [[ -t 0 ]] || die "$prompt (refusing to assume yes; pass --yes or set ASSUME_YES=1)"
  read -r -p "$(printf '%s ?? %s %s [y/N] ' "$C_YELLOW" "$C_RESET" "$prompt")" reply
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ---------------------------------------------------------------------------
# kubectl / helm wrappers pinned to our context and namespace
# ---------------------------------------------------------------------------
kc()   { kubectl --context "$KUBE_CONTEXT" "$@"; }
kcn()  { kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" "$@"; }
helm_() { helm --kube-context "$KUBE_CONTEXT" "$@"; }

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"
}

context_reachable() {
  kc version --request-timeout=10s >/dev/null 2>&1
}

release_exists() {
  helm_ status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1
}

require_cluster() {
  cluster_exists || die "kind cluster '$CLUSTER_NAME' does not exist. Run: make up"
  context_reachable || die "cannot reach cluster '$CLUSTER_NAME'. Is the Docker VM running? Try: make up"
}

require_release() {
  require_cluster
  release_exists || die "helm release '$RELEASE' not found in namespace '$NAMESPACE'. Run: make install"
}

# Resolve the Postgres pod. The chart hardcodes the StatefulSet as "airbyte-db"
# so the pod is normally airbyte-db-0; the label lookup is the fallback.
pg_pod_name() {
  if kcn get pod "$PG_POD" >/dev/null 2>&1; then
    printf '%s' "$PG_POD"
    return 0
  fi
  local found
  found="$(kcn get pods -l "app.kubernetes.io/name=airbyte-db" -o name 2>/dev/null | head -1 || true)"
  [[ -n "$found" ]] || die "could not find the internal Postgres pod ('$PG_POD') in namespace '$NAMESPACE'."
  printf '%s' "${found#pod/}"
}

sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256
  else sha256sum
  fi
}

# Fingerprint the runtime config that pods consume by reference.
#
# Most Airbyte settings reach the pods via configMapKeyRef/secretKeyRef against
# <release>-airbyte-env and <release>-airbyte-secrets. Kubernetes resolves those
# into the container environment ONCE, at pod start, and the chart puts no
# checksum annotation on its pod templates. So a values change that only alters
# the ConfigMap -- telemetry flags, most low-resource settings -- leaves the
# Deployment spec byte-identical, Helm reports "deployed" with nothing to roll,
# and the running pods keep serving the OLD configuration indefinitely.
#
# Comparing this fingerprint across a helm upgrade tells us whether a restart is
# actually required, so we neither miss a change nor restart for nothing.
config_fingerprint() {
  {
    kcn get configmap "${RELEASE}-airbyte-env" -o jsonpath='{.data}' 2>/dev/null || true
    kcn get configmap "${RELEASE}-airbyte-telemetry-env" -o jsonpath='{.data}' 2>/dev/null || true
    kcn get secret "${RELEASE}-airbyte-secrets" -o jsonpath='{.data}' 2>/dev/null || true
  } | sha256 | awk '{print $1}'
}

CONFIG_FP_ANNOTATION="easy-local-airbyte/config-fingerprint"

# Stamp the current config fingerprint onto every Airbyte pod template.
#
# This is the checksum-annotation pattern the chart is missing, implemented
# script-side. Patching a pod template with a *changed* fingerprint makes
# Kubernetes roll that deployment; patching it with the same fingerprint leaves
# the object byte-identical, so nothing restarts.
#
# Crucially this compares desired config against what the pods were actually
# stamped with -- not against the previous ConfigMap. That makes it converge
# from any starting state, including an upgrade that updated the ConfigMap but
# died before restarting anything.
#
# Returns 0 always; prints what it rolled. Sets CONFIG_ROLLED to the count.
sync_config_to_workloads() {
  local fp deps d cur gen_before gen_after
  CONFIG_ROLLED=0
  fp="$(config_fingerprint)"
  deps="$(kcn get deployments -o name 2>/dev/null || true)"
  [[ -n "$deps" ]] || return 0

  for d in $deps; do
    cur="$(kcn get "$d" -o jsonpath="{.spec.template.metadata.annotations['${CONFIG_FP_ANNOTATION}']}" 2>/dev/null || true)"
    [[ "$cur" == "$fp" ]] && continue

    gen_before="$(kcn get "$d" -o jsonpath='{.metadata.generation}' 2>/dev/null || echo 0)"
    kcn patch "$d" --type=merge \
      -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"${CONFIG_FP_ANNOTATION}\":\"${fp}\"}}}}}" \
      >/dev/null
    gen_after="$(kcn get "$d" -o jsonpath='{.metadata.generation}' 2>/dev/null || echo 0)"

    if [[ "$gen_before" != "$gen_after" ]]; then
      CONFIG_ROLLED=$(( CONFIG_ROLLED + 1 ))
      dim "  rolling ${d#deployment.apps/}"
    fi
  done

  (( CONFIG_ROLLED > 0 )) || return 0

  for d in $deps; do
    kcn rollout status "$d" --timeout=300s >/dev/null 2>&1 \
      || warn "  ${d#deployment.apps/} did not become ready within 5m"
  done
}

# Resolve a component's Deployment name by label rather than by guessing it.
# Necessary because the chart's fullname helper collapses the release prefix
# when the release is called "airbyte" (giving "airbyte-server"), but not
# otherwise (giving e.g. "easy-local-airbyte-server") -- so no single string pattern
# works for every RELEASE value.
# Usage: deploy_name server   ->  prints the Deployment name, or nothing.
deploy_name() {
  local component="$1" found
  found="$(kcn get deploy -l "airbyte=${component}" -o name 2>/dev/null | head -1 || true)"
  printf '%s' "${found#deployment.apps/}"
}

# Run psql inside the Postgres pod. Args after the db name are passed to psql.
# Usage: pg_psql <dbname> [psql args...]   (SQL on stdin, or use -c)
pg_psql() {
  local db="$1"; shift
  local pod; pod="$(pg_pod_name)"
  kcn exec -i "$pod" -c "$PG_CONTAINER" -- \
    env PGPASSWORD="$PG_PASSWORD" psql -v ON_ERROR_STOP=1 --no-psqlrc \
      -U "$PG_USER" -d "$db" "$@"
}

# Write a key=value into .env, replacing any existing entry.
env_set() {
  local key="$1" value="$2" file="${REPO_ROOT}/.env"
  touch "$file"
  if grep -qE "^${key}=" "$file"; then
    # Portable in-place edit (BSD and GNU sed differ on -i).
    # `|| true`: grep -v exits 1 when it emits no lines, which happens when the
    # key is the only line in the file.
    local tmp; tmp="$(mktemp)"
    grep -vE "^${key}=" "$file" >"$tmp" || true
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
    mv "$tmp" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
  chmod 600 "$file"
}

# Airbyte workload deployments, i.e. everything that talks to Postgres.
# Deliberately excludes the airbyte-db StatefulSet itself.
airbyte_scalable_workloads() {
  kcn get deployments -o name 2>/dev/null || true
}
