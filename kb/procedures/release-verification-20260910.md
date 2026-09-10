---
title: "Release verification on 2026-09-10"
category: procedures
service: mage2x
tags: [release, verification, provenance, completion]
version: "2.0.0"
created: "2026-09-10"
last_updated: "2026-09-10"
description: "Release 2.0.0 publication and verification evidence."
---

# Release 2.0.0

Release commit: `f3677c4f80bcbf771120d2bd24a008edd383cbff`.

- [Exact release-commit CI](https://github.com/softspark/mage2x/actions/runs/34453192961): passed.
- [Publish workflow](https://github.com/softspark/mage2x/actions/runs/34453450837): passed.
- [GitHub Release](https://github.com/softspark/mage2x/releases/tag/v2.0.0): published.

The release removes `m2x`; callers must choose `m2d`, `m2p` or `m2k`.
The Podman and Kubernetes shortcuts are registered only when their CLI exists.

## Candidate verification

All 92 tests passed. ShellCheck, installer and Zsh syntax checks, generated
bundle consistency and npm tarball contents passed. CI checked the same commit
on Linux and macOS. An independent review found no release blocker.

An interactive Zsh session confirmed `m2<TAB>` completes to `m2d` when the
optional CLIs are absent, while `$M2X_<TAB>` still completes configuration
variables. Tests cover every CLI-presence combination and reload cleanup.

The tarball contains 13 files, including all runtime modules, the standalone
bundle, completion, installer, LICENSE and NOTICE. Its SHA-1 is
`4695dc6a68a30378abbaa4342410671e7a7a9a2b`.

## Publication verification

npm accepted `@softspark/mage2x@2.0.0` at 08:07 UTC and reported that the package
was being processed before becoming available. The workflow generated signed
provenance and logged it at
[Sigstore entry 2780162012](https://search.sigstore.dev/?logIndex=2780162012).

The registry subsequently returned version `2.0.0` and `latest: 2.0.0`, with
SLSA v1 provenance. A fresh consumer project installed that exact version with
scripts disabled and verified the released artifact:

- `npm audit signatures`: **1 verified registry signature and 1 verified attestation**.
- Runtime file boundaries and JavaScript/Zsh syntax checks passed before execution.
- All 12 published non-manifest files match the release checkout byte for byte;
  the package manifest reports version 2.0.0.
- The installer linked the package, backed up a temporary `.zshrc`, and refused
  to replace a real directory. The workstation's installed plugin was not changed.
- Help, CLI-dependent shortcut registration, all 24 adapter functions, ambiguity
  refusal, and JSON/SARIF audits passed from the installed package.
- Production restart was refused for empty, `0` and `false` confirmation values;
  a read command still executed on the same simulated production context.
- The published Docker adapter executed only `echo` in the existing
  `rag-mcp-core` container, returning `MAGE2X_2_0_0_PUBLISHED_READ_OK`.

Verification files and the consumer lockfile are retained under
`/private/tmp/mage2x-release-2.0.0/`. No runtime mutation was needed.
