#!/usr/bin/env bash
# mage2x test suite.
#
# Runs without docker, podman or a cluster: a fake runtime adapter stands in, so
# CI exercises resolution, the production guard and the catalogue rather than
# the container engines themselves. The adapters are thin by design; the logic
# worth testing sits above them.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
head_() { printf '\n\033[36m%s\033[0m\n' "$1"; }

command -v zsh >/dev/null 2>&1 || { echo "zsh is required"; exit 1; }

SANDBOX="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

# A fake adapter with a deliberately awkward target list: two names where one is
# a prefix of the other, and a sidecar whose name contains the service it backs
# up — the shape that made `name=mysql` select `mysql-backup` in production.
cat > "$SANDBOX/fake.zsh" <<'FAKE'
typeset -g FAKE_CALLS=""
_m2x_fake_available() { return 0 }
_m2x_fake_context()   { print -r -- "${FAKE_CONTEXT:-fake:local}" }
_m2x_fake_list()      { print -l -- mysql mysql-backup php php-fpm solo }
_m2x_fake_exec()      { local t=$1 u=$2; shift 2; print -r -- "EXEC t=$t u=$u cmd=$*" }
_m2x_fake_shell()     { print -r -- "SHELL t=$1 u=$2 sh=$3" }
_m2x_fake_logs()      { local t=$1; shift; print -r -- "LOGS t=$t args=$*" }
_m2x_fake_restart()   { print -r -- "RESTART t=$1" }
_m2x_fake_forward()   { print -r -- "FORWARD t=$1 spec=$2" }
FAKE

# shellcheck disable=SC2016  # $-expansion belongs to the inner zsh, not here
run() {
  zsh -c "
    source '$SANDBOX/fake.zsh'
    source '$REPO/mage2x.plugin.zsh'
    M2X_RUNTIME=fake
    $1
  " 2>&1
}

# --------------------------------------------------------------------------
head_ "target resolution"

out=$(run 'm2x solo exec echo hi')
case "$out" in *"t=solo"*) ok "an unambiguous fragment resolves" ;;
               *) bad "unambiguous fragment failed" "$out" ;; esac

out=$(run 'm2x mysql exec echo hi')
case "$out" in
  *"t=mysql u="*) ok "an exact name wins over a longer partial match" ;;
  *) bad "exact match lost to a partial one" "$out" ;;
esac

# The incident this tool exists to prevent: a fragment matching a sidecar.
# 'ph' rather than 'php', which is an exact name and must resolve.
out=$(run 'm2x ph exec echo hi')
case "$out" in
  *ambiguous*) ok "an ambiguous fragment is refused" ;;
  *) bad "ambiguous fragment was resolved anyway" "$out" ;;
esac

case "$out" in
  *php-fpm*) ok "the candidates are listed on refusal" ;;
  *) bad "refusal did not show candidates (stdout/stderr mix-up?)" "$out" ;;
esac

out=$(run 'm2x php exec echo hi')
case "$out" in
  *"t=php u="*) ok "an exact name is not treated as ambiguous" ;;
  *) bad "exact name was refused as ambiguous" "$out" ;;
esac

out=$(run 'm2x nothing-like-this exec echo hi')
case "$out" in *"no target matches"*) ok "an unmatched fragment is reported" ;;
               *) bad "unmatched fragment not reported" "$out" ;; esac

# --------------------------------------------------------------------------
head_ "production guard"

out=$(run 'M2X_PROD=1 m2x solo exec echo hi')
case "$out" in
  *PRODUCTION*) bad "a read-only command prompted on production" ;;
  *"t=solo"*)   ok "read-only commands never prompt, even on production" ;;
  *) bad "read-only command failed on production" "$out" ;;
esac

out=$(run 'M2X_PROD=1 m2x solo restart' </dev/null)
case "$out" in
  *"refusing a destructive operation"*) ok "destructive verb is refused on production without a tty" ;;
  *) bad "destructive verb was not guarded" "$out" ;;
esac

out=$(run 'M2X_PROD=1 M2X_ASSUME_YES=1 m2x solo restart' </dev/null)
case "$out" in
  *"RESTART t=solo"*) ok "M2X_ASSUME_YES allows automation through the guard" ;;
  *) bad "ASSUME_YES did not let the operation through" "$out" ;;
esac

