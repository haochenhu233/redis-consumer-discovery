# redis-consumer-discovery

Single-file tool to discover which Cloud Foundry apps consume each Blacksmith-managed
Redis instance, and **how** they reach it (standard binding / static ref / unknown /
external), ahead of a Redis→Valkey migration.

It traces **from the Redis side → Diego cell → app**, so it also catches consumers that
have no CF binding, env var, or manifest reference — the ones config-side scans miss.

## Design

- **One file:** `redis-consumer-discovery.sh`. Copy just this file into the environment.
- **Read-only:** `ss` (never `-K`), `cf curl` GETs, `cfdot` reads. No mutations.
- **Same file is the worker:** `census`/`sweep` scp this script to the Redis VM / cell and
  run a hidden `_worker-*` subcommand there, so nothing else to distribute.
- **Runs over genesis:** all host access is `genesis <env> b -d <dep> ssh|scp ...`.

## Usage

```
redis-consumer-discovery.sh <subcommand> <env> [output-dir] [--redis <dep>] [--cell <group/idx>]
```

`<env>` is the genesis env name (a trailing `.yml` is stripped). `[output-dir]` defaults to
the current directory. Deployment names are not hardcoded; genesis targets them:

```
genesis @<env>    b <args>   == bosh -e <env>             <args>   # director level; redis via -d
genesis @<env>:cf b <args>   == bosh -e <env> -d <env>-cf <args>   # CF / diego cells
```

Preflight:

```
redis-consumer-discovery.sh preflight <env>                       # discover redis deps + cell group
redis-consumer-discovery.sh preflight <env> --redis <redis-dep>   # run primitive checks
```

Subcommands (built and verified one at a time):

| Subcommand | Status | Output |
|---|---|---|
| `preflight [dep]` | ready | proves primitives + discovers env values |
| `inventory` | pending | `01_redis.tsv` (redis dep → service name/org/space) |
| `census <dep>` | pending | `02_conns.tsv` (redis → cell IP:port peers) |
| `sweep <cell>` | pending | `03_cellmap.tsv` (conn → instance_guid, container ip) |
| `resolve` | pending | `05_apps.tsv` (instance_guid → app_guid via cfdot dump) |
| `classify` | pending | `06_classified.tsv` (method per app/redis) |
| `report` | pending | `redis_consumers.txt` (final CSV) |

Final CSV columns: `app_name, space, org, method, redis_service_name, redis_deployment`.

## Status

Work in progress — being built and verified stage by stage against a real sandbox.
