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
# cell instance slug (group/uuid) for a given cell IP, from the CF deployment vms
cell_slug_for_ip(){ g_cf vms 2>/dev/null | grep -F "$1" \
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

# sweep: for each cell in 02_conns.tsv, resolve its containers' connections to redis
# into (container_ip, CF_INSTANCE_GUID) -> $OUT/03_cellmap.tsv
cmd_sweep(){
  local conns="$OUT/02_conns.tsv"
  [ -s "$conns" ] || die "no census file at $conns; run census first"
  local redis_ips cell_ips
  redis_ips=$(awk -F'\t' 'NR>1{print $3}' "$conns" | sort -u | tr '\n' ' ')
  cell_ips=$(awk -F'\t' 'NR>1{print $5}' "$conns" | sort -u)
  [ -z "${redis_ips// /}" ] && die "no redis IPs in $conns"

  local f="$OUT/03_cellmap.tsv"
  [ -s "$f" ] || printf 'env\tcell_ip\tcell_instance\tcontainer_ip\tinstance_guid\tredis_ip\n' > "$f"

  local cip cslug raw n ccip guid rip
  for cip in $cell_ips; do
    cslug=$(cell_slug_for_ip "$cip")
    [ -z "$cslug" ] && { echo "sweep: no cell instance for $cip (external/NAT?) - skipping"; continue; }
    g_cf scp "$SELF" "$cslug":/tmp/rcd.sh >/dev/null 2>&1 || { echo "sweep: scp to $cslug failed"; continue; }
    local dbg=""; [ -n "${RCD_DEBUG:-}" ] && dbg="DEBUG"
    raw=$(g_cf ssh "$cslug" -c "sudo bash /tmp/rcd.sh _worker-sweep $dbg $redis_ips" 2>/dev/null)
    [ -n "${RCD_DEBUG:-}" ] && printf '%s\n' "$raw" | grep -oE '#DBG#.*'
    n=0
    while IFS=$'\t' read -r ccip guid rip; do
      [ -z "$ccip" ] && continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ENV" "$cip" "$cslug" "$ccip" "$guid" "$rip" >> "$f"
      n=$((n+1))
    done < <(printf '%s\n' "$raw" | grep -oE '#RCD#.*' | cut -f2-)
    echo "sweep: cell $cip ($cslug) -> $n container(s)"
  done
  echo "sweep: results in $f"; column -t -s$'\t' "$f" 2>/dev/null || cat "$f"
}

# resolve: instance_guid (+ container_ip fallback) -> app name/org/space -> $OUT/05_apps.tsv
# Dumps cfdot actual-lrps ONCE from a cell (BBS is global), joins offline, then cf curl.
cmd_resolve(){
  local cm="$OUT/03_cellmap.tsv"
  [ -s "$cm" ] || die "no cellmap at $cm; run sweep first"
  command -v jq >/dev/null || die "jq required on the bastion"

  # 1) dump cfdot actual-lrps from any cell in the cellmap
  local cell; cell=$(awk -F'\t' 'NR>1{print $3; exit}' "$cm")
  [ -z "$cell" ] && die "no cell_instance in $cm"
  echo "resolve: dumping cfdot actual-lrps from $cell ..."
  # remote command uses ONLY shell-safe tokens (no parens/double-quotes/$()) per genesis-ssh constraint
  echo "--- cfdot dump diagnostics (bytes + first stderr lines) ---"
  g_cf ssh "$cell" -c 'sudo /var/vcap/jobs/cfdot/bin/cfdot actual-lrps > /tmp/rcd_lrps.json 2>/tmp/rcd_lrps.err; wc -c /tmp/rcd_lrps.json; echo --STDERR--; head -3 /tmp/rcd_lrps.err'
  echo "----------------------------------------------------------"
  g_cf scp "$cell":/tmp/rcd_lrps.json "$OUT/04_lrps.json" >/dev/null 2>&1 || die "scp cfdot dump failed"
  if [ ! -s "$OUT/04_lrps.json" ]; then
    die "cfdot dump empty. See --STDERR-- above; try the exact cfdot command you used manually and tell me its form (path/subcommand/flags)."
  fi

  # 2) normalize LRPs -> ig<TAB>pg<TAB>instance_address  (format-agnostic)
  jq -rc '.. | objects | select(has("instance_guid") and has("process_guid"))
          | [ .instance_guid, .process_guid, (.instance_address // .address // "") ] | @tsv' \
     "$OUT/04_lrps.json" > "$OUT/04_lrps.tsv" 2>/dev/null
  local lrpn; lrpn=$(wc -l < "$OUT/04_lrps.tsv" | tr -d ' ')
  echo "resolve: parsed $lrpn LRP records"
  [ "$lrpn" -eq 0 ] && die "parsed 0 LRPs; inspect $OUT/04_lrps.json (unexpected cfdot format)"

  # build lookups: ig->pg and ia->pg
  declare -A PG_BY_IG PG_BY_IA
  local ig pg ia
  while IFS=$'\t' read -r ig pg ia; do
    [ -n "$ig" ] && PG_BY_IG["$ig"]="$pg"
    [ -n "$ia" ] && PG_BY_IA["$ia"]="$pg"
  done < "$OUT/04_lrps.tsv"

  # 3) walk cellmap, resolve each container to an app (cache CF API lookups)
  local out="$OUT/05_apps.tsv"
  printf 'env\tredis_ip\tcontainer_ip\tinstance_guid\tprocess_guid\tapp_guid\tapp_name\tspace\torg\n' > "$out"
  declare -A APP_CACHE
  local e cip guid rip cinst cell_ip
  while IFS=$'\t' read -r e cell_ip cinst cip guid rip; do
    [ "$e" = env ] && continue
    [ -z "$e" ] && continue
    pg="${PG_BY_IG[$guid]:-}"
    [ -z "$pg" ] && pg="${PG_BY_IA[$cip]:-}"      # fallback via container IP (NOGUID case)
    local ag name sp org
    if [ -n "$pg" ]; then
      ag="${pg:0:36}"
      if [ -n "${APP_CACHE[$ag]:-}" ]; then
        IFS=$'\t' read -r name sp org <<< "${APP_CACHE[$ag]}"
      else
        local aj sg
        aj=$(timeout 20 cf curl "/v3/apps/$ag" 2>/dev/null)
        name=$(printf '%s' "$aj" | jq -r '.name // "?"' 2>/dev/null)
        sg=$(printf '%s' "$aj" | jq -r '.relationships.space.data.guid // ""' 2>/dev/null)
        sp="?"; org="?"
        if [ -n "$sg" ]; then
          IFS=$'\t' read -r sp org < <(timeout 20 cf curl "/v3/spaces/$sg?include=organization" 2>/dev/null \
            | jq -r '[ (.name // "?"), (.included.organizations[0].name // "?") ] | @tsv' 2>/dev/null)
        fi
        APP_CACHE[$ag]="$name"$'\t'"$sp"$'\t'"$org"
      fi
    else
      ag="?"; name="UNRESOLVED"; sp="?"; org="?"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$e" "$rip" "$cip" "$guid" "${pg:-?}" "$ag" "$name" "$sp" "$org" >> "$out"
  done < "$cm"

  echo "resolve: results in $out"
  column -t -s$'\t' "$out" 2>/dev/null || cat "$out"
}
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
# _worker-sweep <redis_ip...>: RUNS ON a diego cell as root. Read-only.
# For each network namespace with an established connection to a redis IP, emits:
#   #RCD# <container_ip> <instance_guid> <redis_ip>
# instance_guid = CF_INSTANCE_GUID from a process in that netns (NOGUID if scrubbed;
# container_ip is the backup join key).
_worker_sweep(){
  local dbg=""; [ "${1:-}" = DEBUG ] && { dbg=1; shift; }
  local redis_ips="$*"
  declare -A seen
  local nsfile pid ino est nl guid q qino qpid rip cip line total=0
  for nsfile in /proc/[0-9]*/ns/net; do
    pid=${nsfile#/proc/}; pid=${pid%/ns/net}
    ino=$(readlink "$nsfile" 2>/dev/null) || continue
    [ -n "${seen[$ino]:-}" ] && continue
    seen[$ino]=$pid
    total=$((total+1))
    est=$(nsenter -t "$pid" -n ss -Htn state established 2>/dev/null)
    nl=$(printf '%s\n' "$est" | grep -c . )
    # lines mentioning any redis IP (substring match; robust to v4-mapped-v6 format)
    local hitlines=""
    for rip in $redis_ips; do
      [ -z "$rip" ] && continue
      line=$(printf '%s\n' "$est" | grep -F "$rip")
      [ -n "$line" ] && hitlines="$hitlines$line"$'\n'
    done
    local hc; hc=$(printf '%s' "$hitlines" | grep -c . )
    [ -n "$dbg" ] && printf '#DBG#\tns=%s\tpid=%s\test=%s\tredis_hits=%s\n' "$ino" "$pid" "$nl" "$hc"
    [ "$hc" -eq 0 ] && continue
    # this netns talks to redis -> capture the app's instance guid
    guid=$(tr '\0' '\n' < /proc/$pid/environ 2>/dev/null | sed -n 's/^CF_INSTANCE_GUID=//p' | head -1)
    if [ -z "$guid" ]; then
      for q in /proc/[0-9]*/ns/net; do
        qino=$(readlink "$q" 2>/dev/null) || continue
        [ "$qino" = "$ino" ] || continue
        qpid=${q#/proc/}; qpid=${qpid%/ns/net}
        guid=$(tr '\0' '\n' < /proc/$qpid/environ 2>/dev/null | sed -n 's/^CF_INSTANCE_GUID=//p' | head -1)
        [ -n "$guid" ] && break
      done
    fi
    # emit one row per (container_ip, redis_ip); container_ip = the IP on the line that isn't redis
    printf '%s\n' "$hitlines" | grep -c . >/dev/null
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      for rip in $redis_ips; do
        [ -z "$rip" ] && continue
        printf '%s\n' "$line" | grep -qF "$rip" || continue
        cip=$(printf '%s\n' "$line" | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | grep -vFx "$rip" | head -1)
        [ -n "$dbg" ] && printf '#DBG#\tMATCH ns=%s cip=%s rip=%s :: %s\n' "$ino" "${cip:-?}" "$rip" "$line"
        [ -n "$cip" ] && printf '#RCD#\t%s\t%s\t%s\n' "$cip" "${guid:-NOGUID}" "$rip"
      done
    done <<< "$hitlines" | sort -u
  done
  [ -n "$dbg" ] && printf '#DBG#\tnetns_total=%s\n' "$total"
}

# ------------------------------------------------------------------ dispatch --
case "$SUB" in
  preflight)       cmd_preflight ;;
  inventory)       cmd_inventory ;;
  census)          cmd_census ;;
  sweep)           cmd_sweep ;;
  resolve)         cmd_resolve ;;
  classify)        cmd_classify ;;
  report)          cmd_report ;;
  _worker-census)  _worker_census "$@" ;;
  _worker-sweep)   _worker_sweep "$@" ;;
  *) echo "ERROR: unknown subcommand '$SUB'"; exit 1 ;;
esac
