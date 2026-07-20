#!/usr/bin/env bash
# redis-consumer-discovery.sh  (single-file tool)
#
# Discover which CF apps consume each Blacksmith-managed redis, and HOW
# (cf-bind / static-env / unknown / external), for the redis->valkey migration.
# Traces from the redis side -> diego cell -> app, so it also finds consumers
# that have NO cf binding / env / manifest (invisible to config scans).
#
# READ-ONLY everywhere: ss without -K, cf curl GETs, cfdot reads. Run from the
# bastion. The SAME file also runs as the on-host worker (scp'd to redis VM/cell).
#
# Usage:
#   redis-consumer-discovery.sh <subcommand> <env> [output-dir] [flags]
#
#   <env>         genesis env name; a trailing ".yml" is stripped.
#   [output-dir]  where intermediate/output files go; default = current dir.
#
# genesis access model (do NOT hardcode deployment names; note the leading @):
#   genesis @<env>    b <args>   == bosh -e <env>             <args>   (director level; redis via -d)
#   genesis @<env>:cf b <args>   == bosh -e <env> -d <env>-cf <args>   (CF / diego cells)
#
# Subcommands:
#   preflight <env> [out] [--redis <dep>] [--cell <group/idx>]
#   inventory | census --redis <dep> | sweep --cell <inst> | resolve | classify | report   (built stepwise)
set -uo pipefail

# ---- arg parse: <subcommand> <env> [output-dir] [--redis d] [--cell i] ----
SUB="${1:-}"; shift || true
[ -z "$SUB" ] && { echo "usage: $(basename "$0") <subcommand> <env> [output-dir] [--redis <dep>] [--cell <group/idx>]"; exit 1; }
ENV="${1:-}"; shift || true
[ -z "$ENV" ] && { echo "ERROR: <env> is required"; exit 1; }
ENV="${ENV#@}"; ENV="${ENV%.yml}"                   # normalize: strip leading @ and trailing .yml
OUT="."
if [ "${1:-}" ] && [ "${1:0:1}" != "-" ]; then OUT="$1"; shift; fi
REDIS_DEP=""; CELL_INSTANCE="diego-cell/0"
while [ "${1:-}" ]; do
  case "$1" in
    --redis) REDIS_DEP="${2:-}"; shift 2 ;;
    --cell)  CELL_INSTANCE="${2:-}"; shift 2 ;;
    *) echo "ERROR: unknown arg '$1'"; exit 1 ;;
  esac
done
mkdir -p "$OUT"

# ---- genesis helpers ----
g_dir(){ genesis "@$ENV"    b "$@"; }               # genesis @<env> b ...     (director; add -d for redis)
g_cf(){  genesis "@$ENV:cf" b "$@"; }               # genesis @<env>:cf b ...  (CF / diego cells)
line(){ printf '\n=== %s ===\n' "$1"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight ---
# NOTE: remote commands run via `... ssh <inst> -c '<cmd>'` MUST avoid double-quotes
# and parentheses -- they do not survive the genesis->bosh->ssh layering (the remote
# shell sees a bare '('). Keep remote commands to simple tokens, pipes, ; and redirects.
cmd_preflight(){
  echo "env=$ENV  output=$OUT"

  line "0.a  discover redis deployments  (pick one -> --redis)"
  g_dir deployments 2>/dev/null | grep -iE 'redis|valkey' | head

  line "0.b  discover the diego-cell instance group name"
  g_cf vms 2>/dev/null | grep -iE 'diego|cell|compute' | head

  if [ -z "$REDIS_DEP" ]; then
    echo; echo ">> re-run with:  preflight $ENV --redis <redis-dep>   for the primitive checks"; return 0
  fi

  # standalone redis = 1 VM, so ssh targets the deployment directly (no instance slug).
  # scp DOES need an instance target -> parse a real UUID slug (group/xxxxxxxx-xxxx-...),
  # which can't match the 'Using environment https://...' banner or an IP.
  line "0.0  redis instance slug (only needed for scp)"
  local RI
  RI=$(g_dir -d "$REDIS_DEP" instances 2>/dev/null \
        | grep -oE '[a-z][a-z0-9_-]*/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
  echo "redis instance = ${RI:-<not parsed - ssh still works via -d>}"

  line "0.1  non-interactive ssh + captured stdout (redis; note the instance header)"
  g_dir -d "$REDIS_DEP" ssh -c 'hostname; id -un'

  line "0.2  passwordless sudo on the redis VM (expect: root)"
  g_dir -d "$REDIS_DEP" ssh -c 'sudo whoami'

  line "0.3  scp round-trip (bastion -> VM -> bastion)"
  if [ -n "$RI" ]; then
    local ts; ts=$(date +%s); echo "ping $ts" > "$OUT/pf_test.txt"
    g_dir -d "$REDIS_DEP" scp "$OUT/pf_test.txt" "$RI":/var/vcap/data/pf_test.txt >/dev/null 2>&1
    g_dir -d "$REDIS_DEP" ssh -c 'cat /var/vcap/data/pf_test.txt'
    g_dir -d "$REDIS_DEP" scp "$RI":/var/vcap/data/pf_test.txt "$OUT/pf_back.txt" >/dev/null 2>&1
    diff -q "$OUT/pf_test.txt" "$OUT/pf_back.txt" >/dev/null && echo SCP_ROUNDTRIP_OK || echo SCP_FAIL
  else
    echo "SCP_SKIPPED (no slug parsed); paste output of:  genesis @$ENV b -d $REDIS_DEP instances"
  fi

  line "0.4  cell reachable + tools (expect: root, then 3 paths)"
  g_cf ssh "$CELL_INSTANCE" -c 'sudo whoami; command -v nsenter; command -v lsns; command -v ss'

  line "0.5  cfdot works from a cell and returns JSON (sample)"
  g_cf ssh "$CELL_INSTANCE" -c 'sudo /var/vcap/jobs/cfdot/bin/cfdot actual-lrps 2>&1 | head -c 300'

  line "0.6  cf API + jq (bastion; non-interactive, hard timeout)"
  command -v jq >/dev/null && echo "jq=$(jq --version)" || echo "jq=MISSING"
  cf target 2>&1 | grep -iE 'api endpoint|user|org|not logged' | head -4
  timeout 20 cf curl "/v3/apps?per_page=1" 2>/dev/null | jq '.pagination.total_results' 2>/dev/null

  echo; echo ">> report PASS/FAIL per check + the redis instance/dep and cell group"
}

# ------------------------------------------------- stages (built stepwise) ---
cmd_inventory(){ die "inventory: implemented in the next step (after preflight passes)"; }
cmd_census(){    die "census: implemented after inventory is verified"; }
cmd_sweep(){     die "sweep: implemented after census is verified"; }
cmd_resolve(){   die "resolve: implemented after sweep is verified"; }
cmd_classify(){  die "classify: implemented after resolve is verified"; }
cmd_report(){    die "report: implemented last"; }
_worker_census(){ die "_worker-census: implemented with census"; }
_worker_sweep(){  die "_worker-sweep: implemented with sweep"; }

# ------------------------------------------------------------------ dispatch --
case "$SUB" in
  preflight)       cmd_preflight ;;
  inventory)       cmd_inventory ;;
  census)          cmd_census ;;
  sweep)           cmd_sweep ;;
  resolve)         cmd_resolve ;;
  classify)        cmd_classify ;;
  report)          cmd_report ;;
  _worker-census)  _worker_census ;;
  _worker-sweep)   _worker_sweep ;;
  *) echo "ERROR: unknown subcommand '$SUB'"; exit 1 ;;
esac
