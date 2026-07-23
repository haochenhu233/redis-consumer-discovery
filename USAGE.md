# Redis Consumer Discovery — Usage Guide

This tool scans a foundation and reports **which applications use each Redis service, and how**,
ahead of the Redis→Valkey migration. It runs from the bastion and reads live state only — it
makes **no changes** to any Redis, app, or deployment.

---

## 1. Prerequisites

Run everything from the **bastion**. You need:

- `genesis` able to target the foundation (you already use `genesis @<env> ...`).
- `cf` logged in and targeted at the foundation: `cf login ...` (any org/space).
- `jq` installed on the bastion.
- Your usual permissions to `bosh ssh` into service and Diego VMs via genesis.

The one input you must know is your **environment name** (the genesis env, e.g.
`sandbox-us-east`). A trailing `.yml` or leading `@` is fine — the script normalises it.

---

## 2. Get the script

Open this page in your VDI browser and copy the file into a file named
`redis-consumer-discovery.sh` on the bastion:

    https://github.com/haochenhu233/redis-consumer-discovery/blob/main/redis-consumer-discovery.sh

(Use the **copy** button at the top-right of the file view.) When an updated version is
published, refresh that page and copy it again — the location never changes.

---

## 3. Check your environment (once)

Before the first real run, confirm the bastion can reach everything:

    bash redis-consumer-discovery.sh preflight <env>

This lists the Redis deployments and Diego cells it can see. Then run the full check against
any one Redis deployment from that list:

    bash redis-consumer-discovery.sh preflight <env> --redis <a-redis-deployment>

All checks should report success (`SUDO_OK`, `SCP_ROUNDTRIP_OK`, a cfdot JSON sample,
`CF_API_OK`). If any fail, resolve access before continuing.

---

## 4. Run the scan

    bash redis-consumer-discovery.sh run <env>

This scans **every Redis deployment** on the foundation, identifies the apps connected to each,
classifies how each app uses Redis, and writes the results (see section 6). It skips idle or
orphaned Redis automatically and never stops on a single failure.

By default results go to the **current directory**. To choose an output folder:

    bash redis-consumer-discovery.sh run <env> ./scan-output

Options (prepend as needed):

| Option | Effect |
|---|---|
| `RCD_RESUME=1 bash ... run <env>` | Continue an interrupted scan; skip Redis already done. |
| `RCD_INCLUDE_VALKEY=1 bash ... run <env>` | Also scan Valkey (default: Redis only). |
| `... run <env> --redis <deployment>` | Scan a single Redis deployment (spot check). |

> **Important:** an app must have a **live connection** to Redis to be detected. Apps that were
> idle at scan time won't appear. For completeness, run the scan a few times across a normal
> business day (see section 5).

---

## 5. Repeat scans and find unused Redis

Each run records which Redis had **no consumers** at that moment. After running the scan on
several different days/times, merge those records to find Redis that is consistently unused:

    bash redis-consumer-discovery.sh merge-orphaned <env>

This produces `orphaned_merged.tsv`, flagging Redis that had **zero consumers in every scan**
as `truly_orphaned=YES` — cleanup candidates. (Point it at the same output folder you used for
`run`, e.g. `merge-orphaned <env> ./scan-output`.)

---

## 6. Generated files

After a run, the output folder contains:

| File | What it is | Use this for |
|---|---|---|
| **`redis_consumers.txt`** | **The final report (CSV).** One row per app↔Redis pair. | **This is the deliverable.** Open in Excel/Sheets. |
| `orphaned/orphaned-<timestamp>.tsv` | Redis with 0 consumers in that single scan. | Input to `merge-orphaned`; keep across runs. |
| `orphaned_merged.tsv` | Redis unused across all scans (after `merge-orphaned`). | Cleanup candidate list. |
| `02_conns.tsv`, `03_cellmap.tsv`, `04_lrps.*`, `05_apps.tsv`, `06_classified.tsv` | Working files produced along the way. | Diagnostics/support only — ignore for normal use. |

### The final report — `redis_consumers.txt`

Columns: `app_name, space, org, method, redis_service_name, redis_deployment`.

The **`method`** column tells you what each app needs at migration:

| `method` | Meaning | Migration action |
|---|---|---|
| `cf-bind` | Standard service binding. | Auto-migrates. No app-team action. |
| `static-ref: env-var` | Redis address is set in the app's environment variables. | Update the env var to the new Valkey details. |
| `static-ref: manifest` | Redis address is on the app's start command / sidecar. | Update the manifest and re-push. |
| `unknown` | App connects, but the Redis details aren't visible to the platform (e.g. in an app config file or an external config server). | App-team review required. |
| `external` | A connection from outside Cloud Foundry (not an app). | Service-owner / firewall review. |

---

## 7. Notes

- The tool is **read-only** — safe to run anytime, including production, during business hours.
- A single scan is a snapshot. Combine several scans (section 5) for full coverage.
- If a run reports "no live connections," the Redis were idle or the apps weren't connected at
  that moment — re-run when apps are active.