out=$(run 'm2x solo restart' </dev/null)
case "$out" in
  *PRODUCTION*) bad "non-production context prompted" ;;
  *"RESTART t=solo"*) ok "non-production restart runs unprompted" ;;
  *) bad "restart failed off production" "$out" ;;
esac

# Context detection must read the context string, not a flag.
out=$(run 'FAKE_CONTEXT=k8s:acme-production m2x solo restart' </dev/null)
case "$out" in
  *"refusing a destructive operation"*) ok "a production-looking context name triggers the guard" ;;
  *) bad "context pattern did not trigger the guard" "$out" ;;
esac

out=$(run 'FAKE_CONTEXT=k8s:acme-staging m2x solo restart' </dev/null)
case "$out" in
  *"RESTART t=solo"*) ok "a staging context does not trigger the guard" ;;
  *) bad "staging context was treated as production" "$out" ;;
esac

# A guard that cannot tell destructive from safe must stop, not wave everything
# through. Emptying the list used to silently disable production protection.
out=$(run 'FAKE_CONTEXT=k8s:acme-production; _M2X_DESTRUCTIVE=(); m2x solo restart')
case "$out" in
  *"cannot run"*) ok "an emptied destructive list refuses instead of executing" ;;
  *) bad "an emptied destructive list let a production restart through" "$out" ;;
esac

out=$(run 'FAKE_CONTEXT=k8s:acme-production; _M2X_DESTRUCTIVE=oops; m2x solo restart')
case "$out" in
  *"cannot run"*) ok "a non-array destructive list refuses too" ;;
  *) bad "a scalar destructive list was accepted" "$out" ;;
esac

# --------------------------------------------------------------------------
head_ "parameter namespace"

# zsh offers parameter names in command position, because `NAME=value cmd` is
# legal there. So everything the plugin leaves in M2X_* is advertised by TAB as
# though it were configuration. Only the documented knobs belong there; an
# internal listed alongside them invites someone to set it.
expected="M2X_APP_USER M2X_ASSUME_YES M2X_KUBE_NS M2X_MAGENTO_BIN M2X_PROD_PATTERNS M2X_RUNTIME"
# shellcheck disable=SC2016  # $-expansion belongs to the inner zsh, not here
actual=$(run 'print -l ${(ko)parameters[(I)M2X_*]}' | tr '\n' ' ' | sed 's/ *$//')
if [ "$actual" = "$expected" ]; then
  ok "M2X_* holds the documented knobs and nothing else"
else
  bad "the public namespace drifted from the README" "got: $actual"
fi

# Every knob above is in the README table, and every row of that table is a knob.
for k in $expected; do
  grep -q "\`$k\`" "$REPO/README.md" || bad "$k is exposed but not in the README" ""
done
ok "every exposed knob is documented"

# --------------------------------------------------------------------------
head_ "catalogue"

out=$(run 'm2x solo cache')
case "$out" in
  *"cmd=bin/magento cache:clean"*) ok "a shortcut maps to the magento CLI" ;;
  *) bad "shortcut did not map correctly" "$out" ;;
esac

out=$(run 'm2x solo mage indexer:status')
case "$out" in
  *"cmd=bin/magento indexer:status"*) ok "mage passes an arbitrary command through" ;;
  *) bad "mage passthrough broken" "$out" ;;
esac

out=$(run 'M2X_APP_USER=someone m2x solo cache')
case "$out" in
  *"u=someone"*) ok "M2X_APP_USER is honoured" ;;
  *) bad "M2X_APP_USER ignored" "$out" ;;
esac

out=$(run 'm2x solo not-a-verb')
case "$out" in *"unknown verb"*) ok "an unknown verb is rejected" ;;
               *) bad "unknown verb was accepted" "$out" ;; esac

# --------------------------------------------------------------------------
head_ "listing and context"

out=$(run 'm2x')
case "$out" in *mysql-backup*) ok "no arguments lists the targets" ;;
               *) bad "bare invocation did not list targets" "$out" ;; esac

out=$(run 'FAKE_CONTEXT=k8s:prod-eu m2x context')
case "$out" in *production*) ok "context reports production status" ;;
               *) bad "context did not report production" "$out" ;; esac

# --------------------------------------------------------------------------
head_ "runtime aliases"

