# mage2x

## Overview
Run commands inside a container workload over docker, podman or kubectl. Refuses
ambiguous targets, guards destructive verbs on production.

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
npm run bundle      # regenerate dist/ after any change under lib/ or the plugin
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
- Escape parens in parameter substitution: `${line#plugins=\(}`. Unescaped they
  are a glob pattern and the substitution dies with `bad pattern`
- `_describe` takes the NAME of an array, never a literal. A parenthesised
  string is split on whitespace, so every word of every description becomes its
  own candidate — and nothing here catches it: `zsh -n` passes, and completion
  is the one surface the suite cannot drive. Grep for the shape instead
- **`M2X_*` is the public namespace and nothing else may live there.** zsh
  offers parameter names in command position, so a stray internal is advertised
  by TAB as configuration. Internals are `_M2X_*`; a test pins the public set to
  the README table in both directions
- `dist/` is generated and committed. Regenerate it in the same commit as any
  source change, or the drift gate fails — and downstream ships a stale copy
- A destructive step and its bookkeeping must not be able to half-succeed: the
  plugin removal ran, the `.zshrc` rewrite crashed, and the shell was left
  pointing at nothing

## Layout
```
mage2x.plugin.zsh   entry point, verb dispatch, migrate, m2d/m2p/m2k
_mage2x             completion
lib/core.zsh        runtime selection, resolution, production guard
lib/rt-cli.zsh      docker + podman
lib/rt-kube.zsh     kubectl
lib/catalog.zsh     Magento shortcuts
bin/                npm installer
tests/run.sh        suite
```
