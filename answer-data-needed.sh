#!/usr/bin/env bash
# answer-data-needed.sh -- compute copy-back answers for the academy DATA-NEEDED.md.
# Run in git-bash in the VDI, once per environment:
#     bash answer-data-needed.sh <base-path>        # the --path base: merged_report.csv + forward/
#     bash answer-data-needed.sh <merged_report.csv> # csv directly (section-3 extras skipped)
#
# Prints ONLY aggregates, yes/nos, and auto-worded proportions (almost all/most/some/few) --
# no app/redis/org names ever appear in the output. Review, then copy the answers back.
#
# merged_report.csv columns:
#  1 app_name 2 space 3 org 4 app_guid 5 method 6 static_ref 7 static_ref_target
#  8 svc_name 9 svc_space 10 svc_org 11 redis_deployment 12 service_instance_guid
# 13 platform 14 deployment_exists 15 live_connection 16 source
set -uo pipefail

arg="${1:-.}"
if [ -f "$arg" ]; then f="$arg"; base="$(dirname "$arg")"
else base="$arg"; f="$base/merged_report.csv"; fi
[ -s "$f" ] || { echo "ERROR: no merged_report.csv at '$arg'"; exit 1; }
sif="$base/forward/fwd_redis_si.tsv"          # optional: enables unused-redis count

awk -F, '
function word(p){ return p>=90 ? "almost all" : p>=60 ? "most" : p>=20 ? "some" : p>0 ? "few" : "none" }
function pct(n){ return rows ? int(n*100/rows+0.5) : 0 }
NR==1 { next }
{
  rows++
  m=$5; app=$4; si=$12
  meth[m]++
  apps[app]=1
  if (si!="?" && si!="") svc[si]=1
  if ($15=="yes") live++
  if (m=="cf-bind") { bind++; if ($15=="no") idlebind++; if ($6!="") hazard++ }
  if (m ~ /^static-ref/) statics++
  if (m=="unknown" || m=="external") extmgmt++
  if (m=="unresolved") unres++
  if ($13=="windows") { win++; winapp[app]=1 }
  if ($14=="no" && si!="") ghost[si]=1
  if (m!="external" && $2!="" && $2!=$9 && $9!="?" && $9!="") { xspace++; xapps[app]=1 }
  if ($3!="?" && $3!="") orgs[$3]=1
  # per-app rollups for shape checks
  napp[app]++
  methsof[app]=methsof[app] "|" m
  siof[app]=siof[app] "|" si
  liveof[app]=liveof[app] "|" $15
  if ($6!="") hasstatic[app]=1
}
END{
  print "############ SECTION 1 -- proportions (copy the words, % for your reference) ############"
  printf "cf-bind share:              %s  (%d%% of %d rows)\n", word(pct(bind)), pct(bind), rows
  printf "static-ref share:           %s  (%d%%)\n", word(pct(statics)), pct(statics)
  printf "external-mgmt share:        %s  (%d%% = unknown+external)\n", word(pct(extmgmt)), pct(extmgmt)
  if (unres) printf "  (note: %d unresolved rows excluded from buckets)\n", unres
  ib = bind ? int(idlebind*100/bind+0.5) : 0
  printf "bound-but-idle (of cf-bind): %s  (%d%% of cf-bind rows, %d rows)\n", word(ib), ib, idlebind
  wp = pct(win)
  printf "windows slice:              %s  (%d%% of rows; %d windows apps)\n", (wp>=10?"meaningful slice":"a handful"), wp, length(winapp)
  print ""
  print "############ SECTION 2 -- shapes (YES/NO + suggested anonymous one-liner) ############"
  # typical: app with exactly 1 redis, cf-bind, live, and NO static ref anywhere
  typical=0
  for (a in napp) if (napp[a]==1 && methsof[a]=="|cf-bind" && liveof[a]=="|yes" && !(a in hasstatic)) typical++
  printf "typical (1 app,1 redis,cf-bind,active):  %s   -> \"an app bound to its own cache, active at scan\"\n", typical? "YES ("typical" apps)":"NO"
  # mixed: app with cf-bind and static to DIFFERENT si
  mixed=0
  for (a in methsof) if (methsof[a] ~ /cf-bind/ && methsof[a] ~ /static-ref/) mixed++
  printf "mixed (bind redis-A + static redis-B):   %s   -> \"one app, two redis, two methods\"\n", mixed? "YES ("mixed" apps)":"NO"
  printf "bind+hardcode SAME redis (hazard):       %s   -> \"bound app that ALSO pins the address in an env var\"\n", hazard? "YES ("hazard" rows)":"NO"
  printf "bound-but-idle:                          %s   -> \"binding exists, no live connection at scan\"\n", idlebind? "YES ("idlebind" rows)":"NO"
  # shared redis, different methods
  delete simeth; shared=0
  # (second pass impossible in END with -F, so approximate via per-app maps)
  # build si->methods from per-app data
  for (a in siof) { n=split(siof[a], S, "|"); split(methsof[a], M, "|")
    for (i=2; i<=n; i++) if (S[i]!="" && S[i]!="?") simeth[S[i]]=simeth[S[i]] "|" M[i] }
  for (s in simeth) if (simeth[s] ~ /cf-bind/ && (simeth[s] ~ /static-ref/ || simeth[s] ~ /unknown/ || simeth[s] ~ /external/)) shared++
  printf "shared redis, different methods:         %s   -> \"one redis, several consumer apps, not all bound\"\n", shared? "YES ("shared" services)":"NO"
  # NOTE: external rows are NOT in merged_report (merge joins apps only) -- counted separately
  # below from backward/redis_consumers.txt.
  printf "cross-space/org access:                  %s   -> \"an app using a redis owned by another team\"\n", xspace? "YES ("xspace" rows, "length(xapps)" apps)":"NO"
  printf "windows app consumer:                    %s   -> \"a windows-stack app, same story as linux\"\n", win? "YES ("win" rows)":"NO"
  print ""
  print "############ SECTION 3 -- context (data-derivable part) ############"
  printf "distinct apps consuming redis:   %d\n", length(apps)
  printf "distinct redis services:         %d\n", length(svc)
  printf "orgs affected (rough team count): %d\n", length(orgs)
  printf "ghost services (CF record, no deployment): %d\n", length(ghost)
}' "$f"

