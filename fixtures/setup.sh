#!/usr/bin/env bash
# Push the fixture consumers that exercise every classification method, then print
# what the discovery tool SHOULD report for each. Run from this fixtures/ dir, logged
# into cf and targeted at the test org/space.
#
#   ./setup.sh <redis-service-instance-name>
#
# Reads the redis creds via a service key, then pushes 4 CF apps (each keeping a live
# TCP connection to redis) wired 4 different ways + prints an external-consumer command.
set -euo pipefail

REDIS_SVC="${1:?usage: ./setup.sh <redis-service-instance-name>}"
APP_BIND="rcd-fix-bind"      # -> cf-bind
APP_ENV="rcd-fix-env"        # -> static-ref (env var)
APP_CMD="rcd-fix-cmd"        # -> static-ref (start command)
APP_HID="rcd-fix-hidden"     # -> unknown    (baked-in config file)

echo "== reading redis creds from a service key on $REDIS_SVC =="
cf create-service-key "$REDIS_SVC" rcd-fix-key >/dev/null 2>&1 || true
KEY_JSON=$(cf service-key "$REDIS_SVC" rcd-fix-key | sed -n '/{/,$p')
RHOST=$(printf '%s' "$KEY_JSON" | jq -r '.. | .host? // .hostname? // empty' | head -1)
RPORT=$(printf '%s' "$KEY_JSON" | jq -r '.. | .port? // empty' | head -1); RPORT="${RPORT:-6379}"
RPASS=$(printf '%s' "$KEY_JSON" | jq -r '.. | .password? // empty' | head -1)
echo "redis: $RHOST:$RPORT (password ${RPASS:+set})"

common="buildpacks: [binary_buildpack]
  health-check-type: process
  memory: 64M
  instances: 1"

# 1) cf-bind: standard binding, app reads VCAP_SERVICES
cat > manifest-bind.yml <<YAML
applications:
- name: $APP_BIND
  command: bash run.sh
  $common
  services: [$REDIS_SVC]
YAML

# 2) static-ref (env): no binding, redis in env vars
cat > manifest-env.yml <<YAML
applications:
- name: $APP_ENV
  command: bash run.sh
  $common
  env:
    REDIS_HOST: "$RHOST"
    REDIS_PORT: "$RPORT"
    REDIS_PASSWORD: "$RPASS"
YAML

# 3) static-ref (command): no binding, no env: block; redis on the start command
cat > manifest-cmd.yml <<YAML
applications:
- name: $APP_CMD
  command: env REDIS_HOST=$RHOST REDIS_PORT=$RPORT REDIS_PASSWORD=$RPASS bash run.sh
  $common
YAML

# 4) unknown: no binding, no env, no command ref; creds in a baked-in config file
cat > redis.conf <<CONF
REDIS_HOST=$RHOST
REDIS_PORT=$RPORT
REDIS_PASSWORD=$RPASS
CONF
cat > manifest-hidden.yml <<YAML
applications:
- name: $APP_HID
  command: bash run.sh
  $common
YAML

echo "== pushing fixtures =="
cf push -f manifest-bind.yml
cf push -f manifest-env.yml
cf push -f manifest-cmd.yml
cf push -f manifest-hidden.yml     # redis.conf is uploaded with the app bits
rm -f redis.conf                    # keep the baked-in file out of the other apps' next push

cat <<EOF

== expected discovery classification ==
  $APP_BIND    -> cf-bind
  $APP_ENV     -> static-ref   (redis in env)
  $APP_CMD     -> static-ref   (redis on start command; NOT in env: -- exercises the manifest path)
  $APP_HID     -> unknown      (redis only in a baked-in config file, invisible to CF)

== external (non-CF) consumer: run this from the BASTION to get an 'external' row ==
  while true; do exec 3<>/dev/tcp/$RHOST/$RPORT && sleep 30; done
  (source IP is the bastion, not a diego cell -> classified 'external')

Keep these running, then:  redis-consumer-discovery.sh run <env>
Teardown:  cf delete $APP_BIND -f; cf delete $APP_ENV -f; cf delete $APP_CMD -f; cf delete $APP_HID -f; cf delete-service-key $REDIS_SVC rcd-fix-key -f
EOF
