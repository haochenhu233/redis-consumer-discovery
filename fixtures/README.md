# fixtures — exercise every classification method

Five consumers, one per method, each holding a **live TCP connection** to a test Redis
(idle apps are invisible to the census, so they must stay connected during a run).

| Consumer | How it learns the redis address | Expected method |
|---|---|---|
| `rcd-fix-bind` | `cf bind-service` (VCAP_SERVICES) | `cf-bind` |
| `rcd-fix-env` | `env:` vars in the manifest | `static-ref` |
| `rcd-fix-cmd` | on the `command:` (not in `env:`) | `static-ref` (proves the manifest path) |
| `rcd-fix-hidden` | baked-in `redis.conf` file | `unknown` |
| external loop | bash `/dev/tcp` from the **bastion** | `external` |

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
./setup.sh <redis-service-instance-name>
# keep them running, then from the bastion:
redis-consumer-discovery.sh run <env>
# compare redis_consumers.txt against the expected table above
```

Non-TLS test redis only (bash `/dev/tcp` can't do TLS). Teardown command is printed by
`setup.sh` at the end.
