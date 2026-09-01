#!/usr/bin/env bash
# aggregate.sh -- fold MULTIPLE scans of the same env into one activity-truth table.
#     bash aggregate.sh <scan-base-dir> [<scan-base-dir> ...]
#     bash aggregate.sh ./np-scan-*            # globs work
# Each base dir is one scan (the --path base holding merged_report.csv; if owners.sh was run
# there, merged_report_owners.csv is preferred automatically).
#
# Purpose: repeated scans answer two questions a single scan can't --
#   1. is an app<->redis pair EVER live, or idle in every scan?  (ever_live)
#   2. the union of all scans so no pair is missed               (every pair kept, flagged)
#
# Output: aggregated_report.csv in the current directory. One row per DISTINCT
# (app_guid, service_instance_guid) pair across ALL scans. Metadata/owners come from the
# most recent scan containing the pair. Pure file processing -- no env access needed.
set -uo pipefail

[ $# -ge 1 ] || { echo "usage: bash aggregate.sh <scan-base-dir> [more ...]"; exit 1; }

# collect one report file per scan dir, tagged with its mtime for ordering
list=$(mktemp)
for d in "$@"; do
  f=""
  [ -s "$d/merged_report_owners.csv" ] && f="$d/merged_report_owners.csv"
  [ -z "$f" ] && [ -s "$d/merged_report.csv" ] && f="$d/merged_report.csv"
  [ -z "$f" ] && [ -f "$d" ] && f="$d"                       # a csv passed directly
  [ -z "$f" ] && { echo "WARN: no merged_report(.owners).csv in '$d' - skipped" >&2; continue; }
  m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
  printf '%s\t%s\n' "$m" "$f" >> "$list"
done
[ -s "$list" ] || { echo "ERROR: no usable reports"; rm -f "$list"; exit 1; }

files=$(sort -n "$list" | cut -f2)          # oldest -> newest (newest wins for metadata)
rm -f "$list"
n=$(printf '%s\n' "$files" | grep -c .)
echo "aggregate: $n scan(s), oldest -> newest:"
printf '%s\n' "$files" | sed 's/^/  /'

# shellcheck disable=SC2086
printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 awk '
BEGIN { FS=","; OFS="," }
FNR==1 {
  fileidx++
  # scan label = the base dir name of the report
  lbl=FILENAME; sub(/\/[^\/]*$/, "", lbl); sub(/^.*\//, "", lbl); if (lbl=="") lbl=FILENAME
  label[fileidx]=lbl
  hasown = ($0 ~ /org_managers/) ? 1 : 0
  next
}
{
  gsub(/\r$/, "")
  if ($4=="" || $12=="" || $12=="?") next          # need both key halves
  key=$4 SUBSEP $12
  if (!(key in first)) { first[key]=label[fileidx]; order[++np]=key }
  seen[key]++; last[key]=label[fileidx]; lastidx[key]=fileidx
  if ($15=="yes") live[key]++
  if (!((key SUBSEP $5) in mset)) { mset[key SUBSEP $5]=1
    methods[key]=(methods[key]=="") ? $5 : methods[key] "|" $5 }
  meta[key]=$1 OFS $2 OFS $3 OFS $4 OFS $5 OFS $6 OFS $7 OFS $8 OFS $9 OFS $10 OFS $11 OFS $12 OFS $13 OFS $14
  if (hasown) own[key]=$17 OFS $18 OFS $19
}
END {
  print "app_name,space,org,app_guid,method,static_ref,static_ref_target," \
        "redis_service_name,redis_service_space,redis_service_org,redis_deployment," \
        "service_instance_guid,platform,deployment_exists," \
        "scans_seen,scans_live,ever_live,in_latest,first_seen,last_seen,methods_seen," \
        "org_managers,space_owners,owner_source"
  for (i=1; i<=np; i++) {
    k=order[i]
    ev=(live[k]>0) ? "yes" : "no"
    il=(lastidx[k]==fileidx) ? "yes" : "no"
    o=(k in own) ? own[k] : OFS OFS
    ml=(index(methods[k],"|")>0) ? methods[k] : ""
    print meta[k], seen[k], live[k]+0, ev, il, first[k], last[k], ml, o
    if (ev=="yes") nlive++; else nidle++
    if (il=="no") ngone++
    if (ml!="") nflip++
  }
  printf "aggregate: %d distinct pair(s): %d ever-live, %d never-live (idle in every scan)\n", np, nlive+0, nidle+0 > "/dev/stderr"
  printf "aggregate: %d pair(s) missing from the LATEST scan (unbound since? check before dropping)\n", ngone+0 > "/dev/stderr"
  printf "aggregate: %d pair(s) changed classification across scans (methods_seen column)\n", nflip+0 > "/dev/stderr"
}' > aggregated_report.csv

echo "aggregate: wrote aggregated_report.csv"