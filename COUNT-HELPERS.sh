#!/usr/bin/env bash
# Aggregate-only counters for DATA-NEEDED.md. Run in git-bash in the VDI:
#     bash COUNT-HELPERS.sh /path/to/merged_report.csv
# Prints ONLY counts and yes/nos -- no app/redis names, nothing sensitive.
# merged_report.csv columns: 4=app_guid 5=method 6=static_ref 11=redis_deployment
# 12=service_instance_guid 13=platform 14=deployment_exists 15=live_connection 16=source
f="${1:-merged_report.csv}"
[ -s "$f" ] || { echo "usage: bash COUNT-HELPERS.sh <merged_report.csv>"; exit 1; }

echo "== method split (proportions Q1-3) =="
awk -F, 'NR>1{print $5}' "$f" | sort | uniq -c
echo
echo "== live_connection split =="
awk -F, 'NR>1{print $15}' "$f" | sort | uniq -c
echo
echo "== bound-but-idle: cf-bind rows with live=no (Q4) =="
awk -F, 'NR>1 && $5=="cf-bind" && $15=="no"' "$f" | wc -l
echo
echo "== windows rows / total rows (Q5) =="
echo "$(awk -F, 'NR>1 && $13=="windows"' "$f" | wc -l) / $(awk -F, 'NR>1' "$f" | wc -l)"
echo
echo "== distinct apps / distinct redis services =="
echo "$(awk -F, 'NR>1{a[$4]}END{print length(a)}' "$f") apps / $(awk -F, 'NR>1 && $12!="?"{s[$12]}END{print length(s)}' "$f") services"
echo
echo "== ghost services (deployment_exists=no) =="
awk -F, 'NR>1 && $14=="no"{s[$12]}END{print length(s)+0}' "$f"
echo
echo "== shape checks (section 2) =="
echo -n "mixed-method app (cf-bind + static to different redis) exists: "
awk -F, 'NR>1{m[$4]=m[$4]"|"$5} END{for(a in m) if(m[a]~/cf-bind/ && m[a]~/static/){print "YES"; exit} }' "$f" | grep -q YES && echo YES || echo NO
echo -n "bind+static to the SAME redis (hazard rows): "
awk -F, 'NR>1 && $5=="cf-bind" && $6!=""' "$f" | wc -l
echo -n "redis shared by 2+ apps: "
awk -F, 'NR>1{k[$12]++} END{n=0; for(s in k) if(k[s]>1) n++; print n" service(s)"}' "$f"
echo -n "external client rows: "
awk -F, 'NR>1 && $5=="external"' "$f" | wc -l
echo -n "cross-space rows (app space != redis space): "
awk -F, 'NR>1 && $2!=$9 && $9!="?" && $9!=""' "$f" | wc -l
echo -n "max redis consumed by one app: "
awk -F, 'NR>1{n[$4]++} END{mx=0; for(a in n) if(n[a]>mx) mx=n[a]; print mx+0}' "$f"
