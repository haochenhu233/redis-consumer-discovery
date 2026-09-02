#!/usr/bin/env bash
# aggregate.sh -- fold MULTIPLE scans of the same env into one activity-truth table.
#
# Primary form (scan archive tree:  <top>/<day>/<time-slot>/<env>/merged_report*.csv):
#     bash aggregate.sh --path <top> --env <env-name>
#         walks EVERY <day>/<time-slot> under <top>, but inside each slot takes ONLY the
#         given env's directory -> aggregates all its merged reports.
#         Output: aggregated_report_<env>.csv (current directory).
#
# Also accepted (explicit list of scan base dirs):
#     bash aggregate.sh <scan-base-dir> [more ...]        # output: aggregated_report.csv
#
# Per scan dir the report is merged_report_owners.csv if present, else merged_report.csv.
# Scans are ordered oldest -> newest by file mtime (newest wins for metadata/owners).
#
# Why aggregate: repeated scans answer what one scan can't --
#   1. is an app<->redis pair EVER live, or idle in every scan?  (ever_live)
#   2. the union of all scans so no pair is missed
#
# Pairs are identified by NAMES -- (org,space,app_name) <-> (svc org,space,name) -- which are
# unique per space in CF, so a recreated app/service (new guid, same name) stays the SAME pair;
# the guid change is recorded in the app/service_recreated columns instead of duplicating rows.
# Output split: aggregated_report_*.csv = pairs present in the LATEST scan (with full history);
# dropped_list_*.csv = pairs no longer present (unbound / deleted / renamed) -- nothing lost.
# Pure file processing -- no env access needed (runs in the VDI).
set -uo pipefail

TOP=""; ENVN=""; MODE="list"; DIRS=()
while [ "${1:-}" ]; do
  case "$1" in
    --path) TOP="${2:-}"; shift 2 ;;
    --env)  ENVN="${2:-}"; shift 2 ;;
    -*) echo "ERROR: unknown option '$1'"; exit 1 ;;
    *) DIRS+=("$1"); shift ;;
  esac
done

