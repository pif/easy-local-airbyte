#!/usr/bin/env bash
# Tear down the local environment.
#
#   scripts/down.sh                 delete the kind cluster (keeps the VM, keeps backups)
#   scripts/down.sh --all           also stop the dedicated colima VM
#   scripts/down.sh --release-only  uninstall the Helm release, keep the cluster
#
# Backups in backups/ are never touched.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MODE=cluster
while (( $# )); do
  case "$1" in
    --all)          MODE=all; shift ;;
    --release-only) MODE=release; shift ;;
    --yes|-y)       export ASSUME_YES=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [[ "$MODE" == "release" ]]; then
  require_cluster
  warn "This deletes the Airbyte Helm release in namespace '$NAMESPACE'."
  dim "  The internal Postgres StatefulSet and its PVC are created as Helm"
  dim "  pre-install hooks, so 'helm uninstall' leaves them behind and your data"
  dim "  survives. Deleting the namespace or the cluster does destroy them."
  confirm "Uninstall release '$RELEASE'?" || die "aborted by user"
  helm_ uninstall "$RELEASE" -n "$NAMESPACE" --wait --timeout "$HELM_TIMEOUT" || true
  ok "Release uninstalled (Postgres PVC retained)"
  exit 0
fi

if cluster_exists; then
  warn "This DELETES the kind cluster '$CLUSTER_NAME', including the internal Postgres data."
  if [[ -d "$BACKUP_DIR" ]] && ls "${BACKUP_DIR}"/airbyte-pg-*.sql.gz >/dev/null 2>&1; then
    dim "  Backups in backups/ are kept and can be restored into a fresh cluster."
  else
    warn "  You have NO backups. Run 'make backup' first if you want to keep your config."
  fi
  confirm "Delete cluster '$CLUSTER_NAME'?" || die "aborted by user"
  log "Deleting kind cluster '$CLUSTER_NAME'"
  kind delete cluster --name "$CLUSTER_NAME"
  ok "Cluster deleted"
else
  ok "Cluster '$CLUSTER_NAME' does not exist"
fi

if [[ "$MODE" == "all" ]]; then
  if command -v colima >/dev/null 2>&1 && colima status --profile "$COLIMA_PROFILE" >/dev/null 2>&1; then
    log "Stopping colima profile '$COLIMA_PROFILE'"
    colima stop --profile "$COLIMA_PROFILE"
    ok "colima profile stopped (not deleted; 'colima delete -p $COLIMA_PROFILE' removes it)"
  else
    ok "colima profile '$COLIMA_PROFILE' is not running"
  fi
fi
