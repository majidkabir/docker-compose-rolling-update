# Quick Reference

Command cheat sheet. For setup and explanations, see the [README](README.md).

## Install

```bash
# Into your project (both scripts in the same directory)
base=https://github.com/majidkabir/docker-compose-rolling-update/releases/latest/download
mkdir -p scripts && curl -fsSL -o scripts/update.sh "$base/update.sh" -o scripts/check_status.sh "$base/check_status.sh"
chmod +x scripts/*.sh

# ...or as a Docker CLI plugin, from a clone of this repo
./scripts/install-plugin.sh          # then: docker rollingupdate ...
```

## Update

```bash
./scripts/update.sh api                        # one service
./scripts/update.sh api worker                 # several, one after another
API_TAG=1.5.0 ./scripts/update.sh api          # new tag via a compose variable
./scripts/update.sh --pull always api          # re-pushed tag (e.g. :latest)
docker compose build api && ./scripts/update.sh api   # local build
./scripts/update.sh -f prod.yaml -p shop -t 300 api   # other file/project, 5 min timeout
```

| Exit code | Meaning |
|---|---|
| `0` | Updated |
| `1` | Failed — new containers removed, old ones still serving |
| `64` | Usage error (unknown option or service) |
| `130` / `143` | Interrupted — rolled back |

## Checklist for a service

- [ ] Healthcheck defined (compose `healthcheck:` or Dockerfile `HEALTHCHECK`)
- [ ] Healthcheck command exists in the image (`curl`, `wget`, `node`, ...)
- [ ] No fixed host `ports:` and no `container_name` (two copies run briefly)
- [ ] Handles `SIGTERM` and finishes in-flight requests within `stop_grace_period`
- [ ] Proxy re-resolves DNS — Nginx: `resolver 127.0.0.11 valid=1s` + variable in `proxy_pass` + `proxy_next_upstream error timeout`

## Debug

```bash
docker compose ps                                        # containers and health
docker inspect --format '{{json .State.Health}}' <id>    # health-check history
docker compose logs <service>                            # logs of all its containers
./scripts/check_status.sh -t 30 <id>                     # wait for healthy: exit 0 / 1 / 2
docker compose config --images                           # image tags Compose resolves
docker compose rm -f <service>                           # remove stopped leftovers
```

## Try the example

```bash
cd example/
docker build -t service:v1 .
docker compose up -d --wait
./monitor.sh                                             # in a second terminal

docker build --build-arg VERSION=2 -t service:v2 .
VERSION=2 ../scripts/update.sh service1 service2         # v1 → v2, no failed requests
BROKEN=1 VERSION=2 ../scripts/update.sh service1         # broken release: rolled back

docker compose down && docker rmi service:v1 service:v2
./e2e-test.sh                                            # or run all of the above automatically
```
