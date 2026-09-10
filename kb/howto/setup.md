---
title: "Install and use mage2x"
category: howto
service: mage2x
tags: [howto, configuration, audit]
version: "2.0.0"
created: "2026-09-06"
last_updated: "2026-09-10"
description: "Install and use mage2x."
---

# Install and use mage2x

1. Follow [README installation](../../README.md#install) to load the
   multi-file Zsh plugin or the generated single-file distribution.
2. Run `m2d audit` to inspect local configuration without contacting a
   container engine. Clear an unintended `M2X_ASSUME_YES` override.
3. Use `m2d context`, `m2p context` or `m2k context` to inspect the
   chosen engine and its production classification.
4. List targets with that same command without arguments. Copy an exact name
   if a fragment is ambiguous.
5. Run an application command, for example `m2d php cache` or
   `m2k namespace/pod:php mage indexer:status`. These use the configured
   application user (default `www-data`).
6. Use `m2d php logs --tail 20` for logs. On a production context,
   destructive verbs such as `restart` require confirmation unless the
   explicit automation override is exactly `1`.

`m2d` replaces `m2x` and selects Docker. `m2p` and `m2k` are registered only
when `podman` and `kubectl`, respectively, are on PATH when the plugin loads.
Run `exec zsh` after installing or removing either CLI to refresh the available
commands and completions. Engine reachability does not affect registration.
An explicit `--runtime` can override the command's engine selection.

Command-position TAB hides `M2X_*` variables without removing configuration:
assignments such as `M2X_APP_USER=app m2d php shell` and variable expansion
completion such as `$M2X_<TAB>` still work.

If the container has no `www-data`, set `M2X_APP_USER` to an account it
actually contains. A missing user is not proof of an engine problem.
Do not use `exec` to assume a command is protected by the production guard:
the guard classifies mage2x verbs, not arbitrary shell command contents.

Changes under `lib/` or to the entry point require `npm run bundle`.
Run `npm run lint`, `npm run typecheck` and `npm test`; the test
suite checks the generated distribution and runs with fake engines.
No Docker daemon is required for unit tests. The publish workflow runs those
checks explicitly before `npm publish --ignore-scripts --provenance`;
the package has no lifecycle hooks.
