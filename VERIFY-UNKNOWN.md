# Manually verifying an `unknown` connection — live, with the app team

Some report rows show `method = unknown`: the app **is** identified and **is** connected, but
nothing in CF explains *how* it got the Redis address (no binding, no env var, no manifest
entry). App teams sometimes don't believe these rows ("we don't use that Redis"). This guide
proves the connection **live**, from three independent viewpoints, and then hunts for the
*why* — in front of the app team.

Everything here is **read-only** (one clearly-marked optional exception). Run it on non-prod
first. You need: the report row (app name / org / space, `redis_deployment`), `cf` admin
login, bosh access via genesis, and — for Proof C — sudo on the Diego cell.

> Do the whole walk once on a **cleanly-bound app** (`method = cf-bind`, active) before doing
> it with an audience. That validates every command in your environment and shows the team
> what a "normal" result looks like.

---

## Step 0 — variables (from the report row)

```bash
APP="the-app-name"; ORG="its-org"; SPACE="its-space"
REDIS_DEP="redis-cache-small-xxxxxxxx-...."          # column: redis_deployment
SI_GUID="${REDIS_DEP: -36}"                          # last 36 chars = service-instance GUID

# the Redis VM IP — from the scan output…
grep "$REDIS_DEP" <scan-base>/backward/redis_ips.tsv
# …or live:
genesis @<env> b -d "$REDIS_DEP" vms
REDIS_IP="10.x.x.x"; REDIS_PORT=6379

cf target -o "$ORG" -s "$SPACE"
APP_GUID=$(cf app "$APP" --guid)
```

First, show the team **why** the row says `unknown` — the absence that defines it:

```bash
cf curl "/v3/service_credential_bindings?app_guids=$APP_GUID&service_instance_guids=$SI_GUID" \
  | jq '.pagination.total_results'        # 0 = no binding to this Redis
cf env "$APP" | grep -iE 'redis|valkey|6379|'"${REDIS_IP//./\\.}"   # nothing (or nothing for THIS redis)
```

No binding, no env reference — and yet, next, a live socket.

---

## Which port? 6379 — or 16379 for TLS

Redis instances run in **dual mode**: plaintext on `6379` and **TLS on `16379`** (native
`tls-port` in redis.conf; the binding credentials carry both `port` and `tls_port`). A
`findstr`/`grep` on `6379` finds nothing for an app that connects over TLS — filter on the
**Redis IP**, not the port, in every proof, and check both ports on the Redis VM:

```bash
sudo ss -Htn state established "( sport = :6379 or sport = :16379 )"
```

An app on `16379` is a **TLS consumer** — note it on the session record: its Valkey target must
be a TLS-enabled plan, and the app must trust the new instance's certificate (per-instance
certs are issued by the platform's services CA). That is a migration requirement in its own
right, separate from how the app learned the address.

## Proof A — from inside the app's own container (the convincing one)

```bash
cf ssh "$APP"        # needs ssh enabled: check `cf ssh-enabled "$APP"`; multiple instances: -i 0
```

Inside the container:

```bash
ss -Htn state established | grep "$REDIS_IP"      # REDIS_IP typed literally here
```

A line like `10.255.x.x:47632  10.x.x.x:6379` is the app's **own socket** to the Redis —
seen from inside the app's container, with no platform tooling involved. Note the **local
port** (here `47632`) — it links Proof A to Proof B.

If `ss` doesn't exist in the container, read the kernel table directly. `/proc/net/tcp`
stores addresses as little-endian hex; generate the pattern **on the bastion** first:

```bash
# bastion: build the hex pattern for REDIS_IP:REDIS_PORT
IFS=. read -r a b c d <<< "$REDIS_IP"; printf '%02X%02X%02X%02X:%04X\n' "$d" "$c" "$b" "$a" "$REDIS_PORT"
# inside the container (state 01 = ESTABLISHED):
grep -i '<that-pattern>' /proc/net/tcp
```

