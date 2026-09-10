---
title: "SOP: Post-Release Testing"
category: procedures
section: procedures
service: mage2x
tags: [sop, testing, smoke-test, provenance, npm, post-release, runtimes]
version: "2.0.0"
created: "2026-08-28"
last_updated: "2026-09-10"
description: "Smoke-test a published @softspark/mage2x release from npm in an isolated HOME, including the production guard and at least one real container runtime."
---

# SOP: Post-Release Testing

Run once `publish.yml` goes green. Use a throwaway home directory through
command-scoped `HOME` values so the current shell retains its normal home.

A fresh package answers `404` from the registry for a minute or two after a
successful publish. Poll rather than diagnose:

```bash
RELEASE_VERSION=2.0.0
for attempt in 1 2 3; do
  printf 'Registry check %s for %s\n' "$attempt" "$RELEASE_VERSION"
  if npm view "@softspark/mage2x@$RELEASE_VERSION" version; then break; fi
  if [ "$attempt" -eq 3 ]; then
    printf 'Three consecutive failures; inspect the publish workflow before retrying.\n'
    break
  fi
  sleep 60
done
```

## Phase 1 — isolated install

```bash
SMOKE=$(mktemp -d)
SMOKE_HOME="$SMOKE/home"
mkdir -p "$SMOKE_HOME"
HOME="$SMOKE_HOME" npm install -g --prefix "$SMOKE/npm" "@softspark/mage2x@$RELEASE_VERSION"
```

## Phase 2 — installer

```bash
HOME="$SMOKE_HOME" "$SMOKE/npm/bin/mage2x-install" path
HOME="$SMOKE_HOME" ZSH_CUSTOM="$SMOKE_HOME/omz" "$SMOKE/npm/bin/mage2x-install" install --yes
test -L "$SMOKE_HOME/omz/plugins/mage2x" || echo "FAIL: plugin not linked"
```

Use a second throwaway `ZSH_CUSTOM` directory with an existing real
`plugins/mage2x` directory and confirm installation **refuses** to replace it.
With no `~/.zshrc`, it must say so and carry on.

## Phase 3 — the plugin loads and dispatches

```bash
PLUG="$SMOKE_HOME/omz/plugins/mage2x/mage2x.plugin.zsh"
HOME="$SMOKE_HOME" zsh -c "source '$PLUG'; m2d --help"
HOME="$SMOKE_HOME" zsh -c "source '$PLUG'; m2d context"
```

Verify the adapter contract in the *published* package, not the checkout — a
file missing from `files` in `package.json` breaks exactly here:

```bash
HOME="$SMOKE_HOME" zsh -c "source '$PLUG'
  for rt in docker podman kube; do
    for v in available context list exec shell logs restart forward; do
      (( \$+functions[_m2x_\${rt}_\${v}] )) || print \"MISSING _m2x_\${rt}_\${v}\"
    done
  done"
```

## Phase 4 — the guard, against a fake runtime

The guard is the one feature whose failure is silent, so it is tested with a
stub rather than trusted.

```bash
cat > "$SMOKE/fake.zsh" <<'FAKE'
_m2x_fake_available() { return 0 }
_m2x_fake_context()   { print -r -- "${FAKE_CONTEXT:-fake:local}" }
_m2x_fake_list()      { print -l -- web web-backup }
_m2x_fake_restart()   { print -r -- "RESTARTED $1" }
_m2x_fake_exec()      { local t=$1 u=$2; shift 2; print -r -- "EXEC $t $*" }
FAKE

# ambiguity is refused
HOME="$SMOKE_HOME" zsh -c "source '$SMOKE/fake.zsh'; source '$PLUG'; m2d --runtime fake we exec true" 2>&1 \
  | grep -q ambiguous && echo "OK ambiguity" || echo "FAIL ambiguity"

# destructive verb on a production-looking context, no tty
HOME="$SMOKE_HOME" zsh -c "source '$SMOKE/fake.zsh'; source '$PLUG'
        FAKE_CONTEXT=k8s:acme-production m2d --runtime fake web restart" </dev/null 2>&1 \
  | grep -q refusing && echo "OK guard" || echo "FAIL guard"

# reads are never guarded
READ_OUTPUT=$(HOME="$SMOKE_HOME" zsh -c "source '$SMOKE/fake.zsh'; source '$PLUG'
        FAKE_CONTEXT=k8s:acme-production m2d --runtime fake web exec true" </dev/null 2>&1)
if [ "$?" -eq 0 ] && printf '%s\n' "$READ_OUTPUT" | grep -qx 'EXEC web true'; then
  echo "OK read unguarded"
else
  echo "FAIL: read did not execute"
fi
```

