#!/usr/bin/env bash
# case-manifest.sh -- offline cases for the manifest leg of the static-ref scan (2026-10-24): /v3/apps/:guid/manifest
# answers YAML, so it must NOT go through api_err (which scored every manifest "non-JSON response" and blanked it).
# Usage: bash test/case-manifest.sh [workdir]. PASS/FAIL per check; exit 1 on any FAIL.
# scan-apps runs against test/cf-stub through step 3 (the stub carries one offering, one plan, no SIs/bindings).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; T="$HERE/../redis-consumer-discovery.sh"; W="${1:-$(mktemp -d)}"; mkdir -p "$W"
fails=0; pass(){ echo "PASS  $1"; }; fail(){ echo "FAIL  $1"; fails=$((fails+1)); }
check(){ if eval "$2"; then pass "$1"; else fail "$1 -- [$2]"; fi; }
srow(){ awk -F'\t' -v g="$2" 'NR>1 && $1==g {print $2"|"$3}' "$1"; }          # srow <fwd_static.tsv> <app guid> -> static_ref|target
merr(){ awk -F'\t' -v g="$2" '$1==g {print $2}' "$1" 2>/dev/null; }           # merr <.man_errors> <app guid> -> reason
nman(){ grep -o 'manifest unreadable for [0-9]* app' "$1" | grep -o '[0-9]*'; }

export CFSTUB_DIR="$W/stub"; mkdir -p "$CFSTUB_DIR" "$W/a"
cat > "$CFSTUB_DIR/_v3_organizations_per_page_200.json" <<'EOF'
{"pagination":{"total_results":1,"next":null},"resources":[{"guid":"org-1","name":"sim"}]}
EOF
cat > "$CFSTUB_DIR/_v3_spaces_per_page_200.json" <<'EOF'
{"pagination":{"total_results":1,"next":null},"resources":[{"guid":"sp-1","name":"dev","relationships":{"organization":{"data":{"guid":"org-1"}}}}]}
EOF
cat > "$CFSTUB_DIR/_v3_apps_per_page_200.json" <<'EOF'
{"pagination":{"total_results":5,"next":null},"resources":[
 {"guid":"m-yaml","name":"yaml-app","relationships":{"space":{"data":{"guid":"sp-1"}}},"lifecycle":{"type":"buildpack","data":{"buildpacks":[],"stack":"cflinuxfs4"}}},
 {"guid":"m-envref","name":"envref-app","relationships":{"space":{"data":{"guid":"sp-1"}}},"lifecycle":{"type":"buildpack","data":{"buildpacks":[],"stack":"cflinuxfs4"}}},
 {"guid":"m-err","name":"err-app","relationships":{"space":{"data":{"guid":"sp-1"}}},"lifecycle":{"type":"buildpack","data":{"buildpacks":[],"stack":"cflinuxfs4"}}},
 {"guid":"m-empty","name":"empty-app","relationships":{"space":{"data":{"guid":"sp-1"}}},"lifecycle":{"type":"buildpack","data":{"buildpacks":[],"stack":"cflinuxfs4"}}},
 {"guid":"m-plain","name":"plain-app","relationships":{"space":{"data":{"guid":"sp-1"}}},"lifecycle":{"type":"buildpack","data":{"buildpacks":[],"stack":"cflinuxfs4"}}}
]}
EOF
cat > "$CFSTUB_DIR/_v3_apps_per_page_1.json" <<'EOF'
{"pagination":{"total_results":5,"next":null},"resources":[]}
EOF
cat > "$CFSTUB_DIR/_v3_service_offerings_names_redis_per_page_200.json" <<'EOF'
{"pagination":{"total_results":1,"next":null},"resources":[{"guid":"off-1","name":"redis"}]}
EOF
cat > "$CFSTUB_DIR/_v3_service_plans_service_offering_guids_off_1_per_page_200.json" <<'EOF'
{"pagination":{"total_results":1,"next":null},"resources":[{"guid":"plan-1","name":"small"}]}
EOF
# env: only m-envref names a redis in its env vars (the others get the stub's empty list: valid JSON, no match)
cat > "$CFSTUB_DIR/_v3_apps_m_envref_environment_variables.json" <<'EOF'
{"var":{"REDIS_HOST":"10.8.8.8","LOG_LEVEL":"info"}}
EOF
# manifests, the way the real endpoint answers them (YAML; the env: block is reconstructed into it)
cat > "$CFSTUB_DIR/_v3_apps_m_yaml_manifest.yml" <<'EOF'
---
applications:
- name: yaml-app
  command: ./app --cache redis://10.9.9.9:6379/0
  stack: cflinuxfs4
EOF
cat > "$CFSTUB_DIR/_v3_apps_m_envref_manifest.yml" <<'EOF'
---
applications:
- name: envref-app
  env:
    REDIS_HOST: 10.8.8.8
    LOG_LEVEL: info
EOF
cat > "$CFSTUB_DIR/_v3_apps_m_plain_manifest.yml" <<'EOF'
---
applications:
- name: plain-app
  memory: 256M
EOF
cat > "$CFSTUB_DIR/_v3_apps_m_err_manifest.json" <<'EOF'
{"errors":[{"detail":"App not found","title":"CF-ResourceNotFound","code":10010}]}
EOF
: > "$CFSTUB_DIR/_v3_apps_m_empty_manifest.json"

echo "== M: scan-apps static-ref step with YAML manifests (cf-stub)"
PATH="$HERE:$PATH" bash "$T" scan-apps sbx --path "$W/a" > "$W/a/scan.log" 2>&1; rc=$?
S="$W/a/forward/fwd_static.tsv"; E="$W/a/forward/.man_errors"
check "M1 scan-apps ran through step 3 and exited 0 (env readable for every app)" "[ $rc = 0 ] && grep -q 'checked 5 app(s) for static refs' $W/a/scan.log"
check "M2 a redis URL in the manifest command: is a manifest static ref with its host" "[ \"\$(srow $S m-yaml)\" = 'manifest|10.9.9.9' ]"
check "M3 env-var ref wins over the same value in the reconstructed manifest" "[ \"\$(srow $S m-envref)\" = 'env-var|10.8.8.8' ]"
check "M4 a plain YAML manifest without a redis is readable and yields no row" "[ -z \"\$(srow $S m-plain)\" ] && [ -z \"\$(merr $E m-plain)\" ]"
check "M5 a JSON error document is recorded with the CF error, not as non-JSON" "[ \"\$(merr $E m-err)\" = 'CF-ResourceNotFound: App not found' ]"
check "M6 an empty answer is recorded as a timeout" "[ \"\$(merr $E m-empty)\" = 'empty response (timeout / not logged in?)' ]"
check "M7 the unreadable note counts exactly the two real failures" "[ \"\$(nman $W/a/scan.log)\" = 2 ]"
check "M8 no INCOMPLETE marker (manifest failures never make the scan incomplete; env does)" "[ ! -e $W/a/forward/fwd_static.INCOMPLETE ]"
check "M9 static rows: exactly the two apps with a ref" "[ \$(awk 'NR>1' $S | wc -l) = 2 ]"

echo; echo "$fails FAIL(s)  (workdir $W)"; [ "$fails" = 0 ]