**Which process owns it** (the team's first real clue):

```bash
ps -ef                                            # usually obvious: the main app process
# precise: match the socket inode to a process fd
INO=$(grep -i '<hex-pattern>' /proc/net/tcp | awk '{print $10}')
for p in /proc/[0-9]*; do ls -l $p/fd 2>/dev/null | grep -q "socket:\[$INO\]" && echo "$p"; done
cat /proc/<pid>/cmdline | tr '\0' ' '; echo       # what exactly is running
```

## Proof B — from the Redis VM (the other end of the same socket)

```bash
genesis @<env> b -d "$REDIS_DEP" ssh
# on the VM:
sudo ss -Htn state established "sport = :6379" | awk '{print $5}' | sort | uniq -c | sort -rn
```

Important reading note: **the peer IPs here are Diego CELL IPs, not container IPs** —
container traffic is source-NATed to the cell. To show the team that one of those cells is
where *their* app instance runs:

```bash
# bastion: which cell hosts the app instance?
cf curl "/v3/processes/$APP_GUID/stats" | jq -r '.resources[] | "\(.index) \(.host)"'
```

That `host` IP appearing in the Redis-side peer list is the corroboration. For a tighter
match: the **source port** usually survives the NAT, so the port from Proof A appears in
the Proof-B output for that cell IP (`sudo ss -Htn "sport = :6379" | grep <port>`). If it
doesn't, the port was rewritten by NAT — Proof C settles it beyond argument.

## Proof C — the bridge on the cell (definitive; what the scanner automates)

On the Diego cell whose IP matched (`genesis @<env>:cf b ssh <diego-cell/uuid>`), enumerate
container network namespaces and find the one holding the connection:

```bash
declare -A seen
for nsfile in /proc/[0-9]*/ns/net; do
  pid=${nsfile#/proc/}; pid=${pid%/ns/net}
  ino=$(sudo readlink "$nsfile" 2>/dev/null) || continue
  [ -n "${seen[$ino]:-}" ] && continue; seen[$ino]=$pid
  hit=$(sudo nsenter -t "$pid" -n ss -Htn state established "dst = <REDIS_IP>" 2>/dev/null)
  [ -n "$hit" ] && echo "pid $pid: $hit"
done
# confirm the pid belongs to THIS app:
sudo tr '\0' '\n' < /proc/<pid>/environ | grep -E '^VCAP_APPLICATION=' \
  | sed 's/^VCAP_APPLICATION=//' | jq '{application_name, space_name, organization_name}'
```

Same 4-tuple as Proofs A and B, with the app's name on the owning process. Case closed on
*whether* — now the interesting part.

---

## Windows apps — the same three proofs, different tools

Windows containers (winc) have no network namespaces to walk; instead the cell **source-NATs**
every container connection through WinNAT, and the NAT session table is the bridge. Step 0
(variables, the binding/env absence check) is identical. `cf ssh` works for Windows apps if
ssh is enabled (`cf ssh-enabled "$APP"`); it drops you into `cmd.exe` — type `powershell` first.

### Proof A (Windows) — inside the app's container

```powershell
cf ssh <app>
powershell
netstat -ano | findstr "<REDIS_IP>"       # NOT the port: TLS consumers use 16379; last column = owning PID
# or, nicer:
Get-NetTCPConnection -State Established | Where-Object { $_.RemoteAddress -eq '<REDIS_IP>' } |
  Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, OwningProcess
ipconfig | findstr IPv4                    # the CONTAINER IP -- note it, it links to Proof C
```

The socket to `<REDIS_IP>:6379` seen from inside the app's own container. Note the **LocalPort**
(container-side port) and the container IP. Owning process:

```powershell
Get-Process -Id <OwningProcess> | Select-Object Id, ProcessName, Path
Get-CimInstance Win32_Process -Filter "ProcessId=<pid>" | Select-Object CommandLine
```

### Proof B (Windows) — from the Redis VM

Exactly as for Linux (`sudo ss -Htn state established "sport = :6379"` on the Redis VM). The
peer IP is the **Windows cell's IP** (WinNAT SNAT), and the peer **port is rewritten** by NAT —
so unlike Linux, don't expect the container-side port to match. Which cell hosts the instance:

```bash
cf curl "/v3/processes/$APP_GUID/stats" | jq -r '.resources[] | "\(.index) \(.host)"'
```

### Proof C (Windows) — the WinNAT session table on the cell (definitive)

On the Windows cell whose IP matched (`genesis @<env>:cf b ssh <windows-cell>/<uuid>` — the
session is cmd/PowerShell; commands below are PowerShell):

```powershell
Get-NetNatSession | Where-Object {
    $_.InternalDestinationAddress -eq '<REDIS_IP>' -or $_.ExternalDestinationAddress -eq '<REDIS_IP>'
} | Select-Object InternalSourceAddress, InternalSourcePort, ExternalSourceAddress, ExternalSourcePort, ExternalDestinationAddress
```

Read the row as the **full bridge**:
- `InternalSourceAddress` / `InternalSourcePort` = the container IP and port — must equal what
  Proof A showed from inside (`ipconfig` + `LocalPort`);
- `ExternalSourceAddress` / `ExternalSourcePort` = the cell IP and NAT'ed port — must equal the
  peer Redis reported in Proof B.

Same connection seen at all three points; the container IP ties it to the app. (This is
exactly what `windows-wsweep.ps1` automates. Note: container IPs like `172.30.x.x` repeat on
every Windows cell — only the (cell, container IP) pair identifies an instance, which is why
Proof B's cell match matters.)

If the app has several instances and you need to confirm *which* container is which app from
the cell side: `Get-HnsEndpoint | Select-Object IPAddress, VirtualNetworkName, ID` maps IPs to
container endpoints; the container handle prefix equals the first 28 characters of the
instance guid in `cf curl "/v3/processes/$APP_GUID/stats"` (`.resources[].instance_guid` on
newer CAPI) — or simply compare against `ipconfig` from Proof A.

### Finding the WHY on Windows

Inside `cf ssh` (PowerShell), the app lives under `C:\Users\vcap\app`:

```powershell
Select-String -Path C:\Users\vcap\app\* -Pattern '<REDIS_IP>|redis' -List -ErrorAction SilentlyContinue |
  Select-Object Path, LineNumber, Line
# .NET apps -- the usual homes for a pasted address:
Get-ChildItem -Recurse C:\Users\vcap\app -Include appsettings*.json, web.config, *.config |
  Select-String -Pattern '<REDIS_IP>|redis|6379'
Get-ChildItem Env: | Where-Object { $_.Value -match '<REDIS_IP>|redis' }   # env as the process sees it
```

The same why-list applies (droplet-baked config → external config → source → leftover
unbind). For .NET specifically, `appsettings.<Environment>.json` and `connectionStrings` in
`web.config` account for almost all cases.

---

## Finding the WHY (what the app team actually wants to know)

The address+password reached the app *somehow*. Work the list top-down — it's ordered by
how often it's the answer:

1. **Baked into the droplet** — config files shipped with the app. Inside `cf ssh`:
   ```bash
   grep -rlE "$REDIS_IP|redis" /home/vcap/app 2>/dev/null | head
   # Java: also look in exploded config — application*.yml/properties, bootstrap.yml
   ```
2. **Spring Cloud Config Server / external config** — values fetched at boot, invisible to
   every CF scan. Clues: `cf env "$APP"` shows a config-server URI / `SPRING_CLOUD_CONFIG_*`;
   `bootstrap.yml` in the droplet names a config repo. The Redis host then lives in the
   **config repo**, and that's what must change at migration.
3. **Inherited/copied code** — the connection string is in the app's source (or a shared
   internal library's defaults). Homework for the team: search their repo for the IP, the
   service name, or `6379`.
4. **A leftover** — the app once had a binding to this Redis; someone unbound it but the
   address had been copied into config first. The credentials still work because the shared
   password was never rotated. (Check: `cf curl "/v3/service_credential_bindings?service_instance_guids=$SI_GUID&per_page=200" | jq -r '.resources[].name'` — who *else* is bound.)
5. **Optional, ops-approval, non-prod only — watch the traffic itself** for 10–20 seconds to
   see *what* the app does with this Redis (key names are usually self-explaining):
   ```bash
   # on the Redis VM; password: sudo grep -h requirepass /var/vcap/jobs/*/config/* 
   RCLI=$(ls /var/vcap/packages/*redis*/bin/redis-cli | head -1)
   timeout 15 $RCLI -a '<pw>' --no-auth-warning MONITOR | grep '<cell-ip>' | head -40
   ```
   MONITOR echoes every command (measurable perf hit, shows key names/values) — short bursts,
   never on prod without sign-off. If `MONITOR` is disabled by hardening (`rename-command`),
   skip.

## Record the session

| # | app | redis | binding? | port (6379 / 16379 TLS) | socket inside (A) | redis-side peer (B) | cell bridge (C) | owning process | why (1–5) | migration action |
|---|-----|-------|----------|--------------------------|-------------------|---------------------|-----------------|----------------|-----------|------------------|
|   |     |       | 0        | ✓ port …          | ✓ cell …            | ✓ / skipped     |                |           |                  |

The **migration action** for a confirmed `unknown` is always team-side: the address lives
somewhere only they can edit (droplet config, config repo, source). Platform side provides
the new Valkey details; the team changes their config in the same window — same playbook as
the `external management` rows.

## Before you book the session — rule out a phantom row

Reports produced by scanner versions before 2026-09-21 could attribute a connection to the
wrong Redis when one Redis IP is a **prefix of another** (`10.237.1.8` vs `10.237.1.84`):
the app really is connected — to the *longer* IP's Redis, which it is bound to — and the
`unknown` row for the shorter IP is a phantom. Tell-tale: Proof A shows a socket to a
*different* Redis IP than the row names. Fix: `git pull`, run `reclassify <env> --path
<base>` (re-sweeps the cells; no Redis re-scan), re-aggregate, and check whether the row
survived before involving the app team.

## Safety notes

- Proofs A–C and the why-steps 1–4 are read-only. Only step 5 (MONITOR) has any impact.
- Connections are long-lived but not eternal: run Proofs A and B in the **same few minutes**,
  or a pool reconnect changes the port and muddies the match.
- If the app shows **no** socket in Proof A: the connection is intermittent (the scan caught
  it live at scan time — see `scans_live/scans_seen` in the aggregated report). Retry when
  the app is busy, or during its batch window (`first_seen`/`last_seen` hint at the rhythm).
