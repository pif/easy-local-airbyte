#!/usr/bin/env bash
# Show cluster / release / pod health and the effective low-resource settings.
#
# Usage: scripts/status.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

if ! cluster_exists; then
  warn "kind cluster '$CLUSTER_NAME' does not exist. Run: make up"
  exit 1
fi
if ! context_reachable; then
  warn "cluster '$CLUSTER_NAME' exists but is unreachable. Is the Docker VM running?"
  exit 1
fi
ok "Cluster '$CLUSTER_NAME' reachable (context $KUBE_CONTEXT)"

if ! release_exists; then
  warn "Helm release '$RELEASE' not installed. Run: make install"
  exit 1
fi

rev="$(helm_ list -n "$NAMESPACE" -f "^${RELEASE}\$" -o json 2>/dev/null \
  | grep -o '"revision":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
ok "Release '$RELEASE' installed (revision ${rev:-?}, chart $CHART_VERSION)"

printf '\n%sPods%s\n' "$C_BLUE" "$C_RESET"
kcn get pods -o wide 2>/dev/null || true

# Surface the two failure modes that actually bite locally.
printf '\n'
pending="$(kcn get pods --field-selector=status.phase=Pending -o name 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$pending" != "0" ]]; then
  warn "$pending pod(s) Pending -- usually not enough CPU/RAM on the node."
  dim "  Check why:  kubectl --context $KUBE_CONTEXT -n $NAMESPACE describe pod <name> | tail -20"
  dim "  Consider:   LOW_RESOURCE_MODE=true in .env, or raise VM_CPUS / VM_MEMORY_GIB"
fi

# Count only pods that are still meant to be running. The bootloader is a
# run-once pod that legitimately sits in Completed with ready=false forever, so
# counting raw ready=false reports "1 container not ready" on a healthy install.
# Splits the READY column ("1/1") and compares the halves. Deliberately not a
# regex backreference -- POSIX awk has no \1, so /^([0-9]+)\/\1$/ silently
# matches nothing and every pod gets counted as not-ready.
notready="$(kcn get pods --no-headers 2>/dev/null \
  | awk '$3 != "Completed" { split($2, a, "/"); if (a[1] != a[2]) c++ } END { print c+0 }')"
[[ "${notready:-0}" == "0" ]] || dim "  ($notready pod(s) not yet fully ready)"

# --- Effective low-resource configuration -----------------------------------
printf '\n%sLow-resource settings (as deployed)%s\n' "$C_BLUE" "$C_RESET"
if [[ "$LOW_RESOURCE_MODE" == "true" ]]; then
  dim "  LOW_RESOURCE_MODE=true"
else
  dim "  LOW_RESOURCE_MODE=false"
fi

server_deploy="$(deploy_name server)"
variant=""
if [[ -n "$server_deploy" ]]; then
  variant="$(kcn get deploy "$server_deploy" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="JOB_RESOURCE_VARIANT_OVERRIDE")].value}' 2>/dev/null || true)"
fi
printf '  %-42s %s\n' "JOB_RESOURCE_VARIANT_OVERRIDE" "${variant:-<unset>}"

cm="${RELEASE}-airbyte-env"
for k in JOB_MAIN_CONTAINER_CPU_REQUEST JOB_MAIN_CONTAINER_MEMORY_REQUEST \
         CHECK_JOB_MAIN_CONTAINER_CPU_REQUEST DISCOVER_JOB_MAIN_CONTAINER_CPU_REQUEST \
         REPLICATION_ORCHESTRATOR_CPU_REQUEST SIDECAR_MAIN_CONTAINER_CPU_REQUEST \
         JOB_MAIN_CONTAINER_CPU_LIMIT JOB_MAIN_CONTAINER_MEMORY_LIMIT; do
  v="$(kcn get configmap "$cm" -o jsonpath="{.data.${k}}" 2>/dev/null || true)"
  printf '  %-42s %s\n' "$k" "${v:-<unset>}"
done

mfs="$(deploy_name manifest-server)"
printf '  %-42s %s\n' "manifest-server (connector builder)" \
  "$( [[ -n "$mfs" ]] && echo enabled || echo disabled )"

printf '\n%sEndpoint%s\n' "$C_BLUE" "$C_RESET"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${HOST_PORT}/" 2>/dev/null || echo 000)"
if [[ "$code" =~ ^(200|302|401)$ ]]; then
  ok "http://localhost:${HOST_PORT} responding (HTTP $code)"
else
  warn "http://localhost:${HOST_PORT} not responding yet (HTTP $code)"
fi
