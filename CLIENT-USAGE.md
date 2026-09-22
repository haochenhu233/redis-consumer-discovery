# Redis Consumer Discovery — How to Run

You have three files — keep them **in the same directory** on the bastion:

| File | Purpose |
|---|---|
| `redis-consumer-discovery.sh` | the scanner (all commands below) |
| `windows-wsweep.ps1` | helper the scanner uses for Windows cells — must sit next to it |
| `owners.sh` | adds the contact persons to the final report |

Everything is **read-only** — no Redis, app, or deployment is changed. Safe to run anytime,
including production.

You need: your **environment name** (the genesis env, e.g. `prod-us-east` — `@` prefix or
`.yml` suffix are fine), an authenticated **Vault** session, and an **admin `cf` login**
targeted at the foundation.

---

## Step 0 — one-time check per foundation

    bash redis-consumer-discovery.sh preflight <env>
    bash redis-consumer-discovery.sh preflight <env> --redis <any-redis-deployment-from-the-first-output>

Every check should report success (`SUDO_OK`, `SCP_ROUNDTRIP_OK`, a JSON sample, `CF_API_OK`).
If something fails, fix access before continuing.

## Step 1 — scan who is CONNECTED (live connections)

    bash redis-consumer-discovery.sh run <env> --path ./scan

Visits every Redis deployment and identifies the apps currently connected to each
(Linux and Windows). Takes a while on large foundations — you can speed it up or resume:

    RCD_PAR=16 bash redis-consumer-discovery.sh run <env> --path ./scan     # more parallel
    RCD_RESUME=1 bash redis-consumer-discovery.sh run <env> --path ./scan   # continue after interruption

## Step 2 — scan who is CONFIGURED (bindings, env vars, manifests)

    bash redis-consumer-discovery.sh scan-apps  <env> --path ./scan
    bash redis-consumer-discovery.sh list-redis <env> --path ./scan

`scan-apps` sweeps every app via the CF API (the slow part on big foundations); `list-redis`
records which Redis deployments exist. This step also catches apps that were idle during
Step 1.

## Step 3 — merge into the report

    bash redis-consumer-discovery.sh merge <env> --path ./scan

Creates **`./scan/merged_report.csv`** — one row per app↔Redis relationship.

Note: an environment with no live connections at all (e.g. a DR foundation) still merges —
every row simply shows `live_connection=no`, which is the correct result there.

## Step 4 — add the owners

    bash owners.sh ./scan

Creates **`./scan/merged_report_owners.csv`** with three extra columns per row:

| Column | Content |
|---|---|
| `org_managers` | the org managers (always filled) |
| `space_owners` | the space **manager(s)** — or, if the space has none, up to **5 space developers** |
| `owner_source` | `space-manager` / `space-developers` / `none` |

Only real people are listed (usernames that look like email addresses — CI and service
accounts are filtered out). If `owner_source` is `none`, no human owner was found for that
space — use the `org_managers` column instead.

**This file is the end result.** Open it in Excel, group the rows by org + space, and send
each team its rows using the `space_owners` addresses.

---

## Reading the report — the essentials

- **`method`** — how the app uses Redis:
  `cf-bind` = standard binding (the platform migrates these) · `static-ref: …` = the address
  is hardcoded in env vars or the manifest · `unknown` = the app's Redis config isn't visible
  to the platform (app team knows) · `unresolved` = couldn't identify the app in this scan
  (transient — re-run) · `external` = a connection from outside Cloud Foundry.
- **Check first:** rows with `method = cf-bind` **and** a non-empty `static_ref` — these apps
  are bound *and* hardcode the address. The binding migrates automatically, the hardcoded
  copy does not — that env var must be updated/removed for the migration.
- **`live_connection` = no** means the app was idle at scan time — it still migrates; don't
  skip it.
- **`deployment_exists` = no** means the service instance has no deployment behind it
  (leftover record) — cleanup, not migration.

## Good to know

- After updating the scripts, run `bash redis-consumer-discovery.sh selftest` once — it checks
  the matching logic (no environment needed) and must print `ALL PASS`.
- Re-running is always safe. Steps 3 and 4 can be re-run anytime without re-scanning.
- To see exactly what changed between two reports (after a script update or a re-scan):
  `bash compare-reports.sh <old>/merged_report.csv <new>/merged_report.csv` — prints a summary
  and writes `removed.csv` (rows that disappeared), `added.csv` (newly found consumers),
  `changed.csv` (old vs new side by side) and `hazards-cleared.csv` (flags that turned out to
  be false — do not contact those teams).
- Repeat Step 1 on another business day for better coverage of rarely-active apps.
- The scripts need Unix (LF) line endings. If you ever see `\r: command not found`, run once:
  `sed -i 's/\r$//' redis-consumer-discovery.sh owners.sh`
