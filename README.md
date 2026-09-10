# mage2x

> Run commands inside a container workload, whatever runs it. Docker, Podman or
> Kubernetes — one command, and it refuses to guess which container you meant.

[![CI](https://github.com/softspark/mage2x/actions/workflows/ci.yml/badge.svg)](https://github.com/softspark/mage2x/actions/workflows/ci.yml)
[![npm](https://img.shields.io/npm/v/@softspark/mage2x)](https://www.npmjs.com/package/@softspark/mage2x)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

## What's New in v2.0.0

- **Breaking:** `m2d` replaces `m2x` and selects Docker. Update scripts to use `m2d`, `m2p` or `m2k` for their intended runtime.
- `m2p` and `m2k` appear only when their CLI is installed.
- Command-position TAB omits `M2X_*` variables; variable expansion completion still works.
- Runtime overrides stay local to each invocation, and a missing `--runtime` value is rejected.

## Table of Contents

- [Why](#why)
- [Install](#install)
- [Usage](#usage)
- [Targets](#targets)
- [Commands](#commands)
- [Production safety](#production-safety)
- [Configuration](#configuration)
- [Architecture](#architecture)
- [Documentation](#documentation)
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

### As a single file

Where only one object can be delivered — an S3 asset, a configuration-management
template — use the generated build:

```bash
curl -fsSL -o mage2x.plugin.zsh \
  https://raw.githubusercontent.com/softspark/mage2x/v2.0.0/dist/mage2x.plugin.zsh
```

Pin the tag rather than tracking a branch: the point of shipping a file is that
the version is decided at deploy time, not at boot time. `dist/` is committed and
CI fails when it lags the sources.

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
m2d                          # Docker containers
m2d checkout shell           # interactive shell
m2d checkout cache           # magento cache:clean
m2d checkout mage indexer:status
m2d checkout logs -f
m2d context                  # Docker context and production classification
```

On a cluster:

```bash
m2k                          # pods across all namespaces
m2k shop/web-7d9f shell
m2k shop/web-7d9f:php-fpm mage upgrade
m2k shop/web-7d9f forward 3306:3306
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
| `migrate` | retire a superseded plugin, point `~/.zshrc` here |

### Pinning the engine

| Command | Runtime | Available in the shell |
|---|---|---|
| `m2d` | docker | always |
| `m2p` | podman | when `podman` is on PATH at plugin load |
| `m2k` | kubectl | when `kubectl` is on PATH at plugin load |

`m2d` replaces the former `m2x` command and selects Docker. All three commands
take the same arguments; an explicit `--runtime` overrides their engine pin.
Reload the shell with `exec zsh` after installing or removing an engine CLI to
refresh the commands and their completions. Registration checks the executable,
so a stopped daemon or an unreachable cluster does not hide its command.

Command-position TAB omits the `M2X_*` configuration variables. They remain
available for assignments and variable expansion, including `$M2X_<TAB>`.

Magento shortcuts: `cache`, `cache-flush`, `reindex`, `upgrade`, `di`, `deploy`,
`mode`, `cron`, `maint-on`, `maint-off`. Anything else goes through
`m2d <target> mage <command>`. Also available: `magento`, `report`, `applog`,
`composer`, `redis-flush`, `varnish-purge`, `varnish-stat`.

**Inside a project checkout, the project's Makefile is the better tool.** It
knows the platform, the lock files and the network ordering. `mage2x` is for the
case the Makefile cannot serve: a server, or any host without the project tree.

## Local audit

Run `m2d audit --json` or `m2d audit --sarif` to inspect local settings without
contacting an engine. This reports confirmation bypasses, broken guard settings,
unknown adapters and missing binaries. It does not establish remote reachability.
See the [audit contract](kb/reference/configuration.md#audit-contract).

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

That list is internal and not a knob. If it is ever empty or the wrong type the
guard refuses every command, rather than concluding that nothing is destructive.

## Configuration

| Variable | Effect |
|---|---|
| `M2X_RUNTIME` | compatible runtime setting; command pins take precedence, use `--runtime` to override |
| `M2X_KUBE_NS` | default namespace, and restrict listing to it |
| `M2X_APP_USER` | user for application commands (default `www-data`) |
| `M2X_MAGENTO_BIN` | path to the Magento CLI (default `bin/magento`) |
| `M2X_PROD_PATTERNS` | Zsh pattern alternatives marking a context as production |
| `M2X_PROD` | treat the current context as production |
| `M2X_ASSUME_YES` | skip the production prompt |

The confirmation override must equal `1`. Other nonempty values are reported
by the local audit and do not grant approval.

## Architecture

```
mage2x.plugin.zsh     internal dispatch and m2d/m2p/m2k registration
_mage2x               completion over live targets
lib/
  core.zsh            runtime selection, target resolution, production guard
  rt-cli.zsh          docker and podman adapters
  rt-kube.zsh         kubectl adapter
  catalog.zsh         Magento shortcuts, layered over the adapters
bin/
  mage2x-install.mjs  npm installer (Node, no dependencies)
scripts/bundle.sh     builds dist/; --check is the CI drift gate
dist/
  mage2x.plugin.zsh   generated single-file build, committed
tests/run.sh          suite, runs against a fake adapter — no engine required
```

Every adapter implements the same verbs: `available`, `context`, `list`, `exec`,
`shell`, `logs`, `restart`, `forward`. Adding a runtime touches one file and no
command; adding a command touches the catalogue and no runtime.

## Documentation

- [Setup and workflows](kb/howto/setup.md)
- [Configuration and audit formats](kb/reference/configuration.md)

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