# external clients: NOT present in merged_report -- count from the backward report
bwd="$base/backward/redis_consumers.txt"
if [ -s "$bwd" ]; then
  extn=$(awk -F, 'NR>1 && $5=="external"' "$bwd" | wc -l | tr -d ' ')
  extsvc=$(awk -F, 'NR>1 && $5=="external"{s[$11]}END{print length(s)+0}' "$bwd")
  if [ "${extn:-0}" -gt 0 ]; then
    echo "external client (non-CF):        YES ($extn connection(s) to $extsvc redis)   -> \"a non-platform system holding a connection\""
  else
    echo "external client (non-CF):        NO"
  fi
else
  echo "external client: SKIPPED (no backward/redis_consumers.txt under '$base')"
fi

# unused redis: SIs known to CF (forward scan) that have NO consumer row in the merge
if [ -s "$sif" ]; then
  awk -F'\t' 'NR>1{all[$1]=1} END{ }' "$sif" >/dev/null 2>&1
  unused=$(awk 'BEGIN{FS="\t"} NR==FNR{if(FNR>1)all[$1]=1; next}
                {n=split($0,C,","); if(FNR>1 && C[12]!="" && C[12]!="?") used[C[12]]=1}
                END{u=0; for(s in all) if(!(s in used)) u++; print u}' "$sif" "$f")
  echo "unused redis (no consumers found across forward+backward): $unused"
else
  echo "unused redis: SKIPPED (no forward/fwd_redis_si.tsv under '$base' -- run with the --path base)"
fi
echo
echo "manual questions (not derivable from data): migration start date | sandbox availability | dyn-creds redis-side-or-valkey-only"
