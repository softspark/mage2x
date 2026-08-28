# mage2x

## Overview
Run commands inside a container workload over docker, podman or kubectl. Refuses
ambiguous targets, guards destructive verbs on production. Successor to
mage2docker.

## Tech Stack
- **Plugin**: zsh (Oh My Zsh custom plugin), no runtime dependencies
- **Installer**: Node.js >= 18, ESM, no dependencies — workstations only
- **Test**: bash harness against a fake runtime adapter; no engine needed
- **Lint**: ShellCheck for the test harness, `zsh -n` for zsh sources

## Commands
```bash
npm run lint        # ShellCheck
npm run typecheck   # node --check on the installer
npm test            # full suite, no docker or cluster required
```

## Key Conventions
- Conventional Commits (feat:, fix:, refactor:, test:, docs:, chore:)
- Branch names: feat/, fix/, refactor/, docs/, test/
- Everything user-facing is in English
- **The adapter contract is the boundary.** Nothing outside `lib/rt-*.zsh` may
  assume a particular engine; adding a runtime touches one file and no verb
- **Ambiguity is an error.** A fragment matching several workloads is never
  resolved by picking one
- **Only destructive verbs prompt.** A guard that fires on reads is dismissed
  reflexively and protects nothing
- `${x:+-flag $x}` expands to ONE word in zsh — build flag arrays instead, or
  the engine receives `-u www-data` as a single argument
- `(#i)` needs `extendedglob`, which `emulate -L zsh` turns off; lowercase with
  `${x:l}` instead, or the pattern silently never matches
- A function whose stdout is its return value must send every diagnostic to
  stderr, or the message vanishes into the command substitution

## Layout
```
mage2x.plugin.zsh   entry point, verb dispatch, m2d shim
_mage2x             completion
lib/core.zsh        runtime selection, resolution, production guard
lib/rt-cli.zsh      docker + podman
lib/rt-kube.zsh     kubectl
lib/catalog.zsh     Magento shortcuts
bin/                npm installer
tests/run.sh        suite
```
