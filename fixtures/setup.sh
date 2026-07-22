#!/usr/bin/env bash
# Push fixture consumers across ONE OR MORE redis instances to exercise every method
# AND prove the tool iterates all redis deployments + attributes each app to the RIGHT redis.
#
#   ./setup.sh <redis-svc-1> [redis-svc-2 ...]
#
# redis #1  -> all 4 method variants: cf-bind, static-ref(env), static-ref(command), unknown(hidden)
# redis #2+ -> cf-bind + static-ref(env)   (proves multi-redis detection & correct attribution)
# Each app keeps a live TCP connection (idle apps are invisible to the census).
# Each app stages in its own dir so redis.conf (hidden variant) can't leak into others.
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: ./setup.sh <redis-svc-1> [redis-svc-2 ...]"; exit 1; }
command -v jq >/dev/null || { echo "jq required on the bastion for setup"; exit 1; }

STAGE=./stage; rm -rf "$STAGE"; mkdir -p "$STAGE"
: > expected.csv; echo "app,expected_method,expected_redis_service" >> expected.csv
FIRST_HOST=""; FIRST_PORT=""

creds_of(){  # $1=svc -> RHOST RPORT RPASS
  cf create-service-key "$1" rcd-fix-key >/dev/null 2>&1 || true
  local j; j=$(cf service-key "$1" rcd-fix-key | sed -n '/{/,$p')
  RHOST=$(printf '%s' "$j" | jq -r '.. | .host? // .hostname? // empty' | head -1)
  RPORT=$(printf '%s' "$j" | jq -r '.. | .port? // empty' | head -1); RPORT="${RPORT:-6379}"
  RPASS=$(printf '%s' "$j" | jq -r '.. | .password? // empty' | head -1)
}

push_variant(){  # $1=app $2=mode(bind|env|cmd|hidden) $3=svc
  local app="$1" mode="$2" svc="$3" d="$STAGE/$1"
  mkdir -p "$d"; cp run.sh "$d/"
  local common="  buildpacks: [binary_buildpack]
  health-check-type: process
  memory: 64M
  instances: 1"
  case "$mode" in
    bind) cat > "$d/manifest.yml" <<YAML
applications:
- name: $app
  command: bash run.sh
$common
  services: [$svc]
YAML
      ;;
    env) cat > "$d/manifest.yml" <<YAML
applications:
- name: $app
  command: bash run.sh
$common
  env:
    REDIS_HOST: "$RHOST"
    REDIS_PORT: "$RPORT"
    REDIS_PASSWORD: "$RPASS"
YAML
      ;;
    cmd) cat > "$d/manifest.yml" <<YAML
applications:
- name: $app
  command: env REDIS_HOST=$RHOST REDIS_PORT=$RPORT REDIS_PASSWORD=$RPASS bash run.sh
$common
YAML
      ;;
    hidden) printf 'REDIS_HOST=%s\nREDIS_PORT=%s\nREDIS_PASSWORD=%s\n' "$RHOST" "$RPORT" "$RPASS" > "$d/redis.conf"
      cat > "$d/manifest.yml" <<YAML
applications:
- name: $app
  command: bash run.sh
$common
YAML
      ;;
  esac
  ( cd "$d" && cf push -f manifest.yml )
}

i=0
for svc in "$@"; do
  i=$((i+1)); creds_of "$svc"
  [ -z "$FIRST_HOST" ] && { FIRST_HOST="$RHOST"; FIRST_PORT="$RPORT"; }
  echo "== redis #$i: $svc -> $RHOST:$RPORT =="
  push_variant "rcd-fix-bind-$i" bind "$svc"; echo "rcd-fix-bind-$i,cf-bind,$svc" >> expected.csv
  push_variant "rcd-fix-env-$i"  env  "$svc"; echo "rcd-fix-env-$i,static-ref,$svc" >> expected.csv
  if [ "$i" -eq 1 ]; then
    push_variant "rcd-fix-cmd-$i"    cmd    "$svc"; echo "rcd-fix-cmd-$i,static-ref,$svc" >> expected.csv
    push_variant "rcd-fix-hidden-$i" hidden "$svc"; echo "rcd-fix-hidden-$i,unknown,$svc" >> expected.csv
  fi
done

echo
echo "== expected classification (also in expected.csv) =="
column -t -s, expected.csv
cat <<EOF

== external (non-CF) consumer: run on the BASTION for an 'external' row (uses redis #1) ==
  while true; do exec 3<>/dev/tcp/$FIRST_HOST/$FIRST_PORT && sleep 30; done

Keep apps running, then:   redis-consumer-discovery.sh run <env>
Compare redis_consumers.txt against expected.csv (method AND redis_service).

Teardown:
  for a in \$(cut -d, -f1 expected.csv | tail -n +2); do cf delete \$a -f; done
  for s in $*; do cf delete-service-key \$s rcd-fix-key -f; done
  rm -rf stage expected.csv
EOF
