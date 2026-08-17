#!/usr/bin/env bash
# Restore the internal Airbyte Postgres from a scripts/backup.sh dump.
#
# This is destructive: the current contents of the internal Postgres server are
# replaced by the backup.
#
# Sequence, and why each step is needed:
#   1. Scale every Airbyte deployment to 0. Airbyte holds pooled connections
#      open, and PostgreSQL refuses to DROP a database that has any session
#      attached -- so a restore against a live install fails partway and leaves
#      a half-restored database.
#   2. Terminate any leftover backends.
#   3. Replay the dump through psql connected to `template1`. Not `postgres`:
#      pg_dumpall --clean emits DROP DATABASE IF EXISTS postgres, which cannot
#      run from a session connected to that same database.
#   4. Scale back up. The bootloader does not re-run on scale-up, so the
#      restored schema is used as-is.
#
# Usage: scripts/restore.sh --file <backup.sql.gz> [--yes]
#        scripts/restore.sh --latest [--yes]

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

FILE=""
USE_LATEST=0
while (( $# )); do
  case "$1" in
    --file)   FILE="${2:?--file needs a path}"; shift 2 ;;
    --latest) USE_LATEST=1; shift ;;
    --yes|-y) export ASSUME_YES=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

if (( USE_LATEST )); then
  [[ -z "$FILE" ]] || die "pass either --file or --latest, not both"
  FILE="$(ls -1t "${BACKUP_DIR}"/airbyte-pg-*.sql.gz 2>/dev/null | head -1 || true)"
  [[ -n "$FILE" ]] || die "no backups found in ${BACKUP_DIR}"
fi

[[ -n "$FILE" ]] || die "specify a backup: --file <path> or --latest"

# Allow a path relative to the repo root for convenience.
if [[ ! -f "$FILE" && -f "${REPO_ROOT}/${FILE}" ]]; then
  FILE="${REPO_ROOT}/${FILE}"
fi
[[ -f "$FILE" ]] || die "backup file not found: $FILE"

# --- Validate the archive before touching anything --------------------------
log "Validating $(basename "$FILE")"
gzip -t "$FILE" 2>/dev/null || die "not a valid gzip file: $FILE"
is_pg_dumpall_archive "$FILE" || die "does not look like a pg_dumpall backup: $FILE"
ok "Archive is a valid pg_dumpall dump"

meta="${FILE%.sql.gz}.meta"
if [[ -f "$meta" ]]; then
  bchart="$(grep -E '^chart_version=' "$meta" | cut -d= -f2- || true)"
  dim "  taken $(grep -E '^created_utc=' "$meta" | cut -d= -f2- || echo '?') from chart ${bchart:-?}"
  if [[ -n "$bchart" && "$bchart" != "$CHART_VERSION" ]]; then
    warn "Backup was taken on chart $bchart but the current release is $CHART_VERSION."
    dim "  Restoring an older schema under a newer chart is usually fine (the"
    dim "  bootloader migrates forward on next start), but the reverse is not."
  fi
fi

require_release
pod="$(pg_pod_name)"

printf '\n'
warn "This REPLACES the internal Postgres contents of release '$RELEASE' (namespace '$NAMESPACE')."
dim "  All current connections, sources, destinations and sync history will be"
dim "  replaced by those in the backup."
confirm "Proceed with restore?" || die "aborted by user"

# --- 1. Scale down ----------------------------------------------------------
# Recorded so we can restore the exact previous replica counts, rather than
# assuming everything was at 1.
log "Scaling down Airbyte workloads"
scale_state="$(mktemp)"
SCALED_DOWN=0

# If we die between scaling down and scaling back up, say so loudly and leave
# the recorded replica counts on disk -- an install silently stuck at 0 replicas
# looks identical to a broken one.
cleanup() {
  local rc=$?
  if (( rc != 0 )) && (( SCALED_DOWN == 1 )); then
    printf '\n'
    warn "Restore aborted while workloads were scaled down -- Airbyte is currently STOPPED."
    warn "Bring it back with:  make scale-up"
    cp "$scale_state" "${REPO_ROOT}/.restore-scale-state" 2>/dev/null || true
    dim "  previous replica counts saved to .restore-scale-state"
  fi
  rm -f "$scale_state"
  exit $rc
}
trap cleanup EXIT

kcn get deployments -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.replicas}{"\n"}{end}' \
  > "$scale_state" 2>/dev/null || true
SCALED_DOWN=1

while read -r dep replicas; do
  [[ -n "$dep" ]] || continue
  dim "  $dep: $replicas -> 0"
  kcn scale deployment "$dep" --replicas=0 >/dev/null
done < "$scale_state"

log "Waiting for pods to terminate"
for _ in $(seq 1 60); do
  remaining="$(kcn get pods -o name 2>/dev/null | grep -v "$PG_POD" | wc -l | tr -d ' ')"
  [[ "$remaining" == "0" ]] && break
  sleep 2
done
[[ "${remaining:-0}" == "0" ]] && ok "Workloads stopped" \
  || warn "$remaining pod(s) still terminating; continuing (backends will be force-terminated)"

# --- 2. Terminate leftover backends ----------------------------------------
log "Terminating remaining database sessions"
pg_psql postgres -q -c "
  SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
  WHERE pid <> pg_backend_pid()
    AND datname IS NOT NULL;" >/dev/null 2>&1 || true
