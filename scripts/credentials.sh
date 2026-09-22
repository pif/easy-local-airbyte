#!/usr/bin/env bash
# Print the login credentials and API client credentials for this install.
#
# Usage: scripts/credentials.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_release

# The chart writes generated credentials into this secret (it is
# global.auth.managedSecretName, default "airbyte-auth-secrets").
secret="${AIRBYTE_AUTH_SECRET:-airbyte-auth-secrets}"

get_key() {
  kcn get secret "$secret" -o jsonpath="{.data.$1}" 2>/dev/null \
    | { base64 --decode 2>/dev/null || base64 -D 2>/dev/null; } || true
}

printf '%sAirbyte%s  http://localhost:%s\n\n' "$C_BLUE" "$C_RESET" "$HOST_PORT"

# Community edition uses "simple" auth mode: the login pair is the email that was
# entered on the setup screen plus the generated instance-admin password. There
# is no default or built-in username -- the email only exists once setup has been
# completed, so read it back from the database rather than guessing.
pw="$(get_key instance-admin-password)"
email="${AIRBYTE_ADMIN_EMAIL:-}"
if [[ -z "$email" ]]; then
  email="$(pg_psql "$PG_DATABASE" -tAc \
    'SELECT email FROM "user" WHERE email <> '"''"' ORDER BY created_at LIMIT 1' 2>/dev/null \
    | tr -d '[:space:]' || true)"
fi

printf '  %-16s %s\n' "email:" "${email:-<not set yet -- complete the setup screen first>}"
printf '  %-16s %s\n' "password:" "${pw:-${AIRBYTE_ADMIN_PASSWORD:-<unavailable>}}"

cid="$(get_key instance-admin-client-id)"
csec="$(get_key instance-admin-client-secret)"
if [[ -n "$cid" ]]; then
  printf '\n%sAPI (client credentials)%s\n\n' "$C_BLUE" "$C_RESET"
  printf '  %-16s %s\n' "client-id:" "$cid"
  printf '  %-16s %s\n' "client-secret:" "$csec"
fi

if [[ -n "$pw" && -n "${AIRBYTE_ADMIN_PASSWORD:-}" && "$pw" != "$AIRBYTE_ADMIN_PASSWORD" ]]; then
  printf '\n'
  warn "The in-cluster password differs from AIRBYTE_ADMIN_PASSWORD in .env."
  dim "  The value above (from the cluster) is the one that works. This is normal"
  dim "  after restoring a backup taken with a different password."
fi
