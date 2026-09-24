---
title: "SOP: Release Creation"
category: procedures
section: procedures
service: mage2x
tags: [sop, release, npm, provenance, supply-chain, versioning, adapters, local-gates]
version: "2.0.0"
created: "2026-08-28"
last_updated: "2026-09-24"
description: "Version bump, changelog, bundle, and the single release command that gates, tags and publishes @softspark/mage2x."
---

# SOP: Release Creation

```bash
npm run release -- X.Y.Z             # gates, Linux run, pack smoke, tag, push, watch publish
npm run release -- X.Y.Z --dry-run   # everything up to the tag, then prints the rest
```

`scripts/release.sh` is the only supported way to create a release tag. GitHub
Actions no longer tests anything: there is no CI on pushes or pull requests,
and `publish.yml` only turns a tag into an npm package and a GitHub Release. A
tag made by hand ships whatever the commit holds, gated or not. The shared model
is the SoftSpark SOP "Local Release Gates, Publish-Only CI"; this page keeps
what is specific to mage2x.

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

## 2. Prepare the release commit

The script checks these; it does not write them.

```bash
npm version --no-git-tag-version X.Y.Z
npm run bundle
```

`package.json` is the package version source. `dist/mage2x.plugin.zsh` carries
the version in its header, so it is regenerated after the bump; the script
refuses a bundle built for another version. Update the current release metadata
in affected KB documents and preserve version numbers in historical verification
records.

- **CHANGELOG:** `## vX.Y.Z -- Title (YYYY-MM-DD)` with Added / Changed / Fixed /
  Removed. Latest version at the top, `---` between versions, bold feature
  names, verb-first descriptions.
- **README:** collapse any older `## What's New` block. Exactly one may exist at
  a time; history belongs in the CHANGELOG. Move the pinned
  `raw.githubusercontent.com/softspark/mage2x/vX.Y.Z/dist/...` URL to the new tag.

```bash
git commit -am "chore: release vX.Y.Z"
git push origin main
```

## 3. Release

```bash
npm run release -- X.Y.Z
```

It stops at the first failure. Logs go to `${TMPDIR:-/tmp}/mage2x-release-X.Y.Z/`.

| Step | What it checks or does |
|---|---|
| 1. Preconditions | on `main`, clean tree, `main` equals `origin/main` after a fetch, `X.Y.Z` is semver, `vX.Y.Z` exists neither locally nor on origin |
| 2. Version and notes | `package.json` and the `dist/` header are `X.Y.Z`, CHANGELOG has `## vX.Y.Z `, `HEAD` is `chore: release vX.Y.Z` |
| 3. Gates | `npm run lint` (ShellCheck over `tests/run.sh` and `scripts/`), `npm run typecheck`, `./scripts/bundle.sh --check`, `zsh -n` on every zsh source and the bundle, the adapter contract against the checkout and against `dist/` alone, `npm test`, required files, supply-chain gates |
| 4. Linux run | the same gate in a throwaway `node:24` container, repository copied in, run as the non-root `node` user |
| 5. Build and smoke | `npm pack`; the tarball must carry `lib/`, `bin/`, `dist/mage2x.plugin.zsh`, both zsh sources, `LICENSE` and `NOTICE`; installed into a scratch prefix, `mage2x-install path` must print a directory holding the plugin |
| 6. Tag and push | lightweight tag `vX.Y.Z` on `HEAD`, push `main`, then `git push origin refs/tags/vX.Y.Z` |
| 7. Watch publish | `gh run watch` on the tag's `publish.yml` run, then `npm view @softspark/mage2x@X.Y.Z` and the GitHub Release |

**Why the Linux run applies here.** The plugin and its adapters are zsh, the
suite and the bundler are bash, and ShellCheck, zsh and coreutils behave
differently on macOS and Linux. The old CI ran the suite on both systems for
this reason. It needs Docker running; no container engine is needed inside it,
because the suite uses a fake adapter.

**The bundle is checked twice on purpose.** A generated artefact nobody
regenerates is the quiet failure: the sources move, `dist/` does not, and the
pinned copy shipped to S3 is silently a release behind. `bundle.sh --check`
catches drift; the adapter contract against `dist/` alone proves the bundle is a
working plugin without the multi-file checkout next to it.

**npm keeps NOTICE out on its own.** npm includes `LICENSE` automatically but
**not** `NOTICE`, which is why it is listed explicitly in `files` and why step 5
refuses a tarball without it.

## Supply-chain gates

npm only attests packages published with public access. Step 3 reads
`publish.yml` with comments stripped (the workflow's own prose mentions both
flags) and requires `registry-url` on `registry.npmjs.org`, `--provenance`,
`id-token: write`, and `ignore-scripts=true` in `.npmrc`. An unsigned public
release is a regression and has to be re-published.

### Record: moving from GitHub Packages to public npm

Done on 2026-08-28, ahead of the public 1.0.0. Kept because getting only some of
it right leaves the gates disagreeing with the workflow. The move touched, in
one commit:

1. `publish.yml`: `registry-url` to `https://registry.npmjs.org`, add
   `id-token: write`, publish with `--access public --provenance --ignore-scripts`,
   swap `secrets.GITHUB_TOKEN` for `secrets.NPM_TOKEN`
2. `package.json`: drop `publishConfig`
3. `README.md`: drop the GitHub Packages `~/.npmrc` block from Install
4. `sop-post-release-testing.md`: re-enable the provenance phase

Provenance is unavailable for a private package: claiming it in the workflow
fails the publish, and a reader would believe the release is attested when it
cannot be.

## What publish.yml still does

On a `v*` tag: checkout, Node setup, a check that the tag equals
`package.json`, `npm publish --access public --provenance --ignore-scripts`, and
the GitHub Release. Nothing is built there: `dist/` is committed and the release
script already proved it matches the sources.

## 4. Verify

The script already confirmed the registry version and the GitHub Release. Run
`sop-post-release-testing.md` against the published package.

## Rollback

```bash
npm deprecate @softspark/mage2x@X.Y.Z "reason"
```

Deprecate rather than unpublish: npm restricts unpublishing, and consumers may
already have the version pinned. Deleting the tag does not delete what was
published, and a Terraform-pinned `dist/` URL keeps pointing at it; repoint
consumers to the previous tag and fix forward through the same script.