if [ -n "$TOP" ] || [ -n "$ENVN" ]; then
  [ -n "$TOP" ] && [ -n "$ENVN" ] || { echo "usage: bash aggregate.sh --path <top> --env <env-name>"; exit 1; }
  [ -d "$TOP" ] || { echo "ERROR: no such directory: $TOP"; exit 1; }
  MODE="tree"
  for d in "$TOP"/*/*/"$ENVN"; do
    [ -d "$d" ] && DIRS+=("$d")
  done
  [ ${#DIRS[@]} -gt 0 ] || { echo "ERROR: no '$ENVN' directories found under $TOP/*/*/ -- check --env spelling"; exit 1; }
else
  [ ${#DIRS[@]} -gt 0 ] || { echo "usage: bash aggregate.sh --path <top> --env <env>   |   bash aggregate.sh <scan-dir> [...]"; exit 1; }
fi

# collect one report file per scan dir, tagged with its mtime for ordering
list=$(mktemp)
for d in "${DIRS[@]}"; do
  f=""
  [ -s "$d/merged_report_owners.csv" ] && f="$d/merged_report_owners.csv"
  [ -z "$f" ] && [ -s "$d/merged_report.csv" ] && f="$d/merged_report.csv"
  [ -z "$f" ] && [ -f "$d" ] && f="$d"                       # a csv passed directly
  [ -z "$f" ] && { echo "WARN: no merged_report(.owners).csv in '$d' - skipped" >&2; continue; }
  m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
  printf '%s\t%s\n' "$m" "$f" >> "$list"
done
[ -s "$list" ] || { echo "ERROR: no usable reports"; rm -f "$list"; exit 1; }

files=$(sort -n "$list" | cut -f2)          # oldest -> newest
rm -f "$list"
n=$(printf '%s\n' "$files" | grep -c .)
echo "aggregate: $n scan(s), oldest -> newest:"
printf '%s\n' "$files" | sed 's/^/  /'

OUTCSV="aggregated_report.csv"; DROPCSV="dropped_list.csv"
[ "$MODE" = "tree" ] && { OUTCSV="aggregated_report_${ENVN}.csv"; DROPCSV="dropped_list_${ENVN}.csv"; }

printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 awk -v mode="$MODE" '
BEGIN { FS=","; OFS="," }
FNR==1 {
  fileidx++
  # scan label: tree mode -> "<day>/<time-slot>" (the two levels above the env dir);
  # list mode -> the report,s parent dir name
  m=split(FILENAME, seg, "/")
  if (mode=="tree" && m>=4)      lbl=seg[m-3] "/" seg[m-2]
  else if (m>=2)                 lbl=seg[m-1]
  else                           lbl=FILENAME
  label[fileidx]=lbl
  hasown = ($0 ~ /org_managers/) ? 1 : 0
  next
}
{
  gsub(/\r$/, "")
  if ($1=="" || $4=="") next
  # LOGICAL pair key: names, not guids -- app names are unique per space, service instance
  # names unique per space, so a recreated app/service (new guid, same name) stays the SAME
  # pair instead of duplicating. Guid churn is recorded as app/service_recreated instead.
  appk = $3 SUBSEP $2 SUBSEP $1
  svck = ($8!="" && $8!="?") ? ($10 SUBSEP $9 SUBSEP $8) : ("guid:" $12)   # unresolved name -> fall back to SI guid
  key = appk SUBSEP svck
  if (!(key in first)) { first[key]=label[fileidx]; order[++np]=key }
  seen[key]++; last[key]=label[fileidx]; lastidx[key]=fileidx
  if ($15=="yes") live[key]++
  if (!((key SUBSEP $5) in mset)) { mset[key SUBSEP $5]=1
    methods[key]=(methods[key]=="") ? $5 : methods[key] "|" $5 }
  if (!((key SUBSEP $4) in agset))  { agset[key SUBSEP $4]=1;  ag[key]++ }    # distinct app guids seen
  if ($12!="" && !((key SUBSEP $12) in sgset)) { sgset[key SUBSEP $12]=1; sg[key]++ }  # distinct SI guids seen
  meta[key]=$1 OFS $2 OFS $3 OFS $4 OFS $5 OFS $6 OFS $7 OFS $8 OFS $9 OFS $10 OFS $11 OFS $12 OFS $13 OFS $14
  if (hasown) own[key]=$17 OFS $18 OFS $19
}
END {
  hdr = "app_name,space,org,app_guid,method,static_ref,static_ref_target," \
        "redis_service_name,redis_service_space,redis_service_org,redis_deployment," \
        "service_instance_guid,platform,deployment_exists," \
        "scans_seen,scans_live,ever_live,first_seen,last_seen,methods_seen," \
        "app_recreated,service_recreated,org_managers,space_owners,owner_source"
  print hdr > main
  print hdr > dropped
  for (i=1; i<=np; i++) {
    k=order[i]
    ev=(live[k]>0) ? "yes" : "no"
    o=(k in own) ? own[k] : OFS OFS
    ml=(index(methods[k],"|")>0) ? methods[k] : ""
    ar=(ag[k]>1) ? "yes" : ""
    sr=(sg[k]>1) ? "yes" : ""
    row = meta[k] OFS seen[k] OFS live[k]+0 OFS ev OFS first[k] OFS last[k] OFS ml OFS ar OFS sr OFS o
    if (lastidx[k]==fileidx) { print row > main;    nmain++;  if (ev=="yes") nlive++; else nidle++ }
    else                     { print row > dropped; ndrop++ }
    if (ar=="yes" || sr=="yes") nrec++
  }
  printf "aggregate: %d logical pair(s): %d current (-> main report: %d ever-live, %d never-live)\n", np, nmain+0, nlive+0, nidle+0 > "/dev/stderr"
  printf "aggregate: %d pair(s) not in the latest scan -> dropped list (nothing lost)\n", ndrop+0 > "/dev/stderr"
  printf "aggregate: %d pair(s) had their app or service recreated during the window (app/service_recreated columns)\n", nrec+0 > "/dev/stderr"
}' main="$OUTCSV" dropped="$DROPCSV" /dev/null

echo "aggregate: wrote $OUTCSV (current pairs) and $DROPCSV (pairs no longer present)"