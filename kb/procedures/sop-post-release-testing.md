---
title: "SOP: Post-Release Testing"
category: procedures
section: procedures
service: mage2x
tags: [sop, testing, smoke-test, provenance, npm, post-release, runtimes]
version: "1.0.0"
created: "2026-08-28"
last_updated: "2026-08-28"
description: "Smoke-test a published @softspark/mage2x release from npm in an isolated HOME, including the production guard and at least one real container runtime."
---

# SOP: Post-Release Testing

Run once `publish.yml` goes green. Everything happens under a throwaway `HOME`.
Open a fresh shell afterwards — `HOME` is overridden for the duration.

A fresh package answers `404` from the registry for a minute or two after a
successful publish. Poll rather than diagnose:

```bash
until curl -sfo /dev/null https://registry.npmjs.org/@softspark%2Fmage2x; do sleep 20; done
```

## Phase 1 — isolated install

```bash
export SMOKE=$(mktemp -d)
export HOME="$SMOKE/home"
mkdir -p "$HOME"
npm install -g --prefix "$SMOKE/npm" @softspark/mage2x@X.Y.Z
```

## Phase 2 — installer

```bash
"$SMOKE/npm/bin/mage2x-install" path
ZSH_CUSTOM="$HOME/omz" "$SMOKE/npm/bin/mage2x-install" install --yes
test -L "$HOME/omz/plugins/mage2x" || echo "FAIL: plugin not linked"
```

Replace the symlink with a real directory and confirm the second run **refuses**
rather than deleting it. With no `~/.zshrc`, it must say so and carry on.

## Phase 3 — the plugin loads and dispatches

```bash
PLUG="$HOME/omz/plugins/mage2x/mage2x.plugin.zsh"
zsh -c "source '$PLUG'; m2x --help"
zsh -c "source '$PLUG'; m2x context"
```

Verify the adapter contract in the *published* package, not the checkout — a
file missing from `files` in `package.json` breaks exactly here:

```bash
zsh -c "source '$PLUG'
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
zsh -c "source '$SMOKE/fake.zsh'; source '$PLUG'; M2X_RUNTIME=fake m2x we exec true" 2>&1 \
  | grep -q ambiguous && echo "OK ambiguity" || echo "FAIL ambiguity"

# destructive verb on a production-looking context, no tty
zsh -c "source '$SMOKE/fake.zsh'; source '$PLUG'
        FAKE_CONTEXT=k8s:acme-production M2X_RUNTIME=fake m2x web restart" </dev/null 2>&1 \
  | grep -q refusing && echo "OK guard" || echo "FAIL guard"

# reads are never guarded
zsh -c "source '$SMOKE/fake.zsh'; source '$PLUG'
        FAKE_CONTEXT=k8s:acme-production M2X_RUNTIME=fake m2x web exec true" </dev/null 2>&1 \
  | grep -q PRODUCTION && echo "FAIL: read prompted" || echo "OK read unguarded"
```

## Phase 5 — one real runtime

The fake adapter proves the logic; it proves nothing about the engines. Run at
least one for real, on a container you own:

```bash
zsh -c "source '$PLUG'; m2x"                      # lists containers
zsh -c "source '$PLUG'; m2x <name> exec echo ok"  # prints ok
```

On a cluster, also check that `restart` names the workload it is about to roll
and says it affects every replica — without confirming it.

## Phase 6 — supply chain (mandatory)

```bash
npm view "@softspark/mage2x@X.Y.Z" --json | python3 -c \
  "import json,sys; d=json.load(sys.stdin); \
   assert d['dist']['attestations']['provenance']['predicateType']=='https://slsa.dev/provenance/v1'; \
   print('PROVENANCE OK')"
npm audit signatures --registry https://registry.npmjs.org
```

## Phase 7 — tarball contents

```bash
PKG="$SMOKE/npm/lib/node_modules/@softspark/mage2x"
for f in mage2x.plugin.zsh _mage2x lib/core.zsh lib/rt-cli.zsh lib/rt-kube.zsh \
         lib/catalog.zsh bin/mage2x-install.mjs LICENSE NOTICE; do
  test -f "$PKG/$f" || echo "FAIL: missing $f"
done
for f in tests kb CLAUDE.md SECURITY.md .github; do
  test -e "$PKG/$f" && echo "FAIL: should not ship: $f"
done
```

## Phase 8 — cleanup

Delete `$SMOKE` and open a new shell.

## Run log

| Version | Date | Result |
|---|---|---|
| | | |
