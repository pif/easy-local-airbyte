#!/usr/bin/env bash
# List available Postgres backups, newest first.
#
# Usage: scripts/list-backups.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

shopt -s nullglob
files=("${BACKUP_DIR}"/airbyte-pg-*.sql.gz)
shopt -u nullglob

if (( ${#files[@]} == 0 )); then
  warn "No backups in ${BACKUP_DIR#"$REPO_ROOT"/}"
  dim "  create one with: make backup"
  exit 0
fi

printf '%-44s %8s  %-9s %s\n' "BACKUP" "SIZE" "CHART" "LABEL"
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  meta="${f%.sql.gz}.meta"
  chart=""; label=""
  if [[ -f "$meta" ]]; then
    chart="$(grep -E '^chart_version=' "$meta" | cut -d= -f2- || true)"
    label="$(grep -E '^label=' "$meta" | cut -d= -f2- || true)"
  fi
  printf '%-44s %8s  %-9s %s\n' \
    "$(basename "$f")" \
    "$(du -h "$f" | cut -f1 | tr -d ' ')" \
    "${chart:--}" \
    "${label:--}"
done < <(ls -1t "${BACKUP_DIR}"/airbyte-pg-*.sql.gz 2>/dev/null)

printf '\n'
dim "restore newest:  make restore-latest"
dim "restore a file:  make restore FILE=backups/<name>.sql.gz"
