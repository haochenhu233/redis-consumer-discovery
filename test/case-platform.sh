#!/usr/bin/env bash
# case-platform.sh -- offline cases for the platform column (2026-10-23): scan-apps takes it from the app's
# lifecycle stack; merge prefers it and falls back to the backward (cell) value; an old app_base.tsv keeps the
# old behaviour. Usage: bash test/case-platform.sh [workdir]. PASS/FAIL per check; exit 1 on any FAIL.
# scan-apps runs against test/cf-stub (answers from JSON files) and is EXPECTED to die at step 2 (no redis
# offering in the stub): app_base.tsv is complete by then, which is all these cases need.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; T="$HERE/../redis-consumer-discovery.sh"; W="${1:-$(mktemp -d)}"; mkdir -p "$W"
fails=0; pass(){ echo "PASS  $1"; }; fail(){ echo "FAIL  $1"; fails=$((fails+1)); }
check(){ if eval "$2"; then pass "$1"; else fail "$1 -- [$2]"; fi; }
col(){ awk -F, -v g="$2" -v c="$3" 'NR>1 && $4==g {print $c}' "$1" | sort -u | paste -sd, -; }   # col <csv> <app guid> <n>  (distinct values)
cols(){ awk -F, -v g="$2" -v c="$3" 'NR>1 && $4==g {print $c}' "$1" | sort | paste -sd, -; }      # cols: every row's value
nrows(){ awk -F, -v g="$2" 'NR>1 && $4==g' "$1" | wc -l | tr -d ' '; }
plats(){ awk -F'\t' 'NR>1 {print $2"="$6}' "$1" | sort | paste -sd, -; }
row456(){ awk -F'\t' -v g="$2" 'NR>1 && $2==g {print $4"/"$5"/"$6}' "$1"; }

echo "== A: scan-apps: platform from lifecycle.data.stack (cf-stub)"
export CFSTUB_DIR="$W/stub"; mkdir -p "$CFSTUB_DIR" "$W/a"
cat > "$CFSTUB_DIR/_v3_organizations_per_page_200.json" <<'EOF'
{"pagination":{"total_results":1,"next":null},"resources":[{"guid":"org-1","name":"sim"}]}
EOF
cat > "$CFSTUB_DIR/_v3_spaces_per_page_200.json" <<'EOF'
{"pagination":{"total_results":1,"next":null},"resources":[{"guid":"sp-1","name":"dev","relationships":{"organization":{"data":{"guid":"org-1"}}}}]}
EOF
cat > "$CFSTUB_DIR/_v3_apps_per_page_200.json" <<'EOF'
{"pagination":{"total_results":4,"next":null},"resources":[
 {"guid":"a-win","name":"win-app","relationships":{"space":{"data":{"guid":"sp-1"}}},"lifecycle":{"type":"buildpack","data":{"buildpacks":["hwc_buildpack"],"stack":"windows2019"}}},
 {"guid":"a-lin","name":"lin-app","relationships":{"space":{"data":{"guid":"sp-1"}}},"lifecycle":{"type":"buildpack","data":{"buildpacks":[],"stack":"cflinuxfs4"}}},
 {"guid":"a-dkr","name":"dkr-app","relationships":{"space":{"data":{"guid":"sp-1"}}},"lifecycle":{"type":"docker","data":{}}},
 {"guid":"a-odd","name":"odd-app","relationships":{"space":{"data":{"guid":"sp-1"}}},"lifecycle":{"type":"buildpack","data":{"buildpacks":[],"stack":"my custom stack"}}},
 {"guid":"a-nosp","name":"nospace-app","relationships":{"space":{"data":null}},"lifecycle":{"type":"buildpack","data":{"buildpacks":[],"stack":"windows2016"}}},
 {"guid":"a-cnb","name":"cnb-app","relationships":{"space":{"data":{"guid":"sp-1"}}},"lifecycle":{"type":"cnb","data":{"buildpacks":[],"stack":"cflinuxfs4"}}}
]}
EOF
cat > "$CFSTUB_DIR/_v3_apps_per_page_1.json" <<'EOF'
{"pagination":{"total_results":6,"next":null},"resources":[]}
EOF
PATH="$HERE:$PATH" bash "$T" scan-apps sbx --path "$W/a" > "$W/a/scan.log" 2>&1; rc=$?
check "A1 scan-apps ran step 1 and died at step 2 as expected (no offering in the stub)" "[ $rc = 1 ] && grep -q 'no service offering named' $W/a/scan.log"
check "A2 app_base.tsv has the platform column and one row per app" "[ \"$(head -1 $W/a/forward/app_base.tsv)\" = \"$(printf 'env\tapp_guid\tapp_name\tspace\torg\tplatform')\" ] && [ $(awk 'NR>1' $W/a/forward/app_base.tsv | wc -l) = 6 ]"
check "A3 windows2019/windows2016 -> windows, cflinuxfs4 (buildpack or cnb) -> linux, docker -> linux, a custom stack name -> '?' (never blank)" "[ \"$(plats $W/a/forward/app_base.tsv)\" = 'a-cnb=linux,a-dkr=linux,a-lin=linux,a-nosp=windows,a-odd=?,a-win=windows' ]"
check "A4 the count line" "grep -q \"platform from the app's stack: 2 windows, 3 linux, 1 unknown (of 6)\" $W/a/scan.log"
check "A5 an app with a null space does not shift the fields: space/org '?', platform still windows" "[ \"$(row456 $W/a/forward/app_base.tsv a-nosp)\" = '?/?/windows' ]"