ok "Sessions cleared"

# --- 3. Replay the dump -----------------------------------------------------
log "Restoring (this can take a few minutes)"
restore_log="$(mktemp)"
set +e
gzip -dc "$FILE" | kcn exec -i "$pod" -c "$PG_CONTAINER" -- \
  env PGPASSWORD="$PG_PASSWORD" psql --no-psqlrc -U "$PG_USER" -d template1 \
  >"$restore_log" 2>&1
rc=$?
set -e

# ON_ERROR_STOP is deliberately NOT set, and a handful of errors are *expected*
# rather than merely tolerated. `pg_dumpall --clean` unconditionally emits:
#
#   DROP ROLE IF EXISTS airbyte;  CREATE ROLE airbyte;  ALTER ROLE airbyte ...
#   DROP DATABASE template1;      CREATE DATABASE template1 ...
#
# We connect as `airbyte` (so it cannot drop itself) to `template1` (so that
# cannot be dropped either -- which is what we want; template1 must survive).
# Those four statements therefore always fail, and always harmlessly: the
# subsequent ALTER ROLE still restores the role's attributes and password, and
# template1 was never meant to be replaced.
#
# So rather than reporting a raw error count -- which would cry wolf on every
# single successful restore -- classify them and only raise the alarm for
# errors that are NOT structurally expected.
benign_re='current user cannot be dropped'
benign_re+='|role ".*" already exists'
benign_re+='|cannot drop the currently open database'
benign_re+='|database ".*" already exists'
benign_re+='|cannot drop a template database'

all_errs="$(grep -c '^ERROR:' "$restore_log" 2>/dev/null || true)";  all_errs="${all_errs:-0}"
unexpected="$(grep '^ERROR:' "$restore_log" 2>/dev/null | grep -Evc "$benign_re" || true)"
unexpected="${unexpected:-0}"
benign=$(( all_errs - unexpected ))

if (( unexpected > 0 )); then
  warn "$unexpected unexpected error(s) during replay (plus $benign expected). First 20:"
  grep '^ERROR:' "$restore_log" 2>/dev/null | grep -Ev "$benign_re" | head -20 | sed 's/^/    /' >&2 || true
  dim "  Full log kept at: $restore_log"
  verify_strict=1
else
  if (( benign > 0 )); then
    ok "Dump replayed cleanly ($benign expected role/template1 errors, 0 unexpected)"
  else
    ok "Dump replayed with no errors"
  fi
  rm -f "$restore_log"
  verify_strict=0
fi
(( rc == 0 )) || warn "psql exited $rc"

# --- 4. Verify --------------------------------------------------------------
log "Verifying restored databases"
verify_failed="${verify_strict:-0}"

check_db() {
  local db="$1"
  if pg_psql postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$db'" 2>/dev/null | grep -q 1; then
    ok "  database '$db' present"
  else
    warn "  database '$db' MISSING"
    verify_failed=1
  fi
}

# Derive the expected database list from the dump rather than hardcoding it.
# A backup taken before Temporal ever started legitimately contains no
# temporal/temporal_visibility, and a hardcoded list would report that as a
# failed restore. This checks exactly what the dump claimed to carry.
expected="$(gzip -dc "$FILE" 2>/dev/null \
  | grep -E '^CREATE DATABASE ' \
  | sed -E 's/^CREATE DATABASE ([^ ]+).*/\1/' \
  | tr -d '"' | sort -u || true)"

if [[ -z "$expected" ]]; then
  warn "  could not read a database list from the dump; falling back to defaults"
  expected="$PG_DATABASE $TEMPORAL_DATABASES"
fi

for db in $expected; do
  [[ "$db" == "template0" || "$db" == "template1" ]] && continue
  check_db "$db"
done

# Row counts on the tables that hold the things a user actually cares about.
for tbl in workspace actor connection; do
  n="$(pg_psql "$PG_DATABASE" -tAc "SELECT count(*) FROM $tbl" 2>/dev/null | tr -d ' ' || echo '?')"
  printf '  %-14s %s\n' "$tbl rows:" "$n"
  [[ "$n" == "?" ]] && verify_failed=1
done

# --- 5. Scale back up -------------------------------------------------------
log "Scaling Airbyte workloads back up"
while read -r dep replicas; do
  [[ -n "$dep" ]] || continue
  [[ "$replicas" == "0" ]] && continue
  dim "  $dep: 0 -> $replicas"
  kcn scale deployment "$dep" --replicas="$replicas" >/dev/null
done < "$scale_state"
SCALED_DOWN=0
rm -f "${REPO_ROOT}/.restore-scale-state"

log "Waiting for pods to become ready (up to 5 minutes)"
kcn wait --for=condition=available --timeout=300s deployment --all >/dev/null 2>&1 \
  && ok "All deployments available" \
  || warn "Some deployments are not ready yet -- check: make status"

printf '\n'
if (( verify_failed )); then
  warn "Restore completed but verification found problems (see above)."
  exit 1
fi
ok "Restore complete. Airbyte is at http://localhost:${HOST_PORT}"
dim "  Note: the admin password now comes from the RESTORED database, so it is"
dim "  whatever it was when the backup was taken -- not necessarily .env."
