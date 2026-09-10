---
title: "Mage2x configuration and local audit"
category: reference
service: mage2x
tags: [reference, configuration, audit]
version: "2.0.0"
created: "2026-09-06"
last_updated: "2026-09-10"
description: "Mage2x configuration and local audit."
---

# Configuration and local audit

`m2d` replaces `m2x` and selects Docker. `m2p` selects Podman and `m2k`
selects kubectl; these two commands are registered only if their executables
are on PATH when the plugin loads. `m2d` is always registered. Reload the shell
with `exec zsh` after installing or removing an engine CLI. Registration does
not probe daemon or cluster reachability. An explicit `--runtime` overrides
the command's engine pin. A fragment matching multiple workloads is refused.
Runtime selection applies to one invocation and does not change the shell's
`M2X_RUNTIME` value.

| Variable | Meaning |
|---|---|
| M2X_RUNTIME | Compatible runtime setting; command pins take precedence, explicit --runtime overrides them |
| M2X_KUBE_NS | Namespace used by the Kubernetes adapter |
| M2X_APP_USER | Application command user, default www-data |
| M2X_MAGENTO_BIN | Magento CLI path, default bin/magento |
| M2X_PROD_PATTERNS | Zsh pattern alternatives, default prod\|production\|prd\|live |
| M2X_PROD | Any nonempty value forces production classification |
| M2X_ASSUME_YES | Only the exact value 1 bypasses production confirmation |

The `M2X_*` environment names remain supported. They are omitted only from
command-position TAB suggestions; assignments and variable expansion completion
(for example `$M2X_<TAB>`) remain available.

Production detection is a name heuristic, not access control. Engine credentials
and cluster RBAC remain authoritative. The production guard prompts for the
destructive verbs configured in the plugin; arbitrary `exec` commands are
not classified by their contents.

## Audit contract

`m2d audit [--json|--sarif]` inspects the loaded shell's local configuration.
It never probes an adapter, contacts an engine, reads kubeconfig, runs a
credential helper, or prints environment values. It checks the registered
adapter, executable presence on PATH, the production-pattern setting, the
guard array and a confirmation bypass.

JSON contains `schemaVersion: 1`, `tool`, `scope: local-configuration`,
`runtime` (auto, docker, podman, kube or custom), `runtimeProbed: false`,
`productionForced` and `findings`. Each finding has `ruleId` and `level`.
SARIF 2.1.0 carries the same findings as results. There are no source locations:
the inspected settings exist in the current shell, not in an invented file.

| Rule | Meaning |
|---|---|
| unknown-runtime | Selected adapter has no availability function |
| runtime-binary-missing | Required engine binary is absent from PATH |
| confirmation-bypassed | M2X_ASSUME_YES=1 disables confirmation |
| invalid-confirmation-override | Nonempty override is not 1 and grants no approval |
| empty-production-patterns | Context detection has no production pattern |
| broken-production-guard | Destructive-verb array is empty or invalid |

All are warnings. Exit 0 means no local findings; 1 means findings; 2 means
invalid audit arguments. A clean audit does not establish engine reachability,
authorization or the actual remote production context. Use `m2d context`
for a runtime inspection.

`m2d audit --sarif > audit.sarif` produces input for GitHub's
`github/codeql-action/upload-sarif` action with `sarif_file: audit.sarif`.
Preserve the audit exit status while arranging upload on either 0 or 1.
