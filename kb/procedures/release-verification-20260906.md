---
title: "Release verification on 2026-09-06"
category: procedures
service: mage2x
tags: [release, verification, provenance]
version: "1.4.0"
created: "2026-09-06"
last_updated: "2026-09-06"
description: "Published 1.4.0 verification, pre-release gates and earlier smoke evidence."
---

# Executed verification

## Published 1.4.0

Published on 2026-09-06 from commit `fde2884a8897a46f9e5c56ae515caae820155916`.

- [Release](https://github.com/softspark/mage2x/releases/tag/v1.4.0)
- [Exact release-head CI](https://github.com/softspark/mage2x/actions/runs/34051726785): success
- [Publish workflow](https://github.com/softspark/mage2x/actions/runs/34052343241): success

Registry metadata returned the exact version and SLSA v1 provenance. A fresh
consumer lockfile installed gitspace 1.3.0, mage2x 1.4.0 and jira-mcp 1.11.0 with
scripts disabled. Cryptographic verification completed successfully:
**4 verified registry signatures and 3 verified attestations**. This is a new
verification of the released artifacts, separate from the older smoke below.

All three packages contained their expected runtime files, LICENSE and NOTICE;
tests, KB and .github were absent. Syntax checks preceded CLI execution.

The installed plugin passed help, all 24 adapter-function checks, ambiguity
refusal, production refusal for empty/0/false overrides, and JSON/SARIF audits.
The installer symlink/refusal checks passed without changing the real .zshrc.
A read-only Docker smoke returned MAGE2X_1_4_0_PUBLISHED_READ_OK from rag-mcp-core.

## Earlier published-version smoke


The published package `@softspark/mage2x@1.3.1` was installed as an
exact dependency in a temporary npm project, with `--ignore-scripts` and a
consumer lockfile. The isolated project also contained the other two audited
CLI packages. `npm audit signatures --registry https://registry.npmjs.org`
exited 0: **4 verified registry signatures and 3 verified attestations**
(the fourth dependency is commander).

Published artifact checks passed: expected version, LICENSE, NOTICE and runtime
entry points present; tests, KB and .github absent. JavaScript/Zsh syntax
checks ran before executing CLI smoke commands.

Installer `path` and plugin help passed. All 24 adapter functions were present.
A fake engine confirmed ambiguous-target refusal, noninteractive production
restart refusal and unguarded reads. A real Docker adapter command executed
only `echo MAGE2X_PUBLISHED_READ_OK` in the existing rag-mcp-core container,
using its root account; it returned the exact marker. No runtime mutation ran.
The previous complete 1.3.1 installation run remains recorded in the SOP.

## Pre-release validation

Version 1.4.0 was validated locally before publication. Its new
audit commands are tested against real temporary filesystem/configuration
fixtures, including secret redaction and SARIF output. Existing text behavior
is retained except for documented repairs.

After publication, repeat this record against the new registry version and run
its post-release SOP. Do not carry the 1.3.1 cryptographic result forward
as evidence for a future 1.4.0 artifact.

Candidate gates on 2026-09-06: ShellCheck, installer syntax, Zsh syntax,
regenerated distribution drift check and the full suite passed (65 tests).
Tests cover JSON/SARIF output and refusal of unattended production restarts
with 0, false, yes and an arbitrary nonempty override; only exact 1 approves.
