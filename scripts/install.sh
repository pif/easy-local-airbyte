#!/usr/bin/env bash
# Install or upgrade the Airbyte Helm release. Idempotent -- this is also the
# upgrade path.
#
# Usage: scripts/install.sh [--dry-run]

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

require_cluster

# --- Admin password ---------------------------------------------------------
# Generated once and persisted to .env so it survives upgrades. Left to the
# chart's own random generation and it would churn on every helm upgrade.
if [[ -z "$AIRBYTE_ADMIN_PASSWORD" ]]; then
  AIRBYTE_ADMIN_PASSWORD="$(gen_password)"
  env_set AIRBYTE_ADMIN_PASSWORD "$AIRBYTE_ADMIN_PASSWORD"
  ok "Generated an admin password and saved it to .env"
fi

# --- Chart repo -------------------------------------------------------------
log "Updating Helm repo '$CHART_REPO_NAME'"
helm repo add "$CHART_REPO_NAME" "$CHART_REPO_URL" >/dev/null 2>&1 || true
helm repo update "$CHART_REPO_NAME" >/dev/null
ok "Chart $CHART_REF version $CHART_VERSION"

# --- Assemble values --------------------------------------------------------
args=(
  upgrade --install "$RELEASE" "$CHART_REF"
  --namespace "$NAMESPACE" --create-namespace
  --version "$CHART_VERSION"
  --values "${REPO_ROOT}/config/values/base.yaml"
)

if [[ "$LOW_RESOURCE_MODE" == "true" ]]; then
  args+=( --values "${REPO_ROOT}/config/values/low-resource.yaml" )
  log "Low-resource mode: ON (abctl --low-resource-mode equivalent)"
  if [[ "$DISABLE_CONNECTOR_BUILDER" != "true" ]]; then
    # Undo the low-resource file's manifestServer.enabled=false.
    args+=( --set manifestServer.enabled=true )
    dim "  keeping the Connector Builder (manifest server) enabled"
  fi
else
  log "Low-resource mode: OFF"
fi

# An optional, git-ignored file for local overrides that should not be
# committed (custom connector images, extra env vars, ...).
if [[ -f "${REPO_ROOT}/config/values/local.yaml" ]]; then
  args+=( --values "${REPO_ROOT}/config/values/local.yaml" )
  dim "  including config/values/local.yaml"
fi

# Release-name- and port-dependent values, which a static values file cannot
# express. WEBAPP_URL is only needed for chart versions before 2.0.0, which use
# it instead of global.airbyteUrl; harmless to set on newer ones.
args+=(
  --set-string "global.airbyteUrl=http://localhost:${HOST_PORT}"
  --set-string "server.env_vars.WEBAPP_URL=http://${RELEASE}-airbyte-server-svc"
  --set-string "global.auth.instanceAdmin.password=${AIRBYTE_ADMIN_PASSWORD}"
  --set-string "postgresql.storage.volumeClaimValue=${PG_VOLUME_SIZE}"
)

# Cookies must not be Secure-only: this is served over plain HTTP on localhost,
# and with cookieSecureSetting=true the browser drops the session cookie and
# login silently fails.
args+=( --set-string 'global.auth.security.cookieSecureSetting=false' )

if (( DRY_RUN )); then
  log "Rendering manifests (dry run) -- no changes will be applied"
  helm_ "${args[@]}" --dry-run
  exit 0
fi

args+=( --wait --timeout "$HELM_TIMEOUT" )

log "Installing/upgrading release '$RELEASE' in namespace '$NAMESPACE'"
dim "  First run pulls several GB of images and typically takes 10-20 minutes."
helm_ "${args[@]}"

ok "Helm release applied"

# Most Airbyte settings reach pods via configMapKeyRef, which Kubernetes resolves
# once at pod start, and the chart stamps no checksum on its pod templates. So a
# values change that only alters the ConfigMap (telemetry flags, most
# low-resource settings) leaves the Deployment spec identical: Helm reports
# "deployed" while the running pods keep serving the OLD config. This closes that
# gap, and is a no-op when nothing changed.
log "Reconciling runtime config with running pods"
sync_config_to_workloads
if (( ${CONFIG_ROLLED:-0} > 0 )); then
  ok "Rolled ${CONFIG_ROLLED} deployment(s) to pick up changed configuration"
else
  dim "  Pods already running the current configuration."
fi
"${REPO_ROOT}/scripts/status.sh" || true

printf '\n'
ok "Airbyte is available at http://localhost:${HOST_PORT}"
dim "  Credentials: make credentials"
