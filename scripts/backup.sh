#!/usr/bin/env bash
# Back up the internal Airbyte Postgres.
#
# Uses pg_dumpall, not pg_dump, on purpose. The bundled Postgres server holds
# more than just db-airbyte: Temporal auto-creates `temporal` and
# `temporal_visibility` alongside it, and those carry in-flight workflow and
# sync-scheduling state. A pg_dump of db-airbyte alone silently loses them.
#
# Because global.secretsManager.enabled is false, connector credentials live in
# the config database too -- so this dump is a complete backup of your sources,
# destinations and connections. It does NOT include MinIO contents (sync logs
# and workload output); those are disposable artifacts, not configuration.
#
# The dump runs inside the Postgres pod so pg_dumpall always matches the server
# version exactly.
#
# Usage: scripts/backup.sh [--label <text>] [--keep <n>]

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

LABEL=""
KEEP=""
while (( $# )); do
  case "$1" in
    --label) LABEL="${2:?--label needs a value}"; shift 2 ;;
    --keep)  KEEP="${2:?--keep needs a value}";   shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -z "$KEEP" || "$KEEP" =~ ^[0-9]+$ ]] || die "--keep must be a number"

require_cluster
pod="$(pg_pod_name)"

phase="$(kcn get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
[[ "$phase" == "Running" ]] || die "Postgres pod '$pod' is not Running (phase: ${phase:-unknown})."

mkdir -p "$BACKUP_DIR"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
safe_label="$(printf '%s' "$LABEL" | tr -cs 'A-Za-z0-9._-' '-' | sed 's/^-*//; s/-*$//')"
name="airbyte-pg-${stamp}${safe_label:+-${safe_label}}"
outfile="${BACKUP_DIR}/${name}.sql.gz"
metafile="${BACKUP_DIR}/${name}.meta"
tmpfile="${outfile}.partial"

log "Backing up internal Postgres from pod '$pod'"
dim "  databases: $(pg_psql postgres -tAc \
  "select string_agg(datname, ', ' order by datname) from pg_database where not datistemplate" 2>/dev/null || echo '?')"

# --clean --if-exists makes the resulting script idempotent: it emits
# DROP ... IF EXISTS before each CREATE, so a restore does not require the
# target server to be empty and produces no "already exists" noise.
# Trailing pipeline is written to a .partial file and only renamed on success,
# so an interrupted run never leaves a truncated backup that looks valid.
set +e
kcn exec "$pod" -c "$PG_CONTAINER" -- \
  env PGPASSWORD="$PG_PASSWORD" pg_dumpall -U "$PG_USER" --clean --if-exists \
  2>"${tmpfile}.err" | gzip -c > "$tmpfile"
rc=${PIPESTATUS[0]}
set -e

if (( rc != 0 )); then
  warn "pg_dumpall failed (exit $rc):"
  sed 's/^/    /' "${tmpfile}.err" >&2 || true
  rm -f "$tmpfile" "${tmpfile}.err"
  die "backup aborted; no file written"
fi

# A valid gzip stream that decompresses to a plausible dump. Guards against the
# case where pg_dumpall exits 0 but produced nothing useful.
if ! is_pg_dumpall_archive "$tmpfile"; then
  rm -f "$tmpfile" "${tmpfile}.err"
  die "backup is not a valid gzipped pg_dumpall output; aborting (no file written)"
fi

rm -f "${tmpfile}.err"
mv "$tmpfile" "$outfile"

# Sidecar metadata so a restore can warn about mismatched chart versions.
{
  printf 'name=%s\n'          "$name"
  printf 'created_utc=%s\n'   "$stamp"
  printf 'label=%s\n'         "$LABEL"
  printf 'chart_version=%s\n' "$CHART_VERSION"
  printf 'release=%s\n'       "$RELEASE"
  printf 'namespace=%s\n'     "$NAMESPACE"
  printf 'pg_database=%s\n'   "$PG_DATABASE"
  printf 'server_version=%s\n' "$(pg_psql postgres -tAc 'show server_version' 2>/dev/null | tr -d ' ' || echo unknown)"
} > "$metafile"

size="$(du -h "$outfile" | cut -f1 | tr -d ' ')"
ok "Backup written: ${outfile#"$REPO_ROOT"/} ($size)"

# --- Retention --------------------------------------------------------------
if [[ -n "$KEEP" ]] && (( KEEP > 0 )); then
  # Avoids `mapfile`, which is bash 4+ and absent from the stock macOS bash 3.2.
  all=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && all+=("$line")
  done < <(ls -1t "${BACKUP_DIR}"/airbyte-pg-*.sql.gz 2>/dev/null || true)
  if (( ${#all[@]} > KEEP )); then
    log "Pruning old backups (keeping newest $KEEP of ${#all[@]})"
    for old in "${all[@]:$KEEP}"; do
      rm -f "$old" "${old%.sql.gz}.meta"
      dim "  removed $(basename "$old")"
    done
  fi
fi

dim "  restore with: make restore FILE=${outfile#"$REPO_ROOT"/}"
