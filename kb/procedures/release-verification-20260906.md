---
title: "Release verification on 2026-09-06"
category: procedures
service: mage2x
tags: [release, verification, provenance]
version: "1.4.0"
created: "2026-09-06"
last_updated: "2026-09-06"
description: "Executed checks for published 1.3.1 and the 1.4.0 candidate."
---

# Executed verification

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
