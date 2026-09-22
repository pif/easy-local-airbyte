# easy-local-airbyte

Automated local [Airbyte](https://airbyte.com) (open source) on Kubernetes, with
scripted backup and restore of its internal Postgres.

Deployed with plain **Helm** onto a **kind** cluster — deliberately *not* with
`abctl`. Everything is the upstream `airbyte/airbyte` chart plus values files, so
moving to EKS/GKE/AKS later means pointing the same values at a different
cluster rather than rebuilding the deployment.

Uses the chart's **bundled internal Postgres and MinIO**. No external database.

---

## Quick start

```bash
git clone <this repo> && cd easy-local-airbyte
cp .env.example .env        # optional; defaults work as-is
make bootstrap              # tools -> VM -> cluster -> Airbyte
make credentials            # print the login
open http://localhost:8000
```

First run pulls several GB of images and takes 10–20 minutes. Re-runs are fast.

Requires `docker`, `kubectl`, `helm`, `kind`:

```bash
brew install kubectl helm kind colima docker
```

---

## Commands

| Command | Does |
|---|---|
| `make bootstrap` | Everything: preflight, VM, cluster, ingress, Airbyte |
| `make status` | Pods, health, **and the effective low-resource settings** |
| `make credentials` | Login + API client credentials |
| `make backup` | Dump the internal Postgres to `backups/` |
| `make backups` | List backups |
| `make restore-latest` | Restore the newest backup |
| `make restore FILE=backups/x.sql.gz` | Restore a specific backup |
| `make install` | Install **or upgrade** (idempotent) |
| `make template` | Render manifests without applying |
| `make scale-down` / `scale-up` | Stop/start Airbyte, keep data and Postgres |
| `make logs COMPONENT=server` | Tail logs (`server`, `worker`, `workload-launcher`, `cron`) |
| `make shell-db` | `psql` shell on the internal Postgres |
| `make uninstall` | Remove the release, **keep** the cluster and Postgres data |
| `make down` | Delete the cluster (backups survive) |
| `make down-all` | Also stop the Docker VM |

Add `YES=1` to skip confirmation prompts (for CI/automation).

---

## Low-resource mode

`LOW_RESOURCE_MODE=true` (the default) is a Helm-native reimplementation of
`abctl --low-resource-mode`, ported from abctl's source
(`internal/helm/airbyte_values.go`) rather than guessed at. It lives in
[`config/values/low-resource.yaml`](config/values/low-resource.yaml), which
documents every value inline.

### What the mode actually does

1. **`JOB_RESOURCE_VARIANT_OVERRIDE=lowresource`** — the one that matters.
   Connectors ship declared resource requirements and the platform normally
   honours them. This makes the server resolve the *`lowresource` variant* of
   those requirements instead. On a single-node local cluster the declared
   defaults routinely exceed what the node can offer, so sync/check/discover
   pods sit `Pending` forever and connections look like they hang. **This is why
   connections run smoother in this mode.**

2. **Job resource *requests* → `0`**, limits untouched. Requests are what the
   scheduler reserves up front; zeroing them lets job pods schedule onto an
   already-committed node instead of being rejected. Limits stay at 3 CPU / 4 Gi
   so a runaway connector still can't eat the machine.

3. **Same for check / discover / spec / sidecar pods** — the short-lived ones
   behind "Test connection" and schema refresh, and the most common thing to get
   stuck `Pending` on a laptop.

4. **Connector-builder service disabled** (see below).

**Trade-off:** with requests at `0` the scheduler can't know what jobs will
consume, so it will overcommit the node. Right for local single-node, wrong for
production. Don't carry this file into a production cluster.

Verify what actually got deployed:

```bash
make status     # prints JOB_RESOURCE_VARIANT_OVERRIDE and every *_REQUEST/_LIMIT
```

### Three corrections made to abctl's values

These are real bugs in `abctl --low-resource-mode` as applied to chart 2.x, not
stylistic differences:

- **`connectorBuilderServer.enabled=false` does nothing.** That key doesn't
  exist in chart 2.x — the section was removed and the service renamed. Helm
  silently ignores unknown values, so abctl's setting has no effect and the pod
  keeps running. The replacement is `manifestServer`, which is what this repo
  disables. Set `DISABLE_CONNECTOR_BUILDER=false` in `.env` to keep the
  Connector Builder UI (costs one pod; connections and all built-in connectors
  are unaffected either way).

- **abctl never reaches replication pods.** It only sets the deprecated
  `global.jobs.resources` keys. Chart 2.2.0 notes the legacy fallback covers
  main-container resources only and that replication is explicitly *not*
  consumed ([airbyte#72833](https://github.com/airbytehq/airbyte/issues/72833))
  — so `REPLICATION_ORCHESTRATOR_*_REQUEST` stays at the chart default under
  abctl. Those pods are the ones that actually run your syncs. This repo sets
  both the legacy and modern keys.

- **Values must be quoted strings, not bare numbers.** The chart resolves these
  through sprig's `default`, which treats a bare `0` as *empty* and silently
  falls through to the chart default. `"0"` is truthy; `0` is not. Every value
  in the file is quoted for this reason.

---

## Logging in

```bash
make credentials
```

Community edition runs in **`simple` auth mode**. The login pair is:

| | |
|---|---|
| **Email** | whatever you typed on the first-run setup screen |
| **Password** | the generated `instance-admin-password` |

There is **no default username or password pair** to look up — per Airbyte's
[authentication docs](https://docs.airbyte.com/platform/deploying-airbyte/integrations/authentication),
auth is *"based on the email provided at setup and a generated password."* The
setup screen isn't asking you to authenticate; it's asking you to *define* the
admin email. Any address works.

`make credentials` reads the email back out of the database (`user.email`) and
the password out of the `airbyte-auth-secrets` Kubernetes secret, so it always
shows the pair that actually works — including after a restore, where the
password comes from the backup rather than from `.env`.

The password originates from `AIRBYTE_ADMIN_PASSWORD` in `.env`, generated on
first install and pinned there so it survives `helm upgrade` instead of being
regenerated each time. Set it yourself before the first install to choose one.

The `client-id` / `client-secret` shown are for the API, not the UI:

```bash
TOKEN=$(curl -s -X POST http://localhost:8000/api/v1/applications/token \
  -H 'Content-Type: application/json' \
  -d '{"client_id":"<id>","client_secret":"<secret>"}' | jq -r .access_token)
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8000/api/public/v1/workspaces
```

---

## Telemetry

**Disabled in `config/values/base.yaml`.** Verify at any time with `make status`,
which prints the live values and confirms the pods are actually running them.

A stock install of this chart **does phone home**: it ships a hardcoded Airbyte
Segment write key as the *default* for `tracking.segment.writeKeySecretKey`, with
`tracking.enabled: true` and `strategy: segment`. This repo sets:

| Setting | Value | Effect |
|---|---|---|
| `TRACKING_STRATEGY` | `logging` | The real off switch — events go to the pod log, not the network |
| `TRACKING_ENABLED` | `false` | Tracking off |
| `SEGMENT_WRITE_KEY` | `disabled` | Airbyte's built-in key replaced, so there is no valid destination |
| `PUBLISH_METRICS` | `false` | Undocumented in the chart, defaults to `true` |
| `MICROMETER_METRICS_ENABLED` | `false` | No metrics export |
| `DD_ENABLED` | `false` | No Datadog APM |
| `JOB_ERROR_REPORTING_STRATEGY` | `logging` | Connector stack traces stay local, not sent to Sentry |

`SEGMENT_WRITE_KEY` cannot be set to `""` — the chart resolves it through
sprig's `default`, which treats an empty string as unset and would restore the
real key. Hence the dummy value.

### The "Anonymize usage data collection" checkbox is not an off switch

You're right that it's misleading. That checkbox writes
`workspace.anonymous_data_collection`, which only controls **whether events are
tagged with your workspace ID or a random UUID** — it does not stop events being
sent. Airbyte's own [telemetry docs](https://docs.airbyte.com/platform/operator-guides/telemetry)
don't even mention the checkbox; they document `tracking.strategy: logging` as
the way to disable telemetry, which is what this repo does.

So: **with `TRACKING_STRATEGY=logging`, nothing is transmitted either way and the
checkbox is moot.** Tick it anyway — if a future chart upgrade or a hand-edited
values file ever re-enabled tracking, anonymised beats identified.

### What still contacts Airbyte, honestly

Disabling telemetry does not make the install fully air-gapped:

- **Connector registry** (`global.connectorRegistry.seedProvider: remote`) —
  fetches the connector catalogue and connector Docker images from Airbyte's
  CDN/registry. This is a functional download, not telemetry, but it does reveal
  your IP. Setting it to `local` uses the chart's bundled seed instead, at the
  cost of a stale connector list; left on `remote` here because the alternative
  degrades the product.
- **Image pulls** from Docker Hub / Airbyte's registry.

Telemetry state was verified by reading the environment of the running
`airbyte-server`, `airbyte-worker` and `airbyte-workload-launcher` processes —
i.e. the configuration Airbyte's documented off switch acts on. It was not
verified by packet capture.

---

## Backup and restore

### Why `pg_dumpall` and not `pg_dump`

The bundled Postgres server holds **more than `db-airbyte`**. Temporal
auto-creates `temporal` and `temporal_visibility` in the same server, and those
carry workflow and sync-scheduling state. A `pg_dump` of `db-airbyte` alone
silently loses them, and you find out at restore time. `scripts/backup.sh` uses
`pg_dumpall`, so the dump is the whole server.

`pg_dumpall` runs *inside* the Postgres pod, so its version always matches the
server exactly.

### What is and isn't covered

**Covered.** Sources, destinations, connections, sync state and history, users —
and **connector credentials**, because `global.secretsManager.enabled` is
`false`, which means Airbyte stores secrets in the config database. The dump is
a complete backup of your configuration.

⚠️ **Backups therefore contain credentials in plaintext.** `backups/` is
git-ignored. Treat those files like secrets.

**Not covered.** MinIO contents — sync logs and workload output. Those are
disposable artifacts, not configuration. Restoring without them costs you
historical log *text*, not any connection or state.

### Usage

```bash
make backup                              # backups/airbyte-pg-<utc-stamp>.sql.gz
make backup LABEL=before-upgrade         # adds a label to the filename
make backup KEEP=7                       # prune to the newest 7 afterwards
make backups                             # list what you have

make restore-latest
make restore FILE=backups/airbyte-pg-20260817T120000Z.sql.gz
```

Backups are gzipped and written to a `.partial` file that's only renamed after
`pg_dumpall` exits cleanly *and* the gzip stream and dump header both validate —
an interrupted backup never leaves a truncated file that looks usable. A
`.meta` sidecar records the chart version, so a restore warns you when the
backup came from a different chart than the running release.

### What restore does

Restore is destructive — it replaces the internal Postgres contents and prompts
before doing so.

1. **Scales every Airbyte deployment to 0**, recording the previous replica
   counts. Necessary because Airbyte holds pooled connections open and Postgres
   refuses to drop a database with any session attached — restoring against a
   live install fails partway and leaves a half-restored database.
2. Terminates leftover backends.
3. Replays the dump through `psql` connected to **`template1`**, not `postgres`:
   the dump contains `DROP DATABASE IF EXISTS postgres`, which can't run from a
   session connected to that same database.
4. **Verifies** — checks that every database the *dump itself* claims to carry
   is present afterwards (derived from the dump's `CREATE DATABASE` lines, not a
   hardcoded list, so a backup predating Temporal isn't reported as a failure),
   and reports row counts for `workspace`, `actor` and `connection`.

   `ON_ERROR_STOP` is deliberately off, because four errors are *structurally
   guaranteed* on every successful restore: `pg_dumpall --clean` always emits
   `DROP ROLE`/`CREATE ROLE` for the role you're connecting as, and a bare
   `DROP DATABASE template1`. We connect as `airbyte` to `template1` precisely
   so both of those fail — `template1` must survive — and the `ALTER ROLE`
   that follows still restores the role's attributes and password. The script
   classifies these against a known-benign list and reports
   `4 expected, 0 unexpected` rather than crying wolf; only genuinely
   unexpected errors mark the restore as failed. This verification, not an exit
   code, is what tells you the restore worked.
5. Scales back up to the recorded counts.

If a restore is interrupted mid-way it says so and leaves the replica counts in
`.restore-scale-state`; `make scale-up` recovers.

After restoring, the admin password is the one from the **backup**, not the one
in `.env`. `make credentials` reads the live cluster and warns when they differ.

### Restoring into a fresh cluster

Backups survive `make down`, so this is the disaster-recovery path:

```bash
make backup
make down
make bootstrap
make restore-latest
```

---

## Layout

```
config/
  kind-cluster.yaml          single node, localhost:8000 -> ingress :80
  values/base.yaml           internal Postgres + MinIO, ingress, auth
  values/low-resource.yaml   the abctl --low-resource-mode equivalent
  values/local.yaml          your uncommitted overrides (git-ignored, optional)
scripts/
  lib/common.sh              config, defaults, kubectl/helm helpers
  preflight.sh  up.sh  install.sh  status.sh  credentials.sh
  backup.sh  restore.sh  list-backups.sh  scale.sh  down.sh
backups/                     git-ignored dumps
```

Configuration is via `.env` (see `.env.example`); every value has a working
default in `scripts/lib/common.sh`.

---

## Design notes

**kind, not abctl.** abctl wraps kind + Helm but owns the cluster lifecycle and
hides the values it generates. Driving Helm directly keeps the deployment
portable and reviewable.

**A dedicated `colima` VM profile.** On macOS the scripts create a profile named
`airbyte` (6 CPU / 12 GiB / 60 GiB) rather than resizing your existing Docker
setup, which they never touch. Set `DOCKER_PROVIDER=existing` to use whatever
`docker` currently points at, or raise `VM_CPUS` / `VM_MEMORY_GIB` in `.env`.
Both `docker` and `kind` are pointed at the profile via `DOCKER_CONTEXT`.

**No host bind-mount for PV data.** abctl bind-mounts the PersistentVolume
directory to the host. On macOS that path is a virtiofs mount into the Docker VM,
and running Postgres' data directory across it invites permission and `fsync`
problems (the DB container runs as uid 70). PV data therefore stays inside the
node's filesystem, and durability across a cluster rebuild is handled properly
by the backup/restore scripts rather than by a fragile mount.

**`helm uninstall` keeps your data.** The chart creates the Postgres StatefulSet
and PVC as Helm `pre-install` hooks, so they aren't tracked as release resources
and survive `make uninstall`. Deleting the *namespace* or the *cluster* does
destroy them.

**Cookies.** `global.auth.security.cookieSecureSetting=false` is set because
this is served over plain HTTP on localhost; left at the default the browser
drops the session cookie and login fails silently. Change it if you put TLS in
front.

**Moving to a cloud cluster.** Point `KUBE_CONTEXT` at the target, keep
`base.yaml`, drop `low-resource.yaml`, and switch `global.storage.type` to
`s3`/`gcs` and `global.database.type` to `external` for a managed Postgres.

---

## Troubleshooting

**Pods stuck `Pending`** — not enough CPU/RAM on the node. `make status` calls
this out. Confirm `LOW_RESOURCE_MODE=true`, then raise `VM_CPUS` /
`VM_MEMORY_GIB` in `.env` and recreate the VM
(`colima delete -p airbyte && make bootstrap`).

**`localhost:8000` not responding** — check the controller with
`kubectl --context kind-easy-local-airbyte -n ingress-nginx get pods`. If port 8000 is
taken, set `HOST_PORT` in `.env`; it's baked into the kind port mapping, so the
cluster must be recreated (`make down && make bootstrap`).

**Login rejects a correct password** — usually `cookieSecureSetting`. Confirm
you're on `http://localhost:<port>` and not an HTTPS or non-localhost hostname.

**Sync fails but "Test connection" passes** — nearly always resources. Check
`REPLICATION_ORCHESTRATOR_*` in `make status` and the launcher logs
(`make logs COMPONENT=workload-launcher`).

---

## Versions

| | |
|---|---|
| Airbyte chart | `2.2.0` (`CHART_VERSION`) |
| Chart repo | `https://airbytehq.github.io/charts` (v2 line) |
| kind node | `kindest/node:v1.33.1` |
| ingress-nginx chart | `4.11.3` |

Upgrade by bumping `CHART_VERSION` in `.env` and running `make install`. Take a
`make backup` first.
