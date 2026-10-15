# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/).

To release: update `VERSION` in `scripts/update.sh`, move the "Unreleased"
notes under a new version heading, then push a matching tag (`git tag v1.0.0 &&
git push origin v1.0.0`). The release workflow publishes the scripts.

## [Unreleased]

## [1.0.0]

First tagged release. Compared with the earlier untagged scripts:

### Breaking

- `update.sh` requires service names; it no longer defaults to `service1 service2`.
- `check_status.sh` now takes container IDs and only waits for health. Removing
  old containers moved into `update.sh`.

### Fixed

- A new container still `starting` when the timeout expired no longer causes the
  old, healthy container to be removed (downtime). The update now fails and rolls back.
- Services without a healthcheck are no longer treated as healthy; the update is refused.
- The failure branch in `update.sh` was unreachable under `set -e`.
- Calling `update.sh` by absolute path no longer breaks.
- Same-named services in other Compose projects are no longer touched.
- New and old containers are told apart by ID, not by sorting creation timestamps.
- `docker compose up` is limited to the service being updated (`--no-deps`).

### Added

- Automatic rollback when new containers are unhealthy, crash, time out, or the
  script is interrupted (Ctrl+C / SIGTERM).
- Options `-f`, `-p`, `--project-directory`, `-t/--timeout`, `--stop-timeout`,
  `--pull`, `--help`, `--version`; service names are validated up front.
- Services with more than one replica are supported (N → 2N → N).
- Docker CLI plugin: `docker rollingupdate`, installed with `scripts/install-plugin.sh`.
- CI: ShellCheck and an end-to-end zero-downtime test; tag-based release workflow.

### Changed

- Example: VERSION env selects the image tag, single node-based healthcheck,
  `stop_grace_period`, forced-exit timer and SIGINT handling in `server.js`,
  non-root image, pinned nginx, `.dockerignore`, `BROKEN=1` rollback demo.

[Unreleased]: https://github.com/majidkabir/docker-compose-rolling-update/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/majidkabir/docker-compose-rolling-update/releases/tag/v1.0.0