# Each alias pins its engine, so on a host without that engine it must fail
# rather than quietly using whichever one happens to be present.
# The fake adapter knows a target called "solo"; docker, podman and kubectl do
# not. So an alias that reaches the fake is not pinning anything, whether or not
# the real engine happens to be installed on this machine.
for alias_name in m2d m2p m2k; do
  out=$(zsh -c "
    source '$SANDBOX/fake.zsh'
    source '$REPO/mage2x.plugin.zsh'
    $alias_name solo exec echo hi" 2>&1)
  case "$out" in
    *"EXEC t=solo"*) bad "$alias_name fell through to the ambient runtime" "$out" ;;
    *) ok "$alias_name does not use the ambient runtime" ;;
  esac
done

# The pin must beat the ambient setting, or the alias means nothing.
out=$(zsh -c "
  source '$SANDBOX/fake.zsh'
  source '$REPO/mage2x.plugin.zsh'
  M2X_RUNTIME=fake
  m2d solo exec echo hi" 2>&1)
case "$out" in
  *"t=solo"*) bad "m2d used the ambient runtime instead of docker" ;;
  *) ok "an alias overrides M2X_RUNTIME" ;;
esac

head_ "migrate"

MHOME="$SANDBOX/mhome"
mkdir -p "$MHOME/omz/plugins"

out=$(zsh -c "
  source '$REPO/mage2x.plugin.zsh'
  ZSH_CUSTOM='$MHOME/omz' HOME='$MHOME' m2x migrate" 2>&1)
case "$out" in
  *"nothing to migrate"*) ok "migrate is a no-op with nothing to retire" ;;
  *) bad "migrate misbehaved on a clean host" "$out" ;;
esac

# A plain directory may hold edits that exist nowhere else: refuse it.
mkdir -p "$MHOME/omz/plugins/mage2docker"
echo local-edit > "$MHOME/omz/plugins/mage2docker/thing.zsh"
out=$(zsh -c "
  source '$REPO/mage2x.plugin.zsh'
  ZSH_CUSTOM='$MHOME/omz' HOME='$MHOME' m2x migrate" 2>&1)
case "$out" in
  *"plain directory"*) ok "migrate refuses a directory it did not create" ;;
  *) bad "migrate touched a plain directory" "$out" ;;
esac
if [ -f "$MHOME/omz/plugins/mage2docker/thing.zsh" ]; then
  ok "the refused directory is intact"
else
  bad "migrate deleted local work"
fi

# A checkout is replaceable, so it goes.
rm -rf "$MHOME/omz/plugins/mage2docker"
mkdir -p "$MHOME/omz/plugins/mage2docker"
git -C "$MHOME/omz/plugins/mage2docker" init -q
git -C "$MHOME/omz/plugins/mage2docker" -c user.email=t@example.test -c user.name=t \
    commit -q --allow-empty -m x --no-verify 2>/dev/null
out=$(zsh -c "
  source '$REPO/mage2x.plugin.zsh'
  ZSH_CUSTOM='$MHOME/omz' HOME='$MHOME' m2x migrate" 2>&1)
if [ -d "$MHOME/omz/plugins/mage2docker" ]; then
  bad "migrate left a checkout behind" "$out"
else
  ok "migrate removes a checkout"
fi

# And it rewrites plugins=(...) without losing the others.
printf 'plugins=(git mage2docker docker)\n' > "$MHOME/.zshrc"
mkdir -p "$MHOME/omz/plugins/mage2docker"
git -C "$MHOME/omz/plugins/mage2docker" init -q
out=$(zsh -c "
  source '$REPO/mage2x.plugin.zsh'
  ZSH_CUSTOM='$MHOME/omz' HOME='$MHOME' m2x migrate" 2>&1)
line=$(grep '^plugins=' "$MHOME/.zshrc")
case "$line" in
  *mage2docker*) bad "the retired plugin is still in plugins=()" "$line" ;;
  *mage2x*git*|*git*mage2x*) ok "plugins=() keeps the others and gains mage2x" ;;
  *) bad "plugins=() rewritten wrongly" "$line" ;;
esac
if [ -f "$MHOME/.zshrc.bak-mage2x" ]; then
  ok "migrate writes a backup before editing ~/.zshrc"
else
  bad "no backup written"
fi

# --------------------------------------------------------------------------
head_ "kubectl target parsing"

