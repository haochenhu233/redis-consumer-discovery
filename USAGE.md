# Redis Consumer Discovery — Usage Guide

This toolkit answers **which applications use each Redis service, and how**, ahead of the
Redis→Valkey migration. It is **read-only** — it makes no changes to any Redis, app, or
deployment, and is safe to run anytime, including production.

It works in two directions, then merges them:

| Step | Command | What it finds |
|---|---|---|
| Backward scan | `run` | who is **actually connected** to each Redis right now |
| Forward scan | `scan-apps` + `list-redis` | who is **configured** to use Redis (bindings, env vars, manifests) |
| Merge | `merge` | one combined report — **`merged_report.csv` is the deliverable** |
| Owners | `owners.sh` | adds the people to contact per app row |

The one input you must know is your **environment name** (the genesis env, e.g.
`sandbox-us-east`). A trailing `.yml` or leading `@` is fine — the script normalises it.

All commands share a **base directory** via `--path <dir>` (default: the current directory):

    <base>/backward/           <- backward scan results
    <base>/forward/            <- forward scan results
    <base>/merged_report.csv   <- the merge output (the deliverable)

---

## 1. Authenticate first

On the bastion, authenticate with Vault as you normally do, and make sure `cf` is logged in
(admin) and targeted at the foundation. The scripts use your existing genesis and `cf` sessions.

## 2. Check the environment (once per foundation)

    bash redis-consumer-discovery.sh preflight <env>
    bash redis-consumer-discovery.sh preflight <env> --redis <a-redis-deployment>

All checks should report success (`SUDO_OK`, `SCP_ROUNDTRIP_OK`, a cfdot JSON sample,
`CF_API_OK`). If any fail, resolve access before continuing.

## 3. Backward scan — who is connected

    bash redis-consumer-discovery.sh run <env> --path ./np-scan

Scans **every Redis deployment**, identifies the connected apps (Linux **and Windows** cells),
classifies each connection, and writes `./np-scan/backward/`. Skips idle/orphaned Redis
automatically; never stops on a single failure.

| Option | Effect |
|---|---|
| `RCD_PAR=<n>` | Concurrency for Redis/cells (default 8). Raise for speed, lower if the director is strained. |
| `RCD_RESUME=1` | Continue an interrupted scan; skip Redis already done. |
| `RCD_INCLUDE_VALKEY=1` | Also scan Valkey (default: Redis only). |
| `--redis <deployment>` | Scan a single Redis deployment (spot check). |

> **Windows cells:** keep `windows-wsweep.ps1` in the same directory as the main script (it
> comes with the repo). Without it, Windows cells are skipped and their apps appear as
> `external`.

> An app must have a **live connection** to be seen by this scan — that's what the forward
> scan (next) compensates for. Still, running it a few times across a business day improves
> coverage.

## 4. Forward scan — who is configured

    bash redis-consumer-discovery.sh scan-apps  <env> --path ./np-scan
    bash redis-consumer-discovery.sh list-redis <env> --path ./np-scan

`scan-apps` sweeps the CF API: every app, service binding, env var, and manifest (this is the
slow phase at thousands of apps; it needs a `cf` user that can read env vars — full admin).
`list-redis` records which Redis deployments actually exist in BOSH.

Optional cross-check — service instances that exist in CF but have no BOSH deployment (and
vice versa):

    bash redis-consumer-discovery.sh ghosts <env> --path ./np-scan

## 5. Merge — the deliverable

    bash redis-consumer-discovery.sh merge <env> --path ./np-scan

Joins both scans into **`./np-scan/merged_report.csv`** — one row per app↔Redis relationship.

> **Environments with zero live connections** (e.g. DR foundations) merge fine: the report is
> built from the forward scan alone and every row shows `live_connection=no`. That is the
> correct statement for a DR env — configured consumers, nothing talking at scan time.

## 6. Owners — who to contact per app

    bash owners.sh ./np-scan

Appends three columns to the report → **`merged_report_owners.csv`** (original untouched):

| Column | Content |
|---|---|
| `org_managers` | human org managers (always listed) |
| `space_owners` | **space manager(s)** if the space has any; otherwise up to **5 space developers** |
| `owner_source` | `space-manager` / `space-developers` / `none` |

Only **human** users are listed (usernames that look like emails); CI/service accounts are
filtered out. `owner_source = none` means no human owner was found — contact the
`org_managers`. Owner data is fetched fresh from the CF API at run time, so contacts are
current even for an older scan. To split the report for distribution: open
`merged_report_owners.csv`, group by org+space, send each chunk to its `space_owners`.

## 7. Re-deriving without re-scanning

- `reclassify <env> --path <base>` — re-runs the backward classification from the existing
  census (no Redis re-scan). Use after script updates.
- `merge` and `owners.sh` can be re-run anytime against existing files; `owners.sh` with
  `RCD_OWNERS_OFFLINE=1` reuses its previously fetched CF data.

---

## 8. Reading `merged_report.csv`

Columns: `app_name, space, org, app_guid, method, static_ref, static_ref_target,
redis_service_name, redis_service_space, redis_service_org, redis_deployment,
service_instance_guid, platform, deployment_exists, live_connection, source`
(+ the three owner columns after `owners.sh`).

**`method`** — how the app accesses Redis, and what migration needs:

| `method` | Meaning | Migration action |
|---|---|---|
| `cf-bind` | Standard service binding. | Migrated by the platform. No app-team action. |
| `static-ref: env-var` | Redis address set in the app's env vars. | Update the env var to the new details. |
| `static-ref: manifest` | Redis address on the start command / sidecar. | Update the manifest and re-push. |
| `unknown` | App identified, but its Redis config isn't visible to the platform (config file / config server). | App-team review. |
| `unresolved` | Connection seen but the app couldn't be identified in that scan. | Transient — re-run the scan. |
| `external` | A connection from outside Cloud Foundry. | Service-owner review. |

**The hazard filter — check this first:** rows with `method = cf-bind` **and** `static_ref`
not empty are bound apps that *also* hardcode the address. The binding migrates, the
hardcoded copy silently doesn't — these apps need the env var removed/updated before their
migration. `static_ref_target` shows where the hardcoded copy points when it is a *different*
Redis than this row's (blank = same Redis, the normal case).

**Other columns worth knowing:**
- `live_connection` — `yes` = seen talking at scan time; `no` = configured but idle at scan.
  **Idle apps still migrate** — don't skip them.
- `deployment_exists` — `no` = the CF service instance has no BOSH deployment behind it (a
  ghost); bindings to it are dangling and need cleanup, not migration.
- `platform` — `windows` or `linux` cell; same migration either way.
- `source` — `both` (configured + connected), `forward` (configured only), `backward`
  (connected but no binding found).
- `space`/`org` vs `redis_service_space`/`redis_service_org` — when they differ, the app uses
  a Redis owned by another team; coordinate both sides.

**Backward-only output** (in `backward/`): `redis_consumers.txt` is the connection-only
report, and `orphaned/…tsv` lists Redis with no consumers seen in that scan. The numbered
`0*.tsv` files are working files — ignore them.

---

## 9. Notes

- Everything is **read-only**; run anytime, including business hours in production.
- A single backward scan is a snapshot — repeat runs across a business day improve coverage;
  the forward scan covers configured-but-idle apps regardless.
- **Line endings:** the scripts need Unix (LF) endings. A fresh `git clone` handles this (the
  repo's `.gitattributes` forces it). If you copied a file another way and see errors like
  `\r: command not found`, convert once: `sed -i 's/\r$//' <file>`.
