#!/usr/bin/env bash
# redis-consumer-discovery.sh  (single-file tool)
#
# Discover which CF apps consume each Blacksmith-managed redis, and HOW
# (cf-bind / static-ref / unknown / external), for the redis->valkey migration.
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
# Optional hang-protection: only wrap genesis in `timeout` when RCD_SSH_TIMEOUT is explicitly
# set AND a GNU-style timeout exists. Default = direct call (some bastions have BusyBox timeout
# that needs `-t`, or genesis misbehaves off a TTY -- either breaks discovery). Opt in with e.g.
# RCD_SSH_TIMEOUT=120 once you've confirmed `timeout 1 true` works on your bastion.
_gt(){
  if [ -n "${RCD_SSH_TIMEOUT:-}" ] && command -v timeout >/dev/null 2>&1 && timeout 1 true 2>/dev/null; then
    timeout "$RCD_SSH_TIMEOUT" "$@"
  else
    "$@"
  fi
}
g_dir(){ _gt genesis "@$ENV"    b "$@"; }           # genesis @<env> b ...     (director; add -d for redis)
g_cf(){  _gt genesis "@$ENV:cf" b "$@"; }           # genesis @<env>:cf b ...  (CF / diego cells)
line(){ printf '\n=== %s ===\n' "$1"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
# cfdot is provisioned via the diego LOGIN profile (adds it to PATH + exports BBS certs/env).
# A non-interactive `sudo cfdot` runs with secure_path and no profile -> "command not found".
# So cfdot always runs through the scp'd worker via a login shell (bash -lc). Override the
# command with CFDOT=... if a foundation names it differently.
CFDOT="${CFDOT:-cfdot}"
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

  line "0.5  cfdot works from a cell and returns actual-lrps JSON (via login-shell worker)"
  g_cf scp "$SELF" "$CELL_INSTANCE":/tmp/rcd.sh >/dev/null 2>&1 || echo "(scp worker failed)"
  g_cf ssh "$CELL_INSTANCE" -c 'sudo bash /tmp/rcd.sh _worker-cfdot > /tmp/rcd_pf.json 2>/tmp/rcd_pf.err; wc -c /tmp/rcd_pf.json; echo --STDERR--; head -2 /tmp/rcd_pf.err; echo --SAMPLE--; head -c 200 /tmp/rcd_pf.json'

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

# merge-orphaned: combine all per-scan orphaned snapshots -> $OUT/orphaned_merged.tsv
# A redis with 0 consumers in EVERY scan (count == total scans) is flagged truly_orphaned=YES.
cmd_merge_orphaned(){
  local dir="$OUT/orphaned"
  local files; files=$(ls "$dir"/orphaned-*.tsv 2>/dev/null || true)
  [ -z "$files" ] && die "no orphaned scan files in $dir (run some scans first)"
  local nscans; nscans=$(printf '%s\n' "$files" | grep -c .)
  local out="$OUT/orphaned_merged.tsv"
  printf 'redis_deployment\tscans_with_0_consumers\ttotal_scans\ttruly_orphaned\n' > "$out"
  # shellcheck disable=SC2086
  grep -hv '^redis_deployment' $files | cut -f1 | sort | uniq -c \
    | awk -v n="$nscans" '{print $2"\t"$1"\t"n"\t"($1==n?"YES":"no")}' | sort -k4,4r -k2,2rn >> "$out"
  echo "merged $nscans scan(s) -> $out"
  column -t -s$'\t' "$out" 2>/dev/null || cat "$out"
}

# run: full estate sweep -> $OUT/redis_consumers.txt
#   discover all redis/valkey deployments -> census each -> sweep cells -> resolve -> classify -> report
#   RCD_RESUME=1  keeps existing 02/03 files and skips deployments already censused
#   --redis <dep> runs the whole pipeline for a single deployment (testing)
cmd_run(){
  echo "== redis->valkey consumer discovery :: full run =="
  # Redis only by default -- valkey is the migration TARGET, not a consumer source, so it's
  # noise at discovery time. Set RCD_INCLUDE_VALKEY=1 to also sweep valkey (e.g. post-migration).
  local pat='redis'; [ -n "${RCD_INCLUDE_VALKEY:-}" ] && pat='redis|valkey'
  local deps
  if [ -n "$REDIS_DEP" ]; then
    deps="$REDIS_DEP"
  else
    deps=$(g_dir deployments 2>/dev/null \
      | grep -oE '[a-z][a-z0-9_-]*-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
      | grep -iE "$pat" | sort -u)
  fi
  [ -z "$deps" ] && die "no redis deployments found (via genesis @$ENV b deployments)"
  local total; total=$(printf '%s\n' "$deps" | grep -c .)
  echo "discovered $total redis deployment(s)${RCD_INCLUDE_VALKEY:+ (incl. valkey)}"

  [ -z "${RCD_RESUME:-}" ] && rm -f "$OUT/02_conns.tsv" "$OUT/03_cellmap.tsv"

  echo "== phase 1/2: census ALL $total redis (each isolated; failures skip, never abort) =="
  local i=0 d ok=0 fail=0 DEPS=()
  mapfile -t DEPS < <(printf '%s\n' "$deps")           # read into an array first; ssh in the loop
  for d in "${DEPS[@]}"; do                             # would otherwise consume a piped stream
    [ -z "$d" ] && continue
    i=$((i+1))
    if [ -n "${RCD_RESUME:-}" ] && [ -s "$OUT/02_conns.tsv" ] && grep -qF "$d" "$OUT/02_conns.tsv"; then
      echo "[$i/$total] census $d :: SKIP (already censused)"; continue
    fi
    echo "[$i/$total] census $d"
    if ( REDIS_DEP="$d"; cmd_census ); then ok=$((ok+1)); else fail=$((fail+1)); echo "  !! census error for $d (continuing)"; fi
  done
  echo "== census pass: $ok ran, $fail hard-errored (skipped) of $total =="

  # orphaned snapshot: every discovered redis with 0 live connections THIS scan (timestamped).
  # Merge across days (merge-orphaned) to find redis unused in EVERY scan = truly orphaned.
  mkdir -p "$OUT/orphaned"
  local ts; ts=$(date -u +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)
  local ofile="$OUT/orphaned/orphaned-$ts.tsv"
  printf 'redis_deployment\tlive_connections\tscan_utc\n' > "$ofile"
  local norph=0 c
  for d in "${DEPS[@]}"; do
    [ -z "$d" ] && continue
    c=$(awk -F'\t' -v dep="$d" 'NR>1 && $2==dep{n++} END{print n+0}' "$OUT/02_conns.tsv" 2>/dev/null)
    if [ "${c:-0}" -eq 0 ]; then printf '%s\t0\t%s\n' "$d" "$ts" >> "$ofile"; norph=$((norph+1)); fi
  done
  echo "== orphaned this scan: $norph redis with 0 consumers -> $ofile =="

  local nconn=0; [ -s "$OUT/02_conns.tsv" ] && nconn=$(($(wc -l < "$OUT/02_conns.tsv") - 1))
  echo "== census complete: $nconn live connection(s) across $total redis =="
  if [ "$nconn" -le 0 ]; then
    echo "no live client connections found -> nothing to sweep."
    echo "  (all redis idle/orphaned, or consumer apps aren't holding connections - see cf apps/logs & ASGs)"
    return 0
  fi

  echo "== phase 2/2: sweep all diego-cells that appeared, then resolve/classify =="
  cmd_sweep || echo "  !! sweep had errors (continuing)"
  cmd_resolve  || die "resolve failed"
  cmd_classify || die "classify failed"
  cmd_report
  echo; echo "== done :: $OUT/redis_consumers.txt =="
}

# reclassify: re-run phase 2 (sweep -> resolve -> classify -> report) from an EXISTING
# 02_conns.tsv, WITHOUT re-scanning any redis. Use this to re-derive the report after a
# long census (e.g. widened classification, added columns) -- the slow redis census is reused.
# Sweep is parallel (RCD_PAR) so this is fast.
cmd_reclassify(){
  [ -s "$OUT/02_conns.tsv" ] || die "no $OUT/02_conns.tsv to reclassify (run census/run first, or point <output-dir> at a prior scan)"
  local nconn; nconn=$(($(wc -l < "$OUT/02_conns.tsv") - 1))
  echo "== reclassify from existing 02_conns.tsv: $nconn connection(s), no redis re-scan =="
  cmd_sweep || echo "  !! sweep had errors (continuing)"
  cmd_resolve  || die "resolve failed"
  cmd_classify || die "classify failed"
  cmd_report
  echo; echo "== done :: $OUT/redis_consumers.txt =="
}

# census: list live client connections to a redis deployment -> $OUT/02_conns.tsv
# scp's this script to the redis VM and runs _worker-census there (read-only ss).
cmd_census(){
  [ -z "$REDIS_DEP" ] && die "census requires --redis <dep>"
  local slug; slug=$(dep_slug "$REDIS_DEP")
  # orphaned redis (index entry but no BOSH deployment/VM) -> skip gracefully, don't abort a run
  [ -z "$slug" ] && { echo "census: $REDIS_DEP has no instances (orphaned / no deployment) - skipping"; return 0; }
  g_dir -d "$REDIS_DEP" scp "$SELF" "$slug":/tmp/rcd.sh >/dev/null 2>&1 || { echo "census: scp to $slug failed (VM down?) - skipping"; return 0; }
  # tr -d '\r': bosh ssh returns CRLF; strip it so it never enters the data (else IP keys carry \r)
  # </dev/null: bosh ssh reads stdin; without this it eats the caller's loop input (only 1 of N runs)
  local raw; raw=$(g_dir -d "$REDIS_DEP" ssh -c 'sudo bash /tmp/rcd.sh _worker-census' </dev/null 2>/dev/null | tr -d '\r')

  # distinguish worker-ran-but-empty from ssh/worker failure via the sentinel
  if ! printf '%s' "$raw" | grep -q '#RCD-DONE#'; then
    local hint; hint=$(printf '%s' "$raw" | grep -vE '^\s*$' | head -1)
    echo "census: $REDIS_DEP -> worker did not complete (ssh/timeout/perm) - skipping${hint:+  [$hint]}"
    return 0
  fi

  local f="$OUT/02_conns.tsv"
  [ -s "$f" ] || printf 'env\tredis_dep\tredis_ip\tredis_port\tpeer_ip\tpeer_port\n' > "$f"
  local n=0 rip rport pip pport
  while IFS=$'\t' read -r rip rport pip pport; do
    [ -z "$rip" ] && continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ENV" "$REDIS_DEP" "$rip" "$rport" "$pip" "$pport" >> "$f"
    n=$((n+1))
  done < <(printf '%s\n' "$raw" | grep -oE '#RCD#.*' | cut -f2-)

  echo "census: $REDIS_DEP -> $n live connection(s)  (appended to $f)"
  printf '%s\n' "$raw" | grep -oE '#RCD#.*' | cut -f2- | sed 's/^/  redis_ip=/;s/\t/ port=/;s/\t/ peer=/;s/\t/:/' || true
  return 0                                            # ran successfully even if 0 connections
}

# _sweep_one: sweep a SINGLE cell in the background. Writes its rows to its own temp
# file (no lock needed -- one file per cell). scp+ssh are the slow part, so many of
# these run concurrently (bounded by RCD_PAR). Linux-only cell: Windows cells are
# filtered out by the caller (they have no bash/nsenter and only error out).
_sweep_one(){
  local cip="$1" cslug="$2" redis_ips="$3" outfile="$4"
  g_cf scp "$SELF" "$cslug":/tmp/rcd.sh >/dev/null 2>&1 || { echo "sweep: scp to $cslug failed"; return 0; }
  local dbg=""; [ -n "${RCD_DEBUG:-}" ] && dbg="DEBUG"
  local raw; raw=$(g_cf ssh "$cslug" -c "sudo bash /tmp/rcd.sh _worker-sweep $dbg $redis_ips" </dev/null 2>/dev/null | tr -d '\r')
  [ -n "${RCD_DEBUG:-}" ] && printf '%s\n' "$raw" | grep -oE '#DBG#.*'
  local n=0 ccip guid rip
  while IFS=$'\t' read -r ccip guid rip; do
    [ -z "$ccip" ] && continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ENV" "$cip" "$cslug" "$ccip" "$guid" "$rip" >> "$outfile"
    n=$((n+1))
  done < <(printf '%s\n' "$raw" | grep -oE '#RCD#.*' | cut -f2-)
  echo "sweep: cell $cip ($cslug) -> $n container(s)"
}

# sweep: for each cell in 02_conns.tsv, resolve its containers' connections to redis
# into (container_ip, CF_INSTANCE_GUID) -> $OUT/03_cellmap.tsv
# Cells are swept CONCURRENTLY (RCD_PAR at a time, default 8). Windows diego cells are
# skipped -- they have no bash/nsenter, so sweeping them only errors. The cellmap is
# rewritten fresh each run so it is safe to re-run (e.g. `reclassify`) without dupes.
cmd_sweep(){
  local conns="$OUT/02_conns.tsv"
  [ -s "$conns" ] || die "no census file at $conns; run census first"
  local redis_ips cell_ips
  redis_ips=$(awk -F'\t' 'NR>1{print $3}' "$conns" | sort -u | tr '\n' ' ')
  cell_ips=$(awk -F'\t' 'NR>1{print $5}' "$conns" | sort -u)
  if [ -z "${redis_ips// /}" ]; then
    echo "sweep: no live client connections recorded (all redis idle/orphaned, or apps not connected) - nothing to sweep"
    return 0
  fi

  local f="$OUT/03_cellmap.tsv"
  printf 'env\tcell_ip\tcell_instance\tcontainer_ip\tinstance_guid\tredis_ip\n' > "$f"

  # fetch the CF vms table ONCE, then resolve each peer IP -> instance slug offline.
  local vms; vms=$(g_cf vms 2>/dev/null)
  local par="${RCD_PAR:-8}"
  local wdir="$OUT/.sweep"; rm -rf "$wdir"; mkdir -p "$wdir"
  local cip cslug grp vline
  local launched=0 skipped_win=0 skipped_noslug=0
  for cip in $cell_ips; do
    vline=$(printf '%s\n' "$vms" | grep -F "$cip" | head -1)
    cslug=$(printf '%s' "$vline" \
      | grep -oE '[a-z][a-z0-9_-]*/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
    [ -z "$cslug" ] && { echo "sweep: no cell instance for $cip (external/NAT?) - skipping"; skipped_noslug=$((skipped_noslug+1)); continue; }
    grp="${cslug%%/*}"
    case "$grp" in
      *[Ww][Ii][Nn][Dd][Oo][Ww][Ss]*) echo "sweep: $cip ($cslug) is a windows cell - skipping"; skipped_win=$((skipped_win+1)); continue ;;
    esac
    # throttle to RCD_PAR concurrent cells
    while [ "$(jobs -rp | wc -l)" -ge "$par" ]; do sleep 0.3; done
    _sweep_one "$cip" "$cslug" "$redis_ips" "$wdir/$cip.tsv" &
    launched=$((launched+1))
  done
  wait
  cat "$wdir"/*.tsv 2>/dev/null >> "$f"
  echo "sweep: $launched cell(s) swept (par=$par), $skipped_win windows skipped, $skipped_noslug unresolved"
  echo "sweep: results in $f"; column -t -s$'\t' "$f" 2>/dev/null || cat "$f"
}

# resolve: instance_guid (+ container_ip fallback) -> app name/org/space -> $OUT/05_apps.tsv
# Dumps cfdot actual-lrps ONCE from a cell (BBS is global), joins offline, then cf curl.
cmd_resolve(){
  local cm="$OUT/03_cellmap.tsv"
  [ -s "$cm" ] || die "no cellmap at $cm; run sweep first"
  command -v jq >/dev/null || die "jq required on the bastion"

  # 1) dump cfdot actual-lrps from any cell in the cellmap.
  # Header-only cellmap = every peer was external/NAT or a skipped windows cell -> no CF
  # apps to resolve. Emit an empty apps file and return cleanly so classify/report still
  # run and produce an external-only report (instead of aborting the whole pass).
  local cell; cell=$(awk -F'\t' 'NR>1{print $3; exit}' "$cm")
  if [ -z "$cell" ]; then
    printf 'env\tredis_ip\tcontainer_ip\tinstance_guid\tprocess_guid\tapp_guid\tapp_name\tspace\torg\n' > "$OUT/05_apps.tsv"
    echo "resolve: no diego cells in cellmap (all external/NAT or windows) - no apps to resolve"
    return 0
  fi
  echo "resolve: dumping cfdot actual-lrps from $cell ..."
  g_cf scp "$SELF" "$cell":/tmp/rcd.sh >/dev/null 2>&1 || die "scp worker to $cell failed"
  echo "--- cfdot dump diagnostics (bytes + first stderr lines) ---"
  g_cf ssh "$cell" -c 'sudo bash /tmp/rcd.sh _worker-cfdot > /tmp/rcd_lrps.json 2>/tmp/rcd_lrps.err; wc -c /tmp/rcd_lrps.json; echo --STDERR--; head -3 /tmp/rcd_lrps.err'
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
# classify: assign a migration method per resolved app+redis -> $OUT/06_classified.tsv
#   cf-bind    : app has a binding to THIS redis service instance (auto-migrates)
#   static-ref: env-var  : redis appears in the app's environment variables (manifest env: block
#                          or `cf set-env` -- indistinguishable, both land in the CF env store)
#   static-ref: manifest : redis appears elsewhere in the reconstructed manifest (command:,
#                          sidecars:) but NOT in env vars
#   unknown              : app IDENTIFIED, connects, but redis appears nowhere CF can see ->
#                          droplet config file / config-server / copied creds (app-team follow-up)
#   unresolved           : live connection seen but the APP was not identified this scan
#                          (container churned between scan steps, or CF record unreadable) ->
#                          data gap, re-run to resolve; NOT the same as unknown
cmd_classify(){
  local apps="$OUT/05_apps.tsv" conns="$OUT/02_conns.tsv"
  [ -s "$apps" ]  || die "no $apps; run resolve first"
  [ -s "$conns" ] || die "no $conns; run census first"
  command -v jq >/dev/null || die "jq required"

  # redis_ip -> redis_dep (from census)
  declare -A DEP_BY_IP
  local e rd rip rport pip pport
  while IFS=$'\t' read -r e rd rip rport pip pport; do
    [ "$e" = env ] && continue
    rip=${rip//$'\r'/}; rd=${rd//$'\r'/}               # defensive: strip stray CR from older files
    [ -z "$rip" ] && continue
    DEP_BY_IP["$rip"]="$rd"
  done < "$conns"

  local out="$OUT/06_classified.tsv"
  printf 'env\tapp_name\tspace\torg\tmethod\tredis_service_name\tredis_service_space\tredis_service_org\tredis_deployment\tapp_guid\tredis_ip\n' > "$out"
  declare -A SVCINFO
  local cip guid pg ag name sp org dep si svcname svc_space svc_org method man bcount
  while IFS=$'\t' read -r e rip cip guid pg ag name sp org; do
    [ "$e" = env ] && continue; [ -z "$e" ] && continue
    rip=${rip//$'\r'/}; ag=${ag//$'\r'/}; org=${org//$'\r'/}   # defensive: strip stray CR
    [ -z "$rip" ] && continue
    dep="${DEP_BY_IP[$rip]:-?}"
    si=""; [ "${#dep}" -ge 36 ] && si="${dep: -36}"    # last 36 chars = CF service-instance GUID (empty if dep unresolved)

    # redis service instance: name + the space/org IT lives in (cached per service GUID).
    # Comparing these against the app's own space/org reveals cross-space/cross-org access
    # (an app reaching a redis managed in a different space/org).
    svcname="?"; svc_space="?"; svc_org="?"
    if [ -n "$si" ]; then
      if [ -n "${SVCINFO[$si]:-}" ]; then
        IFS=$'\t' read -r svcname svc_space svc_org <<< "${SVCINFO[$si]}"
      else
        local sj ssg
        sj=$(timeout 20 cf curl "/v3/service_instances/$si" 2>/dev/null)
        svcname=$(printf '%s' "$sj" | jq -r '.name // "?"' 2>/dev/null); [ -z "$svcname" ] && svcname="?"
        ssg=$(printf '%s' "$sj" | jq -r '.relationships.space.data.guid // ""' 2>/dev/null)
        if [ -n "$ssg" ]; then
          IFS=$'\t' read -r svc_space svc_org < <(timeout 20 cf curl "/v3/spaces/$ssg?include=organization" 2>/dev/null \
            | jq -r '[ (.name // "?"), (.included.organizations[0].name // "?") ] | @tsv' 2>/dev/null)
          [ -z "$svc_space" ] && svc_space="?"; [ -z "$svc_org" ] && svc_org="?"
        fi
        SVCINFO[$si]="$svcname"$'\t'"$svc_space"$'\t'"$svc_org"
      fi
    fi

    # unresolved: we saw a live connection but never got a usable app identity this scan
    # (container churned between scan steps, or its CF record was unreadable). This is a
    # DATA gap to re-run, NOT "redis is hidden" -- keep it distinct from unknown.
    if [ "$ag" = "?" ] || [ -z "$ag" ] || [ "$name" = "UNRESOLVED" ] || [ "$name" = "?" ]; then
      method="unresolved"
    else
      # 1) binding to THIS instance? (only checkable if we resolved the service GUID)
      bcount=0
      [ -n "$si" ] && bcount=$(timeout 20 cf curl "/v3/service_credential_bindings?app_guids=$ag&service_instance_guids=$si&per_page=1" 2>/dev/null | jq -r '.pagination.total_results // 0' 2>/dev/null)
      if [ "${bcount:-0}" -gt 0 ] 2>/dev/null; then
        method="cf-bind"
      else
        # precise redis/valkey signals (anchored to keep false positives low):
        #   - the redis IP; the deployment name (.bosh DNS) and service-instance GUID
        #   - a redis://|rediss://|valkey://|valkeys:// URL (incl. TLS)
        #   - a REDIS*/VALKEY* host/url/endpoint/server/node/port key
        local pat="${rip//./\\.}|(redis|valkey)s?://|(REDIS|VALKEY)[_A-Z0-9]*(HOST|HOSTNAME|URL|URI|ADDR|ENDPOINT|SERVER|NODE|PORT)"
        [ "$dep" != "?" ] && [ -n "$dep" ] && pat="$pat|${dep}"
        [ -n "$si" ] && pat="$pat|${si}"          # service-instance GUID: 36-char, very low false-positive
        # 2) in the app's ENV VARS? (manifest env: block or `cf set-env`) -> env-var
        if timeout 20 cf curl "/v3/apps/$ag/environment_variables" 2>/dev/null | grep -qiE "$pat" 2>/dev/null; then
          method="static-ref: env-var"
        # 3) elsewhere in the reconstructed manifest (command:, sidecars:), not in env -> manifest
        elif timeout 20 cf curl "/v3/apps/$ag/manifest" 2>/dev/null | grep -qiE "$pat" 2>/dev/null; then
          method="static-ref: manifest"
        else
          method="unknown"
        fi
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$e" "$name" "$sp" "$org" "$method" "$svcname" "$svc_space" "$svc_org" "$dep" "$ag" "$rip" >> "$out"
  done < "$apps"

  echo "classify: results in $out"
  column -t -s$'\t' "$out" 2>/dev/null || cat "$out"
}

# report: final CSV (.txt). Dedups to one row per (app, redis). Adds EXTERNAL consumers
# (census peers whose IP is not any diego cell) as method=external.
cmd_report(){
  local cls="$OUT/06_classified.tsv" conns="$OUT/02_conns.tsv" cm="$OUT/03_cellmap.tsv"
  [ -s "$cls" ] || die "no $cls; run classify first"
  local out="$OUT/redis_consumers.txt"
  echo "app_name,space,org,method,redis_service_name,redis_service_space,redis_service_org,redis_deployment" > "$out"

  # resolved rows, deduped by (app_guid,redis_deployment)
  awk -F'\t' 'NR>1 && $10!="" {
      key=$10 SUBSEP $9; if (seen[key]++) next;
      print $2","$3","$4","$5","$6","$7","$8","$9 }' "$cls" >> "$out"

  # external consumers: census peer IPs not present as a cell in the cellmap.
  # Fill the redis service name/space/org from the classified rows (keyed by deployment)
  # so external rows still show which service -- and which space/org -- was reached.
  if [ -s "$conns" ] && [ -s "$cm" ]; then
    local cellips; cellips=$(awk -F'\t' 'NR>1{print $2}' "$cm" | sort -u)
    awk -F'\t' -v cells="$cellips" '
      BEGIN{ n=split(cells,a,"\n"); for(i=1;i<=n;i++) C[a[i]]=1 }
      FNR==NR { if (FNR>1 && $9!="") { svc[$9]=$6; ssp[$9]=$7; sorg[$9]=$8 } next }   # classified: dep -> svc info
      FNR==1 { next }                                                                # conns header
      $5!="" && !($5 in C) {
        key=$5 SUBSEP $2; if (seen[key]++) next;
        print "EXTERNAL(" $5 "),,,external," svc[$2] "," ssp[$2] "," sorg[$2] "," $2 }' "$cls" "$conns" >> "$out"
  fi

  echo "report: final CSV in $out"
  echo; cat "$out"
}

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
  echo "#RCD-DONE#"                                   # sentinel: proves the worker actually ran
}
# _worker-sweep <redis_ip...>: RUNS ON a diego cell as root. Read-only.
# For each network namespace with an established connection to a redis IP, emits:
#   #RCD# <container_ip> <instance_guid> <redis_ip>
# instance_guid = CF_INSTANCE_GUID from a process in that netns (NOGUID if scrubbed;
# container_ip is the backup join key).
# _worker-cfdot: RUNS ON a diego cell. Emits `cfdot actual-lrps` JSON to stdout.
# Uses a LOGIN shell so the diego cfdot profile (PATH + BBS certs/env) is sourced --
# this is what makes cfdot resolvable, exactly as in an interactive bosh ssh session.
_worker_cfdot(){
  local c="${1:-cfdot}"
  if command -v "$c" >/dev/null 2>&1; then "$c" actual-lrps; return $?; fi
  bash -lc "$c actual-lrps"                          # login shell sources /etc/profile.d/*
}

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
  run)             cmd_run ;;
  reclassify)      cmd_reclassify ;;
  merge-orphaned)  cmd_merge_orphaned ;;
  inventory)       cmd_inventory ;;
  census)          cmd_census ;;
  sweep)           cmd_sweep ;;
  resolve)         cmd_resolve ;;
  classify)        cmd_classify ;;
  report)          cmd_report ;;
  _worker-census)  _worker_census "$@" ;;
  _worker-sweep)   _worker_sweep "$@" ;;
  _worker-cfdot)   _worker_cfdot "$@" ;;
  *) echo "ERROR: unknown subcommand '$SUB'"; exit 1 ;;
esac