out=$(zsh -c "source '$REPO/mage2x.plugin.zsh'
              M2X_KUBE_NS=fallback
              p=(\${(f)\"\$(_m2x_kube_parse 'ns1/pod1:c1')\"})
              print -r -- \"\$p[1]|\$p[2]|\$p[3]\"" 2>&1)
if [ "$out" = "ns1|pod1|c1" ]; then ok "namespace/pod:container parses"; else bad "parse failed" "got $out"; fi

out=$(zsh -c "source '$REPO/mage2x.plugin.zsh'
              M2X_KUBE_NS=fallback
              p=(\${(f)\"\$(_m2x_kube_parse 'bare')\"})
              print -r -- \"\$p[1]|\$p[2]\"" 2>&1)
if [ "$out" = "fallback|bare" ]; then ok "a bare pod name falls back to the namespace"; else bad "namespace fallback failed" "got $out"; fi

# --------------------------------------------------------------------------
head_ "completion"

# _describe takes the NAME of an array. Passing a parenthesised literal makes
# zsh split it on whitespace, so every word of every description turns into a
# completion candidate — the user sees "a", "and", "the", "use" offered as
# targets. Grep for the shape rather than trying to drive the completion system.
if grep -nE "_describe[^#]*'\(" "$REPO/_mage2x" >/dev/null 2>&1; then
  bad "_describe is passed a literal instead of an array name" \
      "$(grep -nE "_describe[^#]*'\(" "$REPO/_mage2x" | head -2)"
else
  ok "_describe is always given an array name"
fi

# The first argument position lists containers, nothing else. `context` and
# `migrate` are valid there, but offering them puts two lines of prose above the
# container names on every TAB; --help is where a command is discovered.
target_block=$(sed -n '/^    target)$/,/^      ;;$/p' "$REPO/_mage2x")
n=$(printf '%s\n' "$target_block" | grep -c '_describe' || true)
if [ "$n" -eq 1 ] && printf '%s\n' "$target_block" | grep -q "_describe -t targets"; then
  ok "position 1 completes targets and nothing else"
else
  bad "position 1 offers something other than targets" "$target_block"
fi

# Dropping them from completion only holds if --help still carries them.
help_out=$(run 'm2x --help')
for cmd in context migrate; do
  if printf '%s\n' "$help_out" | grep -qE "^  $cmd +[a-z]"; then
    ok "--help documents '$cmd'"
  else
    bad "--help does not document '$cmd'" "$(printf '%s\n' "$help_out" | grep -n "$cmd" || echo 'absent')"
  fi
done

# --------------------------------------------------------------------------
head_ "bounded engine calls"

# `timeout` is an external binary: it execs a program, so a shell function
# handed to it is not found. `timeout 3 _m2x_<rt>_list` in the completion
# therefore returned nothing on every host that has coreutils installed, and
# said nothing about it because the adapter drops its own stderr. TAB offered
# no containers at all.
#
# A stub engine and a stub timeout reproduce that here, with no docker and no
# coreutils: the stub timeout is a separate process, so it cannot see a zsh
# function any more than the real one can.
STUB="$SANDBOX/stub"
mkdir -p "$STUB"
cat > "$STUB/docker" <<'ENGINE'
#!/bin/sh
[ "$1" = ps ] && printf 'alpha\nbeta\n'
ENGINE
cp "$STUB/docker" "$STUB/podman"
cat > "$STUB/timeout" <<'TMO'
#!/bin/sh
shift
exec "$@"
TMO
chmod +x "$STUB/docker" "$STUB/podman" "$STUB/timeout"

# The completion helper is driven directly: sourcing _mage2x runs its dispatch
# line, which needs the completion system, so its noise goes to /dev/null and
# the function it defined is called on its own.
comp_targets() {
  PATH="$STUB:$PATH" zsh -c "
    source '$REPO/mage2x.plugin.zsh'
    source '$REPO/_mage2x' 2>/dev/null
    words=($1)
    _m2x_comp_targets" 2>/dev/null
}

for alias_name in m2d m2p; do
  out=$(comp_targets "$alias_name")
  case "$out" in
    *alpha*beta*) ok "$alias_name completes targets with timeout on PATH" ;;
    *) bad "$alias_name completed nothing while timeout was available" "${out:-<empty>}" ;;
  esac
done

# The bound must still be applied, or the fix traded a silent empty list for a
# shell that hangs on an unreachable engine. The marker goes to stdout: the
# adapter sends its own stderr to /dev/null, which would swallow it.
cat > "$STUB/timeout" <<'TMO'
#!/bin/sh
printf 'BOUND=%s\n' "$1"
shift
exec "$@"
TMO
out=$(PATH="$STUB:$PATH" zsh -c "source '$REPO/mage2x.plugin.zsh'; _m2x_docker_list" 2>&1)
case "$out" in
  *"BOUND=3"*) ok "the engine call is bounded when timeout is available" ;;
  *) bad "the engine call is no longer bounded" "$out" ;;
esac

# And it must work where there is no timeout at all, which is stock macOS.
BARE="$SANDBOX/bare"
mkdir -p "$BARE"
cp "$STUB/docker" "$BARE/docker"
chmod +x "$BARE/docker"
out=$(PATH="$BARE:/usr/bin:/bin" zsh -c "source '$REPO/mage2x.plugin.zsh'; _m2x_docker_list" 2>/dev/null)
case "$out" in
  *alpha*beta*) ok "the adapter works with no timeout on PATH" ;;
  *) bad "the adapter needs timeout to be installed" "${out:-<empty>}" ;;
