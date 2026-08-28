# Changelog

All notable changes to `@softspark/mage2x` are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versioning follows [Semantic Versioning](https://semver.org/).

---

## v1.0.0 -- Initial release (2026-08-28)

One command across docker, podman and kubectl: `x` is whichever of them is in
front of you.

### Added
- **Runtime adapters for docker, podman and kubectl** behind one verb set, so a
  command reads the same wherever the workload runs. kubectl is not treated as
  docker with a different binary: targets are `[namespace/]pod[:container]`,
  `restart` rolls the owning Deployment, StatefulSet or DaemonSet rather than
  deleting a pod, and TCP access goes through `port-forward`.
- **Ambiguous targets are refused, never guessed.** A fragment matching more
  than one workload lists the candidates and stops. Selecting a `mysql-backup`
  sidecar instead of `mysqld` has already cost this fleet an incident.
- **Production guard** on destructive verbs only. The context is read from
  `kubectl config current-context`, `DOCKER_HOST` or `CONTAINER_HOST` and
  matched against `M2X_PROD_PATTERNS`; confirmation requires typing the target
  name. Read-only commands never prompt, so the prompt keeps its meaning.
  `M2X_ASSUME_YES=1` exists for automation, and a destructive verb without a
  terminal is refused rather than silently run.
- **Magento command catalogue** (`cache`, `reindex`, `upgrade`, `di`, ...) as a
  thin layer over the adapters, plus `mage` for anything else.
- **`m2d` as a short alias** of `m2x`, for fingers that prefer it.
- **Completion** over live targets, bounded by a timeout so a slow or
  unreachable runtime cannot hang a shell.
- **npm installer** for workstations. Servers clone the repository directly and
  need no Node at all.
