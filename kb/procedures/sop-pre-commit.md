---
title: "SOP: Pre-Commit Quality Gate"
category: procedures
section: procedures
service: mage2x
tags: [sop, quality-gate, pre-commit, shellcheck, tests, adapters]
version: "1.4.0"
created: "2026-08-28"
last_updated: "2026-09-24"
description: "Checks that must pass before every commit to mage2x, including the adapter-contract check that catches a half-written runtime."
---

# SOP: Pre-Commit Quality Gate

## Checklist

- [ ] `npm run lint` (ShellCheck over `tests/run.sh` and `scripts/`) -- 0 findings
- [ ] `node --check bin/mage2x-install.mjs` -- parses
- [ ] `./scripts/bundle.sh --check` -- `dist/` matches the sources
- [ ] `for f in mage2x.plugin.zsh _mage2x lib/*.zsh; do zsh -n "$f"; done` -- parse
- [ ] `./tests/run.sh` -- all pass
- [ ] Adapter contract complete (below)
- [ ] No secrets, no real host or cluster names in fixtures
- [ ] Conventional commit message and branch name
- [ ] Behaviour change reflected in README and CHANGELOG

## Quick run

```bash
scripts/release.sh --gates-only
```

The same gate `npm run release` runs before a tag, including the adapter
contract below against both the checkout and `dist/`. Full output goes to
`${TMPDIR:-/tmp}/mage2x-gates.log`.

## Adapter contract

Every runtime must implement the whole verb set. A missing verb does not fail
here; it fails the first time somebody reaches for it, which by then is on a
server.

```bash
zsh -c '
  source ./mage2x.plugin.zsh
  for rt in docker podman kube; do
    for v in available context list exec shell logs restart forward; do
      (( $+functions[_m2x_${rt}_${v}] )) || print "missing _m2x_${rt}_${v}"
    done
  done'
```

No CI runs it any more; the release script is the last place it can catch a
missing verb before a tag.

## Notes

Never pass `--no-verify`.

The suite runs against a fake adapter and needs no engine, so "docker is not
running" is never a reason to skip it. If a change cannot be tested that way, it
probably belongs in an adapter rather than in the core.
