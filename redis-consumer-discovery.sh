#!/usr/bin/env bash
# redis-consumer-discovery.sh  (single-file tool)
#
# Discover which CF apps consume each Blacksmith-managed redis, and HOW
# (cf-bind / static-env / unknown / external), for the redis->valkey migration.
# Traces from the redis side -> diego cell -> app, so it also finds consumers
# that have NO cf binding / env / manifest (invisible to config scans).
#
# READ-ONLY everywhere: ss without -K, cf curl GETs, cfdot reads. Run from the
# bastion. The SAME file also runs as the on-host worker (it scp's itself to the
# redis VM / cell and invokes a _worker-* subcommand there).
#
# Usage:
#   redis-consumer-discovery.sh preflight [redis_dep]
#   redis-consumer-discovery.sh inventory                 (next step)
#   redis-consumer-discovery.sh census   <redis_dep>      (later)
#   redis-consumer-discovery.sh sweep    <cell>           (later)
#   redis-consumer-discovery.sh resolve | classify | report
#
# Config via env vars (override the defaults):
#   ENV=<genesis env>  CELL_DEP=<cf deployment>  CELL_INSTANCE=<group/idx>
#   CFDOT_CMD='<exact cfdot actual-lrps command that works on a cell>'
#   OUT=<dir for intermediate files on the bastion>
set -uo pipefail

ENV="${ENV:-sbx}"
CELL_DEP="${CELL_DEP:-cf}"
CELL_INSTANCE="${CELL_INSTANCE:-diego-cell/0}"
CFDOT_CMD="${CFDOT_CMD:-sudo /var/vcap/jobs/cfdot/bin/cfdot actual-lrps}"
OUT="${OUT:-./out}"

g(){ genesis "$ENV" b "$@"; }          # genesis <env> b ...  (passthrough to bosh)
line(){ printf '\n=== %s ===\n' "$1"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight ---
cmd_preflight(){
  local REDIS_DEP="${1:-${REDIS_DEP:-}}"

  line "0.a  discover redis deployments  (pick one -> REDIS_DEP)"
  g deployments 2>/dev/null | grep -iE 'redis|valkey' | head

  line "0.b  discover the diego-cell instance group name"
  g -d "$CELL_DEP" vms 2>/dev/null | grep -iE 'diego|cell|compute' | head

  if [ -z "$REDIS_DEP" ]; then
    echo; echo ">> re-run as: preflight <redis_dep>   to run the primitive checks"; return 0
  fi

  line "0.1  non-interactive ssh + captured stdout (redis)"
  g -d "$REDIS_DEP" ssh redis/0 -c 'echo HOST=$(hostname); echo WHOAMI=$(id -un)'

  line "0.2  passwordless sudo on the redis VM"
  g -d "$REDIS_DEP" ssh redis/0 -c 'sudo id | grep -o "uid=0(root)" && echo SUDO_OK'

  line "0.3  scp round-trip (bastion -> VM -> bastion)"
  local ts; ts=$(date +%s); echo "ping $ts" > /tmp/pf_test.txt
  g -d "$REDIS_DEP" scp /tmp/pf_test.txt redis/0:/var/vcap/data/pf_test.txt >/dev/null 2>&1
  g -d "$REDIS_DEP" ssh redis/0 -c 'cat /var/vcap/data/pf_test.txt'
  g -d "$REDIS_DEP" scp redis/0:/var/vcap/data/pf_test.txt /tmp/pf_back.txt >/dev/null 2>&1
  diff -q /tmp/pf_test.txt /tmp/pf_back.txt >/dev/null && echo SCP_ROUNDTRIP_OK || echo SCP_FAIL

  line "0.4  cell reachable + tools present (nsenter/lsns/ss)"
  g -d "$CELL_DEP" ssh "$CELL_INSTANCE" -c 'sudo id | grep -o "uid=0(root)"; for t in nsenter lsns ss; do printf "%s=" "$t"; command -v $t || echo MISSING; done'

  line "0.5  cfdot works from a cell and returns JSON (sample)"
  g -d "$CELL_DEP" ssh "$CELL_INSTANCE" -c "$CFDOT_CMD 2>&1 | head -c 300"

  line "0.6  cf API reachable from bastion + jq present"
  command -v jq >/dev/null && echo "jq=$(jq --version)" || echo jq=MISSING
  cf api 2>/dev/null | head -1
  cf curl /v3/apps?per_page=1 2>/dev/null | jq '.pagination.total_results' 2>/dev/null

  echo; echo ">> report PASS/FAIL per check + the 3 discovered values"
}

# ------------------------------------------------- stages (built stepwise) ---
cmd_inventory(){ die "inventory: implemented in the next step (after preflight passes)"; }
cmd_census(){    die "census: implemented after inventory is verified"; }
cmd_sweep(){     die "sweep: implemented after census is verified"; }
cmd_resolve(){   die "resolve: implemented after sweep is verified"; }
cmd_classify(){  die "classify: implemented after resolve is verified"; }
cmd_report(){    die "report: implemented last"; }

# on-host workers (scp'd, run with sudo on the target) --------------------------
_worker_census(){ die "_worker-census: implemented with census"; }
_worker_sweep(){  die "_worker-sweep: implemented with sweep"; }

# ------------------------------------------------------------------ dispatch --
sub="${1:-}"; shift || true
case "$sub" in
  preflight)       cmd_preflight "$@" ;;
  inventory)       cmd_inventory "$@" ;;
  census)          cmd_census    "$@" ;;
  sweep)           cmd_sweep     "$@" ;;
  resolve)         cmd_resolve   "$@" ;;
  classify)        cmd_classify  "$@" ;;
  report)          cmd_report    "$@" ;;
  _worker-census)  _worker_census "$@" ;;
  _worker-sweep)   _worker_sweep  "$@" ;;
  *) echo "usage: $(basename "$0") {preflight [redis_dep]|inventory|census <dep>|sweep <cell>|resolve|classify|report}"; exit 1 ;;
esac
