#!/usr/bin/env bash
# case-envkey.sh -- offline cases for static-ref: env-key (2026-10-25): an app variable whose NAME contains "redis"
# (any case) is a static ref of kind env-key when neither env nor manifest holds an address; the target lists the
# names only (key:A;B), never a value. Both readers: scan-apps step 3 (fwd_static.tsv) and merge classify (bound rows).
# Usage: bash test/case-envkey.sh [workdir]. PASS/FAIL per check; exit 1 on any FAIL.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; T="$HERE/../redis-consumer-discovery.sh"; W="${1:-$(mktemp -d)}"; mkdir -p "$W"
fails=0; pass(){ echo "PASS  $1"; }; fail(){ echo "FAIL  $1"; fails=$((fails+1)); }
check(){ if eval "$2"; then pass "$1"; else fail "$1 -- [$2]"; fi; }
srow(){ awk -F'\t' -v g="$2" 'NR>1 && $1==g {print $2"|"$3}' "$1"; }                       # srow <fwd_static.tsv> <app> -> static_ref|target
col(){ awk -F, -v g="$2" -v c="$3" 'NR>1 && $4==g {print $c}' "$1" | sort -u | paste -sd, -; }   # col <merged csv> <app guid> <n>

export CFSTUB_DIR="$W/stub"; mkdir -p "$CFSTUB_DIR" "$W/a"
cat > "$CFSTUB_DIR/_v3_organizations_per_page_200.json" <<'EOF'
{"pagination":{"total_results":1,"next":null},"resources":[{"guid":"org-1","name":"sim"}]}
EOF
cat > "$CFSTUB_DIR/_v3_spaces_per_page_200.json" <<'EOF'
{"pagination":{"total_results":1,"next":null},"resources":[{"guid":"sp-1","name":"dev","relationships":{"organization":{"data":{"guid":"org-1"}}}}]}
EOF
apps='k-svc k-mixed k-host k-none k-valkey k-vcapish'
{ printf '{"pagination":{"total_results":6,"next":null},"resources":['; sep=""
  for a in $apps; do printf '%s{"guid":"%s","name":"%s-app","relationships":{"space":{"data":{"guid":"sp-1"}}},"lifecycle":{"type":"buildpack","data":{"buildpacks":[],"stack":"cflinuxfs4"}}}' "$sep" "$a" "$a"; sep=","; done
  printf ']}\n'; } > "$CFSTUB_DIR/_v3_apps_per_page_200.json"
printf '{"pagination":{"total_results":6,"next":null},"resources":[]}\n' > "$CFSTUB_DIR/_v3_apps_per_page_1.json"
cat > "$CFSTUB_DIR/_v3_service_offerings_names_redis_per_page_200.json" <<'EOF'
{"pagination":{"total_results":1,"next":null},"resources":[{"guid":"off-1","name":"redis"}]}
EOF
cat > "$CFSTUB_DIR/_v3_service_plans_service_offering_guids_off_1_per_page_200.json" <<'EOF'
{"pagination":{"total_results":1,"next":null},"resources":[{"guid":"plan-1","name":"small"}]}
EOF
# env bodies (the real endpoint's shape: {"var":{...}})
cat > "$CFSTUB_DIR/_v3_apps_k_svc_environment_variables.json" <<'EOF'
{"var":{"REDIS_SERVICE":"redis","LOG_LEVEL":"info"}}
EOF
cat > "$CFSTUB_DIR/_v3_apps_k_mixed_environment_variables.json" <<'EOF'
{"var":{"myRedisName":"cache-one","OtherRedisPassword":"s3cr3t-value","PORT":"8080"}}
EOF
cat > "$CFSTUB_DIR/_v3_apps_k_host_environment_variables.json" <<'EOF'
{"var":{"REDIS_HOST":"10.8.8.8","REDIS_SERVICE":"redis"}}
EOF
cat > "$CFSTUB_DIR/_v3_apps_k_none_environment_variables.json" <<'EOF'
{"var":{"CACHE_URL":"memcached://10.1.1.1:11211","SPRING_PROFILES_ACTIVE":"redis"}}
EOF
cat > "$CFSTUB_DIR/_v3_apps_k_valkey_environment_variables.json" <<'EOF'
{"var":{"VALKEY_SERVICE":"valkey"}}
EOF
cat > "$CFSTUB_DIR/_v3_apps_k_vcapish_environment_variables.json" <<'EOF'
{"var":{"REDIS":"true"}}
EOF
for a in $apps; do printf -- '---\napplications:\n- name: %s-app\n  memory: 256M\n' "$a" > "$CFSTUB_DIR/_v3_apps_${a//-/_}_manifest.yml"; done

