---
title: "Mage2x configuration and local audit"
category: reference
service: mage2x
tags: [reference, configuration, audit]
version: "1.4.0"
created: "2026-09-06"
last_updated: "2026-09-06"
description: "Mage2x configuration and local audit."
---

# Configuration and local audit

`m2x` selects Docker, Podman or kubectl through an adapter. Use
`m2d`, `m2p`, `m2k` or `--runtime` to pin the engine. A fragment
matching multiple workloads is refused.

| Variable | Meaning |
|---|---|
| M2X_RUNTIME | Adapter name, normally docker, podman or kube |
| M2X_KUBE_NS | Namespace used by the Kubernetes adapter |
| M2X_APP_USER | Application command user, default www-data |
| M2X_MAGENTO_BIN | Magento CLI path, default bin/magento |
| M2X_PROD_PATTERNS | Zsh pattern alternatives, default prod\|production\|prd\|live |
| M2X_PROD | Any nonempty value forces production classification |
| M2X_ASSUME_YES | Only the exact value 1 bypasses production confirmation |

Production detection is a name heuristic, not access control. Engine credentials
and cluster RBAC remain authoritative. The production guard prompts for the
destructive verbs configured in the plugin; arbitrary `exec` commands are
not classified by their contents.

## Audit contract

`m2x audit [--json|--sarif]` inspects the loaded shell's local configuration.
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
authorization or the actual remote production context. Use `m2x context`
for a runtime inspection.

`m2x audit --sarif > audit.sarif` produces input for GitHub's
`github/codeql-action/upload-sarif` action with `sarif_file: audit.sarif`.
Preserve the audit exit status while arranging upload on either 0 or 1.
