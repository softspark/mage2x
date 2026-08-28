---
title: "SOP: Release Creation"
category: procedures
section: procedures
service: mage2x
tags: [sop, release, npm, provenance, supply-chain, versioning, adapters]
version: "1.0.0"
created: "2026-08-28"
last_updated: "2026-08-28"
description: "Version bump, changelog, quality gates, supply-chain gates, tagging and npm publish for @softspark/mage2x."
---

# SOP: Release Creation

## 1. Decide the version

Semantic Versioning. The first public release is `1.0.0`; SoftSpark modules do
not ship `0.x`.

| Change | Bump |
|---|---|
| Verb removed or renamed, adapter contract changed, guard made stricter | major |
| New runtime, new verb, new catalogue entry | minor |
| Bug fix, message wording, docs | patch |

A guard that starts refusing something it used to allow is a **major** bump even
though no signature changed: existing scripts stop working, which is the
definition of breaking. Widening the destructive-verb list counts.

## 2. Update the version

```bash
npm version --no-git-tag-version X.Y.Z
```

`package.json` is the only file carrying a version; there is no companion
manifest to keep in sync.

## 3. Write the CHANGELOG entry

`## vX.Y.Z -- Title (YYYY-MM-DD)` with Added / Changed / Fixed / Removed.
Latest version at the top, `---` between versions, bold feature names,
verb-first descriptions.

## 4. Update the README

Collapse any older `## What's New` block. Exactly one may exist at a time;
history belongs in the CHANGELOG.

## 5. Quality gates

```bash
shellcheck tests/run.sh \
  && node --check bin/mage2x-install.mjs \
  && for f in mage2x.plugin.zsh _mage2x lib/*.zsh; do zsh -n "$f" || break; done \
  && ./tests/run.sh
```

Confirm the adapter contract is complete as well — see `sop-pre-commit.md`.

## 6. Supply-chain gates

The required gates depend on the registry, because npm only attests packages
published with public access. CI checks the pairing automatically; these are the
same assertions by hand.

**Phase 1 — GitHub Packages (used for 1.0.0 internal validation):**

```bash
# Strip comments: both phases are described in the workflow's own prose, and a
# raw grep matches the comment rather than the configuration.
CODE=$(sed 's/#.*//' .github/workflows/publish.yml)
printf '%s' "$CODE" | grep -q 'registry-url:.*npm\.pkg\.github\.com'
printf '%s' "$CODE" | grep -q 'packages: write'
printf '%s' "$CODE" | grep -q -- '--provenance' && echo "WRONG: provenance cannot work here"
grep -q 'ignore-scripts=true' .npmrc
```

Provenance is unavailable for a private package. Claiming it in the workflow
would fail the publish, and — worse — a reader would believe the release is
attested when it cannot be.

**Phase 2 — public npm (current):**

```bash
CODE=$(sed 's/#.*//' .github/workflows/publish.yml)
printf '%s' "$CODE" | grep -q -- '--provenance'
printf '%s' "$CODE" | grep -q 'id-token: write'
grep -q 'ignore-scripts=true' .npmrc
```

All three must exit 0. An unsigned public release is a regression and has to be
re-published.

## 6b. Moving from Phase 1 to Phase 2

Done on 2026-08-28, ahead of the public 1.0.0. Kept as a record of what the move
touches, because getting only some of it right leaves the gates disagreeing with
the workflow. Change all of these in one commit:

1. `publish.yml`: `registry-url` to `https://registry.npmjs.org`, add
   `id-token: write`, publish with `--access public --provenance --ignore-scripts`,
   swap `secrets.GITHUB_TOKEN` for `secrets.NPM_TOKEN`
2. `package.json`: drop `publishConfig`
3. `README.md`: drop the GitHub Packages `~/.npmrc` block from Install
4. `sop-post-release-testing.md`: re-enable the provenance phase

CI's registry check flips on its own — it reads the workflow rather than a flag.

## 7. Verify what the tarball ships

```bash
npm pack --dry-run
```

`lib/` (all four files), `bin/`, `mage2x.plugin.zsh`, `_mage2x`, `LICENSE` and
`NOTICE` must all be present. npm includes `LICENSE` automatically but **not**
`NOTICE`, which is why it is listed explicitly in `files`.

## 8. Commit and tag

```bash
git commit -m "chore: release vX.Y.Z"
git tag vX.Y.Z
git push origin main --tags
```

The tag must sit on the release commit. `publish.yml` re-checks that the tag
matches `package.json` and refuses otherwise — a guard added because tagging the
wrong commit is easy and invisible until someone installs the result.

## 9. Verify

```bash
npm view @softspark/mage2x version
```

Check the GitHub Release page, then run `sop-post-release-testing.md`.

## Rollback

```bash
npm deprecate @softspark/mage2x@X.Y.Z "reason"
git tag -d vX.Y.Z && git push origin --delete vX.Y.Z
```

Deprecate rather than unpublish: npm restricts unpublishing, and consumers may
already have the version pinned.
