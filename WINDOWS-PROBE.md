# Windows Redis Consumer — Probe Runbook

Identify which Windows apps consume Redis. Windows Diego cells use `winc-nat`, so Redis sees the
**cell** IP (source-NAT), which is why Windows consumers show up as `external` in the main report.
This runbook proves we can recover the real **container IP** on the Windows cell (via the WinNAT
session table) and join it to an app through the global `cfdot` dump.

Everything here is **read-only** except step 1 (which pushes one throwaway test app).

> Replace the placeholders throughout: `<env>` (genesis env), `<win-cell-uuid>`, `<linux-cell-uuid>`,
> `<redis_ip>`, `<redis-service>`. Files come from `git pull` of this repo.

---

## 0. Prereqs

```bash
git pull                              # get windows-probe.ps1 + fixtures-windows/
cf api                                # confirm you're logged in and targeted at the foundation
cf target -o <test-org> -s <test-space>
```

---

## 1. Push a Windows consumer (test fixture)

No Windows Redis consumer exists in the sandbox, so push one. It holds a live TCP socket to a
Redis service from a Windows cell — giving the probe something to see, and us ground truth.

```bash
cf stacks                             # confirm the windows stack name (windows / windows2019)
cd fixtures-windows
# edit manifest.yml: set `services:` to a real redis service instance (<redis-service>)
cf push -f manifest.yml
cf logs rcd-fix-win-bind --recent     # expect: "fixture: holding a socket to <ip>:<port>"
cd ..
```

If it won't stage/start: bump `memory` to `1G` in the manifest, and re-check the `stack:` name.

---

## 2. Find which Windows cell it landed on + its Redis IP

```bash
guid=$(cf app rcd-fix-win-bind --guid); echo "app_guid=$guid"
cf curl "/v3/apps/$guid/processes/web/stats" | grep -Eo '"host":"[^"]+"'   # cell IP
cf env rcd-fix-win-bind | grep -iE 'host|port'                            # redis IP:port

genesis @<env>:cf b vms | grep -i windows        # map the cell IP -> windows2019-cell/<uuid>
```

---

## 3. Run the probe on that cell

```bash
genesis @<env>:cf b scp windows-probe.ps1 windows2019-cell/<win-cell-uuid>:C:/Windows/Temp/rcd.ps1
genesis @<env>:cf b ssh windows2019-cell/<win-cell-uuid> -c 'powershell -ExecutionPolicy Bypass -File C:/Windows/Temp/rcd.ps1 <redis_ip>'
```

(If scp rejects `C:/Windows/Temp/...`, use a bare `rcd.ps1` target and adjust the `-File` path.)

---

## 4. Read the output

Look for a `natsess_sample` / `natmap` line. The WinNAT session is the answer — it maps the
container to the Redis:

```
InternalSourceAddress      : 172.30.2.4        <- CONTAINER IP  (what we need)
InternalDestinationAddress : <redis_ip>        <- Redis
ExternalSourceAddress      : <cell_ip>         <- what Redis sees (why it looked "external")
```

If the app is idle at probe time you'll see 0 sessions — make sure it's running first.

---

## 5. Verify the cfdot join (does the container IP resolve to the app?)

cfdot only runs on **Linux** cells, but its BBS data is foundation-global (includes Windows LRPs),
so query it from any Linux cell.

> **Do NOT pipe `bosh ssh` stdout into a local file** — `bosh ssh` prefixes every line with
> `<instance>: stdout | …`, so the file won't be valid JSON. Instead write the JSON to a file
> **on the cell** (the redirect runs in the remote shell, before bosh ssh decorates anything),
> then scp that clean file back — exactly what the tool's `resolve` step does.

```bash
genesis @<env>:cf b vms | grep -iE 'diego.*cell' | grep -vi windows    # pick a linux cell
genesis @<env>:cf b scp redis-consumer-discovery.sh <linux-cell-uuid>:/tmp/rcd.sh

# run cfdot ON the cell -> clean JSON file there (no bosh-ssh line prefixes)
genesis @<env>:cf b ssh <linux-cell-uuid> -c 'sudo bash /tmp/rcd.sh _worker-cfdot > /tmp/rcd_lrps.json 2>/dev/null; wc -c /tmp/rcd_lrps.json'

# pull the clean file back
genesis @<env>:cf b scp <linux-cell-uuid>:/tmp/rcd_lrps.json /tmp/lrps.json

# is the container IP an LRP instance_address, and does it belong to our app?
jq -c --arg g "$guid" '.. | objects | select(has("instance_guid") and has("process_guid"))
  | {pg:.process_guid, ia:(.instance_address // .address)} | select(.ia=="172.30.2.4")' /tmp/lrps.json
```

(If you already captured a decorated file, salvage it with:
`sed -n 's/^[^|]*stdout | //p' /tmp/lrps.json > /tmp/lrps.clean.json`)

- **Prints an object whose `pg` starts with `$guid`** → the join works with existing machinery;
  the Windows sweep worker can be built (`Get-NetNatSession` → `container_ip → redis_ip`, joined via
  `instance_address`).
- **Nothing / a different address** → Windows records the cell IP instead; we pivot to the HNS
  `SharedContainers` → container-handle → `instance_guid` join.

---

## Teardown

```bash
cf delete rcd-fix-win-bind -f
# if you made a service key for the env variant: cf delete-service-key <redis-service> <key> -f
```