## Phase 5 — one real runtime

The fake adapter proves the logic; it proves nothing about the engines. Run at
least one for real, on a container you own:

```bash
HOME="$SMOKE_HOME" zsh -c "source '$PLUG'; m2d"                      # lists Docker containers
HOME="$SMOKE_HOME" zsh -c "source '$PLUG'; m2d <name> exec echo ok"  # replace <name>; prints ok
```

`m2d` selects Docker. Use `m2p` for Podman or `m2k` for kubectl; these shortcuts
exist only when their CLI is installed. `m2x` is removed in 2.0.0. Confirm the
loaded shell has no `m2x` function and that `m2p`/`m2k` availability matches the
installed CLIs. Fake adapter tests need explicit `--runtime fake`, because
`M2X_RUNTIME` does not override the command's selected runtime.

On a cluster, also check that `restart` names the workload it is about to roll
and says it affects every replica — without confirming it.

## Phase 6 — supply chain (mandatory)

```bash
HOME="$SMOKE_HOME" npm view "@softspark/mage2x@$RELEASE_VERSION" --json | python3 -c \
  "import json,sys; d=json.load(sys.stdin); \
   assert d['dist']['attestations']['provenance']['predicateType']=='https://slsa.dev/provenance/v1'; \
   print('PROVENANCE OK')"
```

`npm audit signatures` reads a lockfile, and the install in Phase 1 is a global
prefix, which has none: run as written there it answers "found no installed
dependencies to audit" and exits non-zero, which reads like a failed gate rather
than the wrong working directory. Give it a throwaway project:

```bash
mkdir -p "$SMOKE/auditproj"
(
  cd "$SMOKE/auditproj" || exit
  HOME="$SMOKE_HOME" npm init -y >/dev/null
  HOME="$SMOKE_HOME" npm install "@softspark/mage2x@$RELEASE_VERSION" --ignore-scripts
  HOME="$SMOKE_HOME" npm audit signatures --registry https://registry.npmjs.org
)
```

Both lines of the result matter: a verified **registry signature** says the
tarball is the one npm holds, and a verified **attestation** says CI built it.

## Phase 7 — tarball contents

```bash
PKG="$SMOKE/npm/lib/node_modules/@softspark/mage2x"
for f in mage2x.plugin.zsh _mage2x dist/mage2x.plugin.zsh lib/core.zsh lib/rt-cli.zsh lib/rt-kube.zsh \
         lib/catalog.zsh bin/mage2x-install.mjs LICENSE NOTICE; do
  test -f "$PKG/$f" || echo "FAIL: missing $f"
done
for f in tests kb CLAUDE.md SECURITY.md .github; do
  test -e "$PKG/$f" && echo "FAIL: should not ship: $f"
done
```

## Phase 8 — cleanup

Keep `$SMOKE` until the release evidence has been recorded. Remove it only after
reviewing its contents and verifying a backup of anything to retain, with explicit
approval for deletion. The current shell's `HOME` was not changed.

## Run log

| Version | Date | Result |
|---|---|---|
| 2.0.0 | 2026-09-10 | Passed: published package, installer, command registration, production guard, Docker echo, registry signature and provenance attestation. See [verification record](release-verification-20260910.md). |
| 1.3.1 | 2026-09-03 | Pass, first run of this SOP. Phases 1-7 green: installer links and refuses a real directory, the published package carries the whole adapter contract (24/24), the guard refuses a production restart and leaves reads alone, docker lists 26 targets and `exec` prints `ok`, provenance verifies with a registry signature and an attestation, and nothing outside `files` shipped. Completion returned 25 targets on a host with `timeout` present, which is the release. Two notes: Phase 6's `npm audit signatures` needed a project with a lockfile and is now written that way, and Phase 5's `exec` fails on a container with no `www-data` — the documented `M2X_APP_USER` default, not a defect. |

## Verification on 2026-09-06

Published 1.4.0: exact release-head CI and publish workflow passed;
registry version, provenance, cryptographic signatures and installed CLI smoke
were verified. See [the executed publication record](release-verification-20260906.md#published-140).

The published 1.3.1 package was checked separately from the unshipped
1.4.0 candidate. See [the execution record](release-verification-20260906.md)
for completed checks and remaining release checks.
