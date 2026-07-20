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

# ---- arg parse ----
# orchestrator (on bastion):  <subcommand> <env> [output-dir] [--redis d] [--cell i]
# worker (scp'd to a host, no <env>):  _worker-census | _worker-sweep
SUB="${1:-}"; shift || true
[ -z "$SUB" ] && { echo "usage: $(basename "$0") <subcommand> <env> [output-dir] [--redis <dep>] [--cell <group/idx>]"; exit 1; }
ENV=""; OUT="."; REDIS_DEP=""; CELL_INSTANCE="diego-cell/0"; SELF=""
case "$SUB" in
  _worker-*) : ;;                                   # workers run on-host; no <env>/flags
  *)
    ENV="${1:-}"; shift || true
    [ -z "$ENV" ] && { echo "ERROR: <env> is required"; exit 1; }
    ENV="${ENV#@}"; ENV="${ENV%.yml}"               # normalize: strip leading @ and trailing .yml
    if [ "${1:-}" ] && [ "${1:0:1}" != "-" ]; then OUT="$1"; shift; fi
    while [ "${1:-}" ]; do
      case "$1" in
        --redis) REDIS_DEP="${2:-}"; shift 2 ;;
        --cell)  CELL_INSTANCE="${2:-}"; shift 2 ;;
        *) echo "ERROR: unknown arg '$1'"; exit 1 ;;
      esac
    done
    mkdir -p "$OUT"
    SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
    ;;
esac

# ---- genesis helpers ----
g_dir(){ genesis "@$ENV"    b "$@"; }               # genesis @<env> b ...     (director; add -d for redis)
g_cf(){  genesis "@$ENV:cf" b "$@"; }               # genesis @<env>:cf b ...  (CF / diego cells)
line(){ printf '\n=== %s ===\n' "$1"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
# group/uuid instance slug of a deployment (ignores the 'Using ... https://' banner)
dep_slug(){ g_dir -d "$1" instances 2>/dev/null \
  | grep -oE '[a-z][a-z0-9_-]*/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1; }

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

  line "0.3  scp round-trip (bastion -> VM:/tmp -> bastion)"
  if [ -n "$RI" ]; then
    local ts; ts=$(date +%s); echo "ping $ts" > "$OUT/pf_test.txt"
    g_dir -d "$REDIS_DEP" scp "$OUT/pf_test.txt" "$RI":/tmp/pf_test.txt || echo "(upload scp errored)"
    g_dir -d "$REDIS_DEP" ssh -c 'cat /tmp/pf_test.txt'
    g_dir -d "$REDIS_DEP" scp "$RI":/tmp/pf_test.txt "$OUT/pf_back.txt" || echo "(download scp errored)"
    diff -q "$OUT/pf_test.txt" "$OUT/pf_back.txt" >/dev/null && echo SCP_ROUNDTRIP_OK || echo SCP_FAIL
  else
    echo "SCP_SKIPPED (no slug parsed); paste output of:  genesis @$ENV b -d $REDIS_DEP instances"
  fi

  line "0.4  cell reachable + tools (expect: root, then 3 paths)"
  g_cf ssh "$CELL_INSTANCE" -c 'sudo whoami; command -v nsenter; command -v lsns; command -v ss'

  line "0.5  cfdot works from a cell and returns JSON (sample)"
  g_cf ssh "$CELL_INSTANCE" -c 'sudo /var/vcap/jobs/cfdot/bin/cfdot actual-lrps 2>&1 | head -c 300'

  line "0.6  cf API + jq (bastion; non-interactive, hard timeout)"
  if command -v jq >/dev/null; then echo "jq=OK $(jq --version)"; else echo "jq=MISSING"; fi
  if cf target >/dev/null 2>&1; then
    echo "cf-login=OK"; cf target 2>/dev/null | grep -iE 'api endpoint|user'
  else
    echo "cf-login=FAIL (run: cf login / cf target)"
  fi
  local n; n=$(timeout 20 cf curl "/v3/apps?per_page=1" 2>/dev/null | jq -r '.pagination.total_results // "ERR"' 2>/dev/null)
  echo "apps-total=${n:-ERR}"
  { [ -n "$n" ] && [ "$n" != "ERR" ]; } && echo CF_API_OK || echo CF_API_FAIL

  echo; echo ">> report PASS/FAIL per check + the redis instance/dep and cell group"
}

# ------------------------------------------------- stages (built stepwise) ---
cmd_inventory(){ die "inventory: implemented in a later step"; }

# census: list live client connections to a redis deployment -> $OUT/02_conns.tsv
# scp's this script to the redis VM and runs _worker-census there (read-only ss).
cmd_census(){
  [ -z "$REDIS_DEP" ] && die "census requires --redis <dep>"
  local slug; slug=$(dep_slug "$REDIS_DEP")
  [ -z "$slug" ] && die "could not parse instance slug for '$REDIS_DEP' (run: genesis @$ENV b -d $REDIS_DEP instances)"
  g_dir -d "$REDIS_DEP" scp "$SELF" "$slug":/tmp/rcd.sh >/dev/null 2>&1 || die "scp worker to $slug failed"
  local raw; raw=$(g_dir -d "$REDIS_DEP" ssh -c 'sudo bash /tmp/rcd.sh _worker-census' 2>/dev/null)

  local f="$OUT/02_conns.tsv"
  [ -s "$f" ] || printf 'env\tredis_dep\tredis_ip\tredis_port\tpeer_ip\tpeer_port\n' > "$f"
  local n=0 rip rport pip pport
  while IFS=$'\t' read -r rip rport pip pport; do
    [ -z "$rip" ] && continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ENV" "$REDIS_DEP" "$rip" "$rport" "$pip" "$pport" >> "$f"
    n=$((n+1))
  done < <(printf '%s\n' "$raw" | grep -oE '#RCD#.*' | cut -f2-)

  echo "census: $REDIS_DEP -> $n live connection(s)  (appended to $f)"
  printf '%s\n' "$raw" | grep -oE '#RCD#.*' | cut -f2- | sed 's/^/  redis_ip=/;s/\t/ port=/;s/\t/ peer=/;s/\t/:/'
}

cmd_sweep(){     die "sweep: implemented after census is verified"; }
cmd_resolve(){   die "resolve: implemented after sweep is verified"; }
cmd_classify(){  die "classify: implemented after resolve is verified"; }
cmd_report(){    die "report: implemented last"; }

# _worker-census: RUNS ON the redis VM as root. Read-only. Emits #RCD#-tagged TSV:
#   #RCD# <redis_ip> <redis_port> <peer_ip> <peer_port>
# Kernel ss (immune to rename-command hardening). Finds the real port(s) incl TLS.
_worker_census(){
  local ports p
  ports=$(ss -Htnlp 2>/dev/null | grep -iE 'redis|valkey' | grep -oE ':[0-9]+' | tr -d ':' | sort -un)
  [ -z "$ports" ] && ports=$(grep -REhoE '^(port|tls-port) +[0-9]+' /var/vcap/jobs/*/config/* 2>/dev/null | grep -oE '[0-9]+$' | sort -un)
  for p in $ports; do
    [ "$p" = 0 ] && continue
    ss -Htn state established "sport = :$p" 2>/dev/null | awk -v p="$p" '
      NF>=2 { loc=$(NF-1); peer=$NF; li=index(loc,":"); pi=index(peer,":");
              if (li>0 && pi>0)
                printf "#RCD#\t%s\t%s\t%s\t%s\n", substr(loc,1,li-1), p, substr(peer,1,pi-1), substr(peer,pi+1) }'
  done
}
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
