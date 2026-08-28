# mage2x

> Run commands inside a container workload, whatever runs it. Docker, Podman or
> Kubernetes — one command, and it refuses to guess which container you meant.

[![CI](https://github.com/softspark/mage2x/actions/workflows/ci.yml/badge.svg)](https://github.com/softspark/mage2x/actions/workflows/ci.yml)
[![npm](https://img.shields.io/npm/v/@softspark/mage2x)](https://www.npmjs.com/package/@softspark/mage2x)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

## What's New in v1.0.0

- **Three runtimes, one command** — docker, podman and kubectl behind the same verbs
- **Ambiguous targets are refused**, with the candidates listed, instead of guessed
- **Production guard** on destructive verbs only, confirmed by typing the target name
- **`m2d` works as a short alias**, for fingers that prefer it

## Table of Contents

- [Why](#why)
- [Install](#install)
- [Usage](#usage)
- [Targets](#targets)
- [Commands](#commands)
- [Production safety](#production-safety)
- [Configuration](#configuration)
- [Architecture](#architecture)
- [Known Limits](#known-limits)
- [Contributing](#contributing)
- [Security](#security)
- [License](#license)
- [Changelog](#changelog)

## Why

Reaching into a running Magento container should not mean remembering a
different incantation for every engine. Docker hosts, Podman hosts and
Kubernetes clusters need the same handful of operations, and the answer should
not be three tools with three sets of muscle memory.

Two things beyond portability shape the design.

**A fragment that matches more than one workload is an error.** Matching `mysql`
against a `mysql-backup` sidecar instead of `mysqld` is not hypothetical; it has
happened here, on a monitoring tool that took the first match. `mage2x` lists
the candidates and stops.

**Destructive verbs on production ask first.** Not every command — a prompt that
fires on `logs` is dismissed reflexively within a day and protects nothing. Only
`restart`, `stop`, `rm` and friends, and only when the context looks like
production.

## Install

### From git

```bash
git clone https://github.com/softspark/mage2x.git \
  "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/mage2x"
```

Add `mage2x` to `plugins=(...)` in `~/.zshrc` and reload the shell. This is the
path configuration management should use: the plugin is pure zsh and needs no
Node, which matters on servers that have neither Node nor `make`.

### From npm

```bash
npx @softspark/mage2x install
```

Links the plugin into `$ZSH_CUSTOM/plugins/mage2x` and offers to add it to
`plugins=(...)`, writing a backup first. There is no postinstall hook: the
package ships `ignore-scripts=true`, so installation is always something you
asked for.

**Requirements:** zsh, and at least one of `docker`, `podman` or `kubectl`.
Node.js 18+ only for the npm installer.

## Usage

```bash
m2x                          # what can I reach from here?
m2x checkout shell           # interactive shell
m2x checkout cache           # magento cache:clean
m2x checkout mage indexer:status
m2x checkout logs -f
m2x context                  # which runtime, which context, is it production?
```

On a cluster:

```bash
m2x --runtime kube                       # pods across all namespaces
m2x shop/web-7d9f shell
m2x shop/web-7d9f:php-fpm mage upgrade
m2x shop/web-7d9f forward 3306:3306
```

## Targets

| Runtime | Target syntax |
|---|---|
| docker, podman | container name |
| kubectl | `[namespace/]pod[:container]` |

Targets are matched on a fragment. An exact name always wins; anything matching
two or more workloads is refused with the candidates printed:

```
x 'ph' is ambiguous - refusing to guess
     php
     php-fpm
   name the target exactly
```

## Commands

| Verb | Effect |
|---|---|
| `shell` | interactive shell as `$M2X_APP_USER` |
| `root` | interactive shell as root |
| `sh` | interactive `sh`, for images without bash |
| `exec <cmd>` | run a command |
| `logs [args]` | container logs |
| `restart` | restart; guarded on production |
| `forward L:R` | port-forward (kubectl only) |
| `context` | show the runtime and context in use |

`m2d` is a short alias of `m2x` and takes the same arguments.

Magento shortcuts: `cache`, `cache-flush`, `reindex`, `upgrade`, `di`, `deploy`,
`mode`, `cron`, `maint-on`, `maint-off`. Anything else goes through
`m2x <target> mage <command>`. Also available: `magento`, `report`, `applog`,
`composer`, `redis-flush`, `varnish-purge`, `varnish-stat`.

**Inside a project checkout, the project's Makefile is the better tool.** It
knows the platform, the lock files and the network ordering. `mage2x` is for the
case the Makefile cannot serve: a server, or any host without the project tree.

## Production safety

A context is production when `M2X_PROD=1` is set, or when its name matches
`M2X_PROD_PATTERNS` (default `prod|production|prd|live`). The context is
`kubectl config current-context`, or `DOCKER_HOST` / `CONTAINER_HOST`, or the
engine's context name and hostname.

```
PRODUCTION  restart  checkout-php  on  k8s:acme-production
type the target name to confirm:
```

Confirmation is the target's name, not `y` — the point is to make you read what
you are about to restart. Without a terminal the operation is refused rather
than run; `M2X_ASSUME_YES=1` is the explicit override for automation.

Only destructive verbs are guarded: `restart`, `stop`, `rm`, `kill`, `down`,
`scale`, `rollout`. Reads never prompt.

## Configuration

| Variable | Effect |
|---|---|
| `M2X_RUNTIME` | force `docker`, `podman` or `kube` instead of detecting |
| `M2X_KUBE_NS` | default namespace, and restrict listing to it |
| `M2X_APP_USER` | user for application commands (default `www-data`) |
| `M2X_MAGENTO_BIN` | path to the Magento CLI (default `bin/magento`) |
| `M2X_PROD_PATTERNS` | regex marking a context as production |
| `M2X_PROD` | treat the current context as production |
| `M2X_ASSUME_YES` | skip the production prompt |

## Architecture

```
mage2x.plugin.zsh     entry point: argument parsing, verb dispatch, m2d shim
_mage2x               completion over live targets
lib/
  core.zsh            runtime selection, target resolution, production guard
  rt-cli.zsh          docker and podman adapters
  rt-kube.zsh         kubectl adapter
  catalog.zsh         Magento shortcuts, layered over the adapters
bin/
  mage2x-install.mjs  npm installer (Node, no dependencies)
tests/run.sh          suite, runs against a fake adapter — no engine required
```

Every adapter implements the same verbs: `available`, `context`, `list`, `exec`,
`shell`, `logs`, `restart`, `forward`. Adding a runtime touches one file and no
command; adding a command touches the catalogue and no runtime.

## Known Limits

- `kubectl exec` cannot switch user, so `M2X_APP_USER` is ignored there and says so.
- Neither docker nor podman has a port-forward; `forward` reports the container
  IP instead of pretending.
- A pod with no controller cannot be restarted — deleting it would not bring it
  back, so `mage2x` refuses rather than doing it.
- Production detection is a heuristic over the context name. Set `M2X_PROD=1`
  where the name does not say what the cluster is.

## Contributing

See [CONTRIBUTING.md](.github/CONTRIBUTING.md).

## Security

See [SECURITY.md](SECURITY.md). Report vulnerabilities to biuro@softspark.eu
rather than in a public issue.

## License

[Apache-2.0](LICENSE). See [NOTICE](NOTICE) for attribution requirements.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

---

Built by [SoftSpark](https://softspark.eu).
