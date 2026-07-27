# Redis Consumer Discovery — Usage Guide

This tool scans a foundation and reports **which applications use each Redis service, and how**,
ahead of the Redis→Valkey migration. It runs from the bastion and reads live state only — it
makes **no changes** to any Redis, app, or deployment.

The one input you must know is your **environment name** (the genesis env, e.g.
`sandbox-us-east`). A trailing `.yml` or leading `@` is fine — the script normalises it.

---

## 1. Authenticate with Vault first

Before running, authenticate with Vault as you normally do on the bastion. The script uses your
existing genesis and `cf` sessions, so make sure `cf` is also logged in and targeted at the
foundation.

---

## 2. Check the environment (once)

Confirm the bastion can reach everything:

    bash redis-consumer-discovery.sh preflight <env>

This lists the Redis deployments and Diego cells it can see. Then run the full check against any
one Redis deployment from that list:

    bash redis-consumer-discovery.sh preflight <env> --redis <a-redis-deployment>

All checks should report success (`SUDO_OK`, `SCP_ROUNDTRIP_OK`, a cfdot JSON sample,
`CF_API_OK`). If any fail, resolve access before continuing.

---

## 3. Run the scan

    bash redis-consumer-discovery.sh run <env>

This scans **every Redis deployment** on the foundation, identifies the apps connected to each,
classifies how each app uses Redis, and writes the results (see section 4). It skips idle or
orphaned Redis automatically and never stops on a single failure.

By default results go to the **current directory**. To choose an output folder:

    bash redis-consumer-discovery.sh run <env> ./scan-output

Options (prepend or append as needed):

| Option | Effect |
|---|---|
| `RCD_PAR=<n> bash ... run <env>` | How many Redis/cells to scan **concurrently** (default 8). Raise for speed, lower if the director is strained. |
| `RCD_RESUME=1 bash ... run <env>` | Continue an interrupted scan; skip Redis already done. |
| `RCD_INCLUDE_VALKEY=1 bash ... run <env>` | Also scan Valkey (default: Redis only). |
| `... run <env> --redis <deployment>` | Scan a single Redis deployment (spot check). |

> **Important:** an app must have a **live connection** to Redis to be detected. Apps that were
> idle at scan time won't appear. For completeness, run the scan a few times across a normal
> business day.

---

## 4. Generated files

After a run, the output folder contains:

| File | What it is | Use this for |
|---|---|---|
| **`redis_consumers.txt`** | **The final report (CSV).** One row per app↔Redis pair. | **This is the deliverable.** Open in Excel/Sheets. |
| `orphaned/orphaned-<timestamp>.tsv` | Redis with no consumers in that scan. | Kept for later review; ignore for now. |
| `02_conns.tsv`, `03_cellmap.tsv`, `04_lrps.*`, `05_apps.tsv`, `06_classified.tsv`, `redis_ips.tsv` | Working files produced along the way. | Diagnostics/support only — ignore for normal use. |

### The final report — `redis_consumers.txt`

Columns: `app_name, space, org, method, static_ref, static_ref_target, redis_service_name, redis_service_space, redis_service_org, redis_deployment`.

`space`/`org` are where the **app** runs; `redis_service_space`/`redis_service_org` are where the
**Redis service instance** lives. When they differ, the app is reaching a Redis managed in a
different space/org — worth flagging for migration ownership.

`static_ref` is filled **independently of `method`**: it says whether the app *also* hardcodes
the Redis address (in env vars or its manifest), even when it's bound. **A row with
`method = cf-bind` and `static_ref = env-var` is a migration hazard** — the binding will
auto-migrate to Valkey, but the hardcoded env var will still point at the old Redis, so the app
may keep using the dead Redis after cutover. These need the env var updated, not just a rebind.
Filter for them first: `method=cf-bind` **and** `static_ref` not empty.

`static_ref_target` tells you **which** Redis the hardcoded reference points at, but only when
it is **different** from this row's Redis:
- **blank** → the static reference points at *this* row's Redis (the hardcoded address matches, or
  couldn't be extracted). This is the normal in-place hazard above.
- **an address (e.g. `10.0.0.9 [other-cache]`)** → the app is bound to *this* Redis but its env
  var/manifest points at a **different** Redis (shown resolved to that service's name when it's
  one we scanned). These apps span two Redis services — migrate/repoint both, and confirm which
  one the app actually uses. A bare hostname here means the target couldn't be matched to a
  scanned Redis by IP — verify it manually.

The **`method`** column tells you what each app needs at migration:

| `method` | Meaning | Migration action |
|---|---|---|
| `cf-bind` | Standard service binding. | Auto-migrates. No app-team action. |
| `static-ref: env-var` | Redis address is set in the app's environment variables. | Update the env var to the new Valkey details. |
| `static-ref: manifest` | Redis address is on the app's start command / sidecar. | Update the manifest and re-push. |
| `unknown` | App **is** identified, but the Redis details aren't visible to the platform (e.g. in an app config file or an external config server). | App-team review required. |
| `unresolved` | A live connection was seen but the **app couldn't be identified** in this scan (container was rescheduled between scan steps, or its record was momentarily unreadable). | Usually transient — **re-run the scan** to resolve. Not an app-config problem. |
| `external` | A connection from outside Cloud Foundry (not an app). | Service-owner / firewall review. |

---

## 5. Notes

- The tool is **read-only** — safe to run anytime, including production, during business hours.
- A single scan is a snapshot. Run it several times when apps are active for full coverage.
- If a run reports "no live connections," the Redis were idle or the apps weren't connected at
  that moment — re-run when apps are active.
