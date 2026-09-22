#!/usr/bin/env bash
# compare-reports.sh -- diff two merged reports (e.g. before/after a scanner fix or re-scan).
#     bash compare-reports.sh <old-merged_report.csv> <new-merged_report.csv> [--out <dir>]
# Works on merged_report.csv, merged_report_owners.csv, or aggregated_report_*.csv (first 16
# columns are the same). Rows are matched as LOGICAL pairs by names -- (org,space,app) <->
# (svc org,space,svc name) -- so recreated apps/services still line up.
#
# Output (in --out, default ./compare-<timestamp>/):
#   summary.txt            counts per bucket + hazard/unknown deltas
#   removed.csv            pairs only in OLD  (phantoms / false rows that the fix dropped)
#   added.csv              pairs only in NEW  (consumers the old scan MISSED)
#   changed.csv            same pair, different method/static_ref/target/live/deployment/source
#                          (old and new values side by side)
#   hazards-cleared.csv    was cf-bind + static_ref, now not  -> false hazards (do NOT contact)
#   hazards-new.csv        newly flagged hazards
# Pure file processing; no environment access.
set -uo pipefail
OLD=""; NEW=""; OUT=""
while [ "${1:-}" ]; do
  case "$1" in --out) OUT="${2:-}"; shift 2;; -*) echo "unknown option $1"; exit 1;;
    *) if [ -z "$OLD" ]; then OLD="$1"; elif [ -z "$NEW" ]; then NEW="$1"; fi; shift;; esac
done
[ -s "${OLD:-}" ] && [ -s "${NEW:-}" ] || { echo "usage: bash compare-reports.sh <old.csv> <new.csv> [--out dir]"; exit 1; }
OUT="${OUT:-./compare-$(date -u +%Y%m%dT%H%M%SZ)}"; mkdir -p "$OUT"

# cols: 1 app 2 space 3 org 4 app_guid 5 method 6 static_ref 7 static_ref_target 8 svc_name
#       9 svc_space 10 svc_org 11 redis_deployment 12 si_guid 13 platform 14 deployment_exists
#       15 live_connection 16 source
awk -v out="$OUT" '
BEGIN { FS=","; OFS="," }
function key(   s) { s = ($8!="" && $8!="?") ? $10 SUBSEP $9 SUBSEP $8 : "guid:" $12; return $3 SUBSEP $2 SUBSEP $1 SUBSEP s }
function core()   { return $1 OFS $2 OFS $3 OFS $4 OFS $5 OFS $6 OFS $7 OFS $8 OFS $9 OFS $10 OFS $11 OFS $12 OFS $13 OFS $14 OFS $15 OFS $16 }
function hazard() { return ($5=="cf-bind" && $6!="") ? 1 : 0 }
FNR==1 { file++; if (file==1) hdr=$1 OFS $2 OFS $3 OFS $4 OFS $5 OFS $6 OFS $7 OFS $8 OFS $9 OFS $10 OFS $11 OFS $12 OFS $13 OFS $14 OFS $15 OFS $16; next }
{ gsub(/\r$/,""); if ($1=="") next; k=key() }
file==1 { old[k]=core(); om[k]=$5; osr[k]=$6; ost[k]=$7; olv[k]=$15; ode[k]=$14; oso[k]=$16; ohz[k]=hazard(); oorder[++no]=k; next }
file==2 { new[k]=core(); nm[k]=$5; nsr[k]=$6; nst[k]=$7; nlv[k]=$15; nde[k]=$14; nso[k]=$16; nhz[k]=hazard(); norder[++nn]=k }
END {
  print hdr > (out "/removed.csv"); print hdr > (out "/added.csv")
  print "what_changed," hdr ",NEW:method,NEW:static_ref,NEW:static_ref_target,NEW:live_connection,NEW:deployment_exists,NEW:source" > (out "/changed.csv")
  print hdr > (out "/hazards-cleared.csv"); print hdr > (out "/hazards-new.csv")
  for (i=1;i<=no;i++) { k=oorder[i]; if (!(k in new)) { print old[k] > (out "/removed.csv"); rem++; rm_m[om[k]]++ ; if (ohz[k]) hzrem++ } }
  for (i=1;i<=nn;i++) { k=norder[i]
    if (!(k in old)) { print new[k] > (out "/added.csv"); add++; ad_m[nm[k]]++; if (nhz[k]) hznew_add++; continue }
    d=""
    if (om[k]!=nm[k])   d=d "method:" om[k] "->" nm[k] ";"
    if (osr[k]!=nsr[k]) d=d "static_ref:" osr[k] "->" nsr[k] ";"
    if (ost[k]!=nst[k]) d=d "static_ref_target:" ost[k] "->" nst[k] ";"
    if (olv[k]!=nlv[k]) d=d "live:" olv[k] "->" nlv[k] ";"
    if (ode[k]!=nde[k]) d=d "deployment_exists:" ode[k] "->" nde[k] ";"
    if (oso[k]!=nso[k]) d=d "source:" oso[k] "->" nso[k] ";"
    if (d=="") { same++; continue }
    chg++; print "\"" d "\"," old[k] "," nm[k] "," nsr[k] "," nst[k] "," nlv[k] "," nde[k] "," nso[k] > (out "/changed.csv")
    if (om[k]!=nm[k]) mc[om[k] " -> " nm[k]]++
    if (ohz[k] && !nhz[k]) { print old[k] > (out "/hazards-cleared.csv"); hzclr++ }
    if (!ohz[k] && nhz[k]) { print new[k] > (out "/hazards-new.csv"); hznew++ }
  }
  s = out "/summary.txt"
  printf "old rows: %d   new rows: %d\n", no, nn > s
  printf "unchanged pairs:           %d\n", same+0 > s
  printf "REMOVED (only in old):     %d   <- phantom/false rows dropped by the fix\n", rem+0 > s
  for (m in rm_m) printf "    by old method %-22s %d\n", m, rm_m[m] > s
  printf "ADDED (only in new):       %d   <- consumers the old scan missed (e.g. wrong-cell sweep)\n", add+0 > s
  for (m in ad_m) printf "    by new method %-22s %d\n", m, ad_m[m] > s
  printf "CHANGED (same pair):       %d\n", chg+0 > s
  for (m in mc) printf "    method %-30s %d\n", m, mc[m] > s
  printf "hazards (cf-bind + static_ref): old %d -> new %d   cleared %d (false hazards)   newly flagged %d   removed with row %d\n",
         hzo(), hzn(), hzclr+0, hznew+hznew_add+0, hzrem+0 > s
  printf "unknown rows:                   old %d -> new %d\n", cnt(om,"unknown"), cnt(nm,"unknown") > s
  printf "external rows:                  old %d -> new %d\n", cnt(om,"external"), cnt(nm,"external") > s
}
function hzo(  k,n){ for (k in ohz) n+=ohz[k]; return n+0 }
function hzn(  k,n){ for (k in nhz) n+=nhz[k]; return n+0 }
function cnt(a,v,  k,n){ for (k in a) if (a[k]==v) n++; return n+0 }
' "$OLD" "$NEW"

cat "$OUT/summary.txt"
echo
echo "details: $OUT/{removed,added,changed,hazards-cleared,hazards-new}.csv"