esac

# Nothing may hand a shell function to timeout again. zsh -n cannot catch it and
# neither can the suite above once the shape moves to another adapter, so the
# shape itself is what is pinned.
offenders=$(grep -rnE '(^|[;&|(]|[[:space:]])timeout[[:space:]]+[0-9]+[[:space:]]+_m2x_' \
  "$REPO/_mage2x" "$REPO/mage2x.plugin.zsh" "$REPO/lib" "$REPO/dist" 2>/dev/null \
  | grep -v ':[[:space:]]*#')
if [ -z "$offenders" ]; then
  ok "timeout is never applied to a shell function"
else
  bad "timeout is applied to a shell function" "$offenders"
fi

# --------------------------------------------------------------------------
head_ "single-file build"

# The bundle is what reaches hosts that can only carry one object, so it is
# tested as a plugin in its own right rather than assumed equivalent.
if "$REPO/scripts/bundle.sh" --check >/dev/null 2>&1; then
  ok "dist/ matches the sources"
else
  bad "dist/ is out of date - run scripts/bundle.sh"
fi

if [ -f "$REPO/dist/mage2x.plugin.zsh" ]; then
  if zsh -n "$REPO/dist/mage2x.plugin.zsh" 2>/dev/null; then
    ok "the bundle parses"
  else
    bad "the bundle has a syntax error"
  fi

  # It must define everything, having inlined what the checkout would source.
  missing=$(zsh -c "source '$REPO/dist/mage2x.plugin.zsh'
    (( \$+functions[m2x] )) || print m2x
    for rt in docker podman kube; do
      for v in available context list exec shell logs restart forward; do
        (( \$+functions[_m2x_\${rt}_\${v}] )) || print \"_m2x_\${rt}_\${v}\"
      done
    done" 2>&1)
  if [ -z "$missing" ]; then
    ok "the bundle defines the whole surface on its own"
  else
    bad "the bundle is missing functions" "$missing"
  fi

  # And it must behave the same: same refusal on an ambiguous target.
  out=$(zsh -c "
    source '$SANDBOX/fake.zsh'
    source '$REPO/dist/mage2x.plugin.zsh'
    M2X_RUNTIME=fake
    m2x ph exec true" 2>&1)
  case "$out" in
    *ambiguous*) ok "the bundle refuses an ambiguous target too" ;;
    *) bad "the bundle behaves differently from the checkout" "$out" ;;
  esac
else
  bad "dist/mage2x.plugin.zsh was never built"
fi

# --------------------------------------------------------------------------
head_ "syntax"

for f in mage2x.plugin.zsh _mage2x lib/core.zsh lib/rt-cli.zsh lib/rt-kube.zsh lib/catalog.zsh; do
  if zsh -n "$REPO/$f" 2>/dev/null; then ok "$f parses"; else bad "$f has a syntax error"; fi
done

if node --check "$REPO/bin/mage2x-install.mjs" 2>/dev/null; then
  ok "installer parses"
else
  bad "installer has a syntax error"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