# ---- merge inputs shared by B and C (hand-written; shapes = the headers the tool writes)
mkforward(){ # mkforward <base> <with-platform 1|0>
  local b="$1"; mkdir -p "$b/forward" "$b/backward"
  if [ "$2" = 1 ]; then printf 'env\tapp_guid\tapp_name\tspace\torg\tplatform\n' > "$b/forward/app_base.tsv"
    printf 'sbx\t%s\t%s\tdev\tsim\t%s\n' a-win-idle win-idle windows a-win-mixed win-mixed windows a-conf conf-app linux a-unk unk-app '?' a-static static-only windows >> "$b/forward/app_base.tsv"
  else printf 'env\tapp_guid\tapp_name\tspace\torg\n' > "$b/forward/app_base.tsv"
    printf 'sbx\t%s\t%s\tdev\tsim\n' a-win-idle win-idle a-win-mixed win-mixed a-conf conf-app a-unk unk-app a-static static-only >> "$b/forward/app_base.tsv"; fi
  printf 'service_instance_guid\tredis_service_name\tredis_service_space\tredis_service_org\tlast_op_type\tlast_op_state\n' > "$b/forward/fwd_redis_si.tsv"
  printf '%s\t%s\tdev\tsim\tcreate\tsucceeded\n' si-1 redis-one si-2 redis-two si-3 redis-three >> "$b/forward/fwd_redis_si.tsv"
  printf 'app_guid\tservice_instance_guid\tredis_service_name\tredis_service_space\tredis_service_org\n' > "$b/forward/fwd_binds.tsv"
  printf '%s\t%s\tx\tdev\tsim\n' a-win-idle si-1 a-win-mixed si-1 a-win-mixed si-2 a-conf si-2 a-unk si-3 >> "$b/forward/fwd_binds.tsv"
  printf 'app_guid\tstatic_ref\tstatic_ref_target\n' > "$b/forward/fwd_static.tsv"
  printf 'a-static\tenv-var\t10.0.0.3\n' >> "$b/forward/fwd_static.tsv"
  printf 'redis_deployment\tservice_instance_guid\n' > "$b/forward/redis_deployments.tsv"
  printf 'redis-cache-small-%s\t%s\n' si-1 si-1 si-2 si-2 si-3 si-3 >> "$b/forward/redis_deployments.tsv"
  # backward: live pairs seen from the cells -- win-mixed on si-2 (windows cell), conf-app on si-2 (a WINDOWS cell, disagreeing with its linux stack), unk-app on si-3 (linux cell)
  printf 'env\tapp_name\tspace\torg\tplatform\tmethod\tstatic_ref\tstatic_ref_target\tredis_service_name\tredis_service_space\tredis_service_org\tredis_deployment\tapp_guid\tredis_ip\n' > "$b/backward/06_classified.tsv"
  printf 'sbx\t%s\tdev\tsim\t%s\tcf-bind\t\t\tx\tdev\tsim\tredis-cache-small-%s\t%s\t10.0.0.1\n' win-mixed windows si-2 a-win-mixed conf-app windows si-2 a-conf unk-app linux si-3 a-unk >> "$b/backward/06_classified.tsv"
  # the deployment names above are not 36-char guids; merge keys backward rows by the LAST 36 chars of the deployment, so use real-length guids
  sed -i.bak 's/si-1/00000001-0000-4000-8000-000000000001/g; s/si-2/00000002-0000-4000-8000-000000000002/g; s/si-3/00000003-0000-4000-8000-000000000003/g' "$b"/forward/*.tsv "$b"/backward/*.tsv; rm -f "$b"/forward/*.bak "$b"/backward/*.bak
}

echo "== B: merge with the platform column: forward wins, backward is the fallback, conflicts counted"
mkforward "$W/b" 1
bash "$T" merge sbx --path "$W/b" > "$W/b/merge.log" 2>&1; rc=$?
R="$W/b/merged_report.csv"
check "B1 merge ok; says where platform came from (4 of 5 apps known forward)" "[ $rc = 0 ] && grep -q 'platform from the forward scan (app stack) for 4 of 5 apps' $W/b/merge.log"
check "B2 a Windows app with NO live connection is now windows (was blank)" "[ \"$(col $R a-win-idle 13)\" = windows ] && [ \"$(col $R a-win-idle 15)\" = no ]"
check "B3 a Windows app with one live and one idle service: windows on BOTH rows" "[ \"$(col $R a-win-mixed 13)\" = windows ] && [ $(nrows $R a-win-mixed) = 2 ]"
check "B4 forward linux vs backward windows: the stack is kept, one conflict warned" "[ \"$(col $R a-conf 13)\" = linux ] && grep -q 'WARNING -- 1 row(s) where the app.s stack (forward) and the cell type (backward) disagree' $W/b/merge.log"
check "B5 forward '?' -> the backward value (linux) is used" "[ \"$(col $R a-unk 13)\" = linux ]"
check "B6 the declared-static-only app row carries the forward platform too" "[ \"$(col $R a-static 13)\" = windows ] && [ \"$(col $R a-static 5)\" = 'static-ref: env-var' ]"

echo "== B2: the same forward files with CRLF line ends and a hand-edited value: header still recognised, odd value counted"
mkforward "$W/b2" 1; sed -i.bak 's/$/\r/' "$W/b2/forward/app_base.tsv"; sed -i.bak 's/a-conf\tconf-app\tdev\tsim\tlinux/a-conf\tconf-app\tdev\tsim\tLinux/; s/a-unk\tunk-app\tdev\tsim\t?/a-unk\tunk-app\tdev\tsim\tmaybe/' "$W/b2/forward/app_base.tsv"; rm -f "$W/b2/forward/app_base.tsv.bak"
bash "$T" merge sbx --path "$W/b2" > "$W/b2/merge.log" 2>&1; rc=$?
R="$W/b2/merged_report.csv"
check "B2a CRLF header is still the platform column; 'Linux' accepted; 'maybe' counted as odd and ignored" "[ $rc = 0 ] && grep -q 'platform from the forward scan (app stack) for 4 of 5 apps; backward (cell) value is the fallback; 1 row(s) with a value that is neither' $W/b2/merge.log"
check "B2b values as in B: idle windows app windows, conf app linux (from 'Linux'), unk app falls back to backward linux" "[ \"$(col $R a-win-idle 13)\" = windows ] && [ \"$(col $R a-conf 13)\" = linux ] && [ \"$(col $R a-unk 13)\" = linux ]"

echo "== C: merge with an OLD app_base.tsv (5 columns): behaviour unchanged"
mkforward "$W/c" 0
bash "$T" merge sbx --path "$W/c" > "$W/c/merge.log" 2>&1; rc=$?
R="$W/c/merged_report.csv"
check "C1 merge ok and says the column is missing" "[ $rc = 0 ] && grep -q \"no 'platform' as its 6th header field (older scan-apps\" $W/c/merge.log && ! grep -q WARNING $W/c/merge.log"
check "C2 idle Windows app blank, mixed app windows only on its live row, conflict app backward windows, static-only blank" "[ \"$(col $R a-win-idle 13)\" = '' ] && [ \"$(cols $R a-win-mixed 13)\" = ',windows' ] && [ \"$(col $R a-conf 13)\" = windows ] && [ \"$(col $R a-static 13)\" = '' ]"
check "C3 same rows, same columns as B (only platform differs)" "[ $(wc -l < $R) = $(wc -l < $W/b/merged_report.csv) ] && [ \"$(cut -d, -f1-12,14-16 $R | sort)\" = \"$(cut -d, -f1-12,14-16 $W/b/merged_report.csv | sort)\" ]"

echo; echo "case-platform: $fails failure(s)"; [ $fails = 0 ]
