#!/usr/bin/env bash
# Create the kind cluster and install the ingress controller.
# Idempotent: safe to re-run against an existing cluster.
#
# Usage: scripts/up.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

"${REPO_ROOT}/scripts/preflight.sh"

# preflight may have just started the VM, so re-resolve the docker context.
if [[ -z "${DOCKER_HOST:-}" && "$DOCKER_PROVIDER" != "existing" \
      && -S "${HOME}/.colima/${COLIMA_PROFILE}/docker.sock" ]]; then
  export DOCKER_CONTEXT="colima-${COLIMA_PROFILE}"
fi

# --- kind cluster -----------------------------------------------------------
if cluster_exists; then
  ok "kind cluster '$CLUSTER_NAME' already exists"
else
  log "Creating kind cluster '$CLUSTER_NAME' (localhost:${HOST_PORT} -> ingress :80)"
  rendered="$(mktemp)"
  trap 'rm -f "$rendered"' EXIT
  # sed rather than envsubst: envsubst ships with gettext and is not present on
  # a stock macOS.
  sed -e "s|\${CLUSTER_NAME}|${CLUSTER_NAME}|g" \
      -e "s|\${KIND_NODE_IMAGE}|${KIND_NODE_IMAGE}|g" \
      -e "s|\${HOST_PORT}|${HOST_PORT}|g" \
      "${REPO_ROOT}/config/kind-cluster.yaml" > "$rendered"
  kind create cluster --config "$rendered" --wait 5m
  ok "kind cluster created"
fi

context_reachable || die "cluster created but context '$KUBE_CONTEXT' is not reachable."

# --- ingress-nginx ----------------------------------------------------------
# Always run upgrade --install rather than skipping when the release exists: a
# release left in a "failed" state still reports a status, so a mere existence
# check would skip over a broken controller forever.
status="$(helm_ list -n ingress-nginx -f '^ingress-nginx$' -o json 2>/dev/null \
  | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
if [[ "$status" == "deployed" ]]; then
  ok "ingress-nginx already deployed"
else
  [[ -z "$status" ]] && log "Installing ingress-nginx" \
                     || log "ingress-nginx is in state '$status' -- reinstalling"
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
  helm repo update ingress-nginx >/dev/null
  # hostPort publishes the controller on the node's :80, which kind maps to
  # localhost:${HOST_PORT}. The nodeSelector matches the ingress-ready label
  # set in the kind config.
  helm_ upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx --create-namespace \
    --version "$INGRESS_NGINX_CHART_VERSION" \
    --set controller.hostPort.enabled=true \
    --set controller.service.type=NodePort \
    --set-string controller.nodeSelector.ingress-ready=true \
    --set-string controller.tolerations[0].key=node-role.kubernetes.io/control-plane \
    --set controller.tolerations[0].operator=Exists \
    --set controller.tolerations[0].effect=NoSchedule \
    --set controller.watchIngressWithoutClass=true \
    --set controller.admissionWebhooks.enabled=false \
    --wait --timeout 5m
  ok "ingress-nginx installed"
fi

log "Cluster ready"
dim "  context: $KUBE_CONTEXT"
dim "  next:    make install"
