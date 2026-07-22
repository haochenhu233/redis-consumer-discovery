#!/usr/bin/env bash
# Keep-alive fixture "app": holds an established TCP connection to redis so the
# discovery census can see it. It does NOT need to speak redis correctly -- an open
# socket to the redis port is all the tool needs. Redis address comes from (in order):
#   1. REDIS_HOST/REDIS_PORT/REDIS_PASSWORD env vars      (env / command / manifest variants)
#   2. ./redis.conf  (KEY=VALUE lines)                    (hidden variant: baked-in config file)
#   3. VCAP_SERVICES                                       (cf-bind variant)
set -u

# variant 3/4: source a baked-in config file if present (no env, no binding)
[ -f ./redis.conf ] && . ./redis.conf 2>/dev/null

# variant 1: parse VCAP_SERVICES if bound -- jq-free (jq is not in the binary buildpack)
if [ -z "${REDIS_HOST:-}" ] && [ -n "${VCAP_SERVICES:-}" ]; then
  REDIS_HOST=$(printf '%s' "$VCAP_SERVICES" | grep -oE '"(host|hostname)":"[^"]*"' | head -1 | sed -E 's/.*":"//; s/"$//')
  REDIS_PORT=$(printf '%s' "$VCAP_SERVICES" | grep -oE '"port":[0-9]+' | head -1 | grep -oE '[0-9]+')
  REDIS_PASSWORD=$(printf '%s' "$VCAP_SERVICES" | grep -oE '"password":"[^"]*"' | head -1 | sed -E 's/.*":"//; s/"$//')
fi

: "${REDIS_HOST:?REDIS_HOST not set (env, redis.conf, or VCAP_SERVICES)}"
: "${REDIS_PORT:=6379}"
echo "fixture: connecting to $REDIS_HOST:$REDIS_PORT and holding the socket open"

while true; do
  if exec 3<>"/dev/tcp/$REDIS_HOST/$REDIS_PORT"; then
    [ -n "${REDIS_PASSWORD:-}" ] && printf 'AUTH %s\r\n' "$REDIS_PASSWORD" >&3 2>/dev/null
    while printf 'PING\r\n' >&3 2>/dev/null; do sleep 10; done
    exec 3>&- 2>/dev/null
  fi
  sleep 5
done
