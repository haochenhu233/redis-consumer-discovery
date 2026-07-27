# fixtures-windows — a Windows Redis consumer for probe/worker testing

The SBX has no Windows Redis consumer, so we push our own. It holds a live TCP connection to a
redis service from a Windows Diego cell — giving the probe something to detect **and** giving us
ground truth (we know this app → this redis, and which cell it runs on).

`keepalive.ps1` is the pure-PowerShell analog of the Linux `fixtures/run.sh` (no redis client,
no route needed — just an open socket). Non-TLS redis only.

## Push it

```
cf stacks                                   # confirm the windows stack name (windows / windows2019)
cf target -o <test-org> -s <test-space>
# edit manifest.yml: put your redis service instance name in `services:` (or use the env: variant)
cd fixtures-windows
cf push -f manifest.yml
cf logs rcd-fix-win-bind --recent           # expect: "fixture: holding a socket to <ip>:<port>"
```

If it won't stage/start: bump `memory` to 1G, and double-check the `stack:` name and that
`binary_buildpack` supports it on this foundation.

## Find which Windows cell it landed on (to target the probe + ground truth)

```
guid=$(cf app rcd-fix-win-bind --guid)
cf curl "/v3/apps/$guid/processes/web/stats" | grep -Eo '"host":"[^"]+"'   # instances[].host = cell IP
```
Map that cell IP to a Windows cell slug with `genesis @<env>:cf b vms | grep -i windows`, then run
`../windows-probe.ps1` against that cell (see the probe steps). The redis IP to pass the probe is
the one this app is bound to / points at.

## Teardown

```
cf delete rcd-fix-win-bind -f
# if you created a service key for the env variant: cf delete-service-key <svc> <key> -f
```