echo "== K: scan-apps static-ref step: a variable NAMED after redis"
PATH="$HERE:$PATH" bash "$T" scan-apps sbx --path "$W/a" > "$W/a/scan.log" 2>&1; rc=$?
S="$W/a/forward/fwd_static.tsv"
check "K1 scan-apps ran through step 3 (exit 0)" "[ $rc = 0 ] && grep -q 'checked 6 app(s) for static refs' $W/a/scan.log"
check "K2 REDIS_SERVICE=redis -> env-key, target names the key" "[ \"\$(srow $S k-svc)\" = 'env-key|key:REDIS_SERVICE' ]"
check "K3 mixed-case names, sorted; a password variable is a hit by NAME and its value is absent from the row" "[ \"\$(srow $S k-mixed)\" = 'env-key|key:OtherRedisPassword;myRedisName' ] && ! grep -q 's3cr3t-value' $S"
check "K4 an address in REDIS_HOST wins: env-var with the host, even with REDIS_SERVICE present" "[ \"\$(srow $S k-host)\" = 'env-var|10.8.8.8' ]"
check "K5 'redis' only in a VALUE (SPRING_PROFILES_ACTIVE=redis) is not a hit; nor a memcached URL" "[ -z \"\$(srow $S k-none)\" ]"
check "K6 VALKEY_SERVICE is not a hit (the rule is the word redis)" "[ -z \"\$(srow $S k-valkey)\" ]"
check "K7 a bare REDIS variable is a hit" "[ \"\$(srow $S k-vcapish)\" = 'env-key|key:REDIS' ]"
check "K8 count line: 4 static refs" "grep -q 'checked 6 app(s) for static refs (par=8), 4 with a static redis ref' $W/a/scan.log"

echo "== M: merge carries the forward static_ref onto BOUND rows (the plan's hazard input): env-key on a cf-bind row"
B="$W/m"; mkdir -p "$B/forward" "$B/backward"
SI=00000001-0000-4000-8000-000000000001
printf 'env\tapp_guid\tapp_name\tspace\torg\tplatform\n' > "$B/forward/app_base.tsv"
printf 'sbx\t%s\t%s\tdev\tsim\tlinux\n' k-svc k-svc-app k-host k-host-app k-none k-none-app >> "$B/forward/app_base.tsv"
printf 'service_instance_guid\tredis_service_name\tredis_service_space\tredis_service_org\tlast_op_type\tlast_op_state\n' > "$B/forward/fwd_redis_si.tsv"
printf '%s\tredis-one\tdev\tsim\tcreate\tsucceeded\n' $SI >> "$B/forward/fwd_redis_si.tsv"
printf 'app_guid\tservice_instance_guid\tredis_service_name\tredis_service_space\tredis_service_org\n' > "$B/forward/fwd_binds.tsv"
printf '%s\t%s\tredis-one\tdev\tsim\n' k-svc $SI k-host $SI k-none $SI >> "$B/forward/fwd_binds.tsv"
printf 'app_guid\tstatic_ref\tstatic_ref_target\n' > "$B/forward/fwd_static.tsv"
printf 'k-svc\tenv-key\tkey:REDIS_SERVICE\nk-host\tenv-var\t10.8.8.8\n' >> "$B/forward/fwd_static.tsv"   # as scan-apps step 3 writes them (case K)
printf 'redis_deployment\tservice_instance_guid\n%s\t%s\n' redis-cache-small-$SI $SI > "$B/forward/redis_deployments.tsv"
printf 'env\tapp_name\tspace\torg\tplatform\tmethod\tstatic_ref\tstatic_ref_target\tredis_service_name\tredis_service_space\tredis_service_org\tredis_deployment\tapp_guid\tredis_ip\n' > "$B/backward/06_classified.tsv"
PATH="$HERE:$PATH" bash "$T" merge sbx --path "$B" > "$B/merge.log" 2>&1; rc=$?
R="$B/merged_report.csv"
check "M1 merge ok" "[ $rc = 0 ] && [ -s $R ]"
check "M2 bound app with REDIS_SERVICE: method cf-bind, static_ref env-key, target key:REDIS_SERVICE (= hazard for the plan)" "[ \"\$(col $R k-svc 5)\" = cf-bind ] && [ \"\$(col $R k-svc 6)\" = env-key ] && [ \"\$(col $R k-svc 7)\" = 'key:REDIS_SERVICE' ]"
check "M3 bound app with REDIS_HOST (another address): env-var wins, target is the host" "[ \"\$(col $R k-host 6)\" = env-var ] && [ \"\$(col $R k-host 7)\" = 10.8.8.8 ]"
check "M4 bound app with no redis-named variable: static_ref empty (unchanged behaviour)" "[ \"\$(col $R k-none 6)\" = '' ]"
check "M5 no value of any variable reaches the report" "! grep -q 's3cr3t-value\|cache-one\|memcached' $R"

echo; echo "case-envkey: $fails failure(s)"; [ $fails = 0 ]
