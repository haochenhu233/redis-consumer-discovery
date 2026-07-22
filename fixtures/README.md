# fixtures — exercise every method AND multi-redis attribution

Consumers across **one or more** redis instances, each holding a **live TCP connection**
(idle apps are invisible to the census). Multiple redises prove the tool iterates all redis
deployments and attributes each app to the **right** one.

Per redis #1 (full method coverage):

| Consumer | How it learns the redis address | Expected method |
|---|---|---|
| `rcd-fix-bind-1` | `cf bind-service` (VCAP_SERVICES) | `cf-bind` |
| `rcd-fix-env-1` | `env:` vars in the manifest | `static-ref` |
| `rcd-fix-cmd-1` | on the `command:` (not in `env:`) | `static-ref` (proves the manifest path) |
| `rcd-fix-hidden-1` | baked-in `redis.conf` file | `unknown` |

Per redis #2+ (attribution check): `rcd-fix-bind-N` (`cf-bind`) + `rcd-fix-env-N` (`static-ref`),
each expected to map to **its own** redis service — not redis #1's.

Plus an external `/dev/tcp` loop from the **bastion** → `external`.

## Files

- `run.sh` — the keep-alive "app": opens a TCP socket to redis and holds it. No redis
  client or buildpack deps (pure bash `/dev/tcp`, binary buildpack). Reads the address
  from env, then `./redis.conf`, then `VCAP_SERVICES`.
- `setup.sh` — reads redis creds via a service key, writes the 4 manifests, pushes them,
  and prints the expected classification + the external-consumer command.

## Use

```
cd fixtures
cf login ... && cf target -o <test-org> -s <test-space>
./setup.sh <redis-svc-1> [redis-svc-2 ...]     # 2+ services => multi-redis attribution test
# keep them running, then from the bastion:
redis-consumer-discovery.sh run <env>          # NO --redis => iterates ALL redis deployments
# compare redis_consumers.txt against expected.csv (method AND redis_service)
```

Non-TLS test redis only (bash `/dev/tcp` can't do TLS). Teardown command is printed by
`setup.sh` at the end.
