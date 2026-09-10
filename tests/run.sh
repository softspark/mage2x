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

# User startup files can rewrite PATH before a stub engine is reached.
export ZDOTDIR="$SANDBOX/zsh-config"
mkdir -p "$ZDOTDIR"

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

out=$(run 'm2d --runtime fake solo exec echo hi')
case "$out" in *"t=solo"*) ok "an unambiguous fragment resolves" ;;
               *) bad "unambiguous fragment failed" "$out" ;; esac

out=$(run 'm2d --runtime fake mysql exec echo hi')
case "$out" in
  *"t=mysql u="*) ok "an exact name wins over a longer partial match" ;;
  *) bad "exact match lost to a partial one" "$out" ;;
esac

# The incident this tool exists to prevent: a fragment matching a sidecar.
# 'ph' rather than 'php', which is an exact name and must resolve.
out=$(run 'm2d --runtime fake ph exec echo hi')
case "$out" in
  *ambiguous*) ok "an ambiguous fragment is refused" ;;
  *) bad "ambiguous fragment was resolved anyway" "$out" ;;
esac

case "$out" in
  *php-fpm*) ok "the candidates are listed on refusal" ;;
  *) bad "refusal did not show candidates (stdout/stderr mix-up?)" "$out" ;;
esac

out=$(run 'm2d --runtime fake php exec echo hi')
case "$out" in
  *"t=php u="*) ok "an exact name is not treated as ambiguous" ;;
  *) bad "exact name was refused as ambiguous" "$out" ;;
esac

out=$(run 'm2d --runtime fake nothing-like-this exec echo hi')
case "$out" in *"no target matches"*) ok "an unmatched fragment is reported" ;;
               *) bad "unmatched fragment not reported" "$out" ;; esac

# --------------------------------------------------------------------------
head_ "production guard"

out=$(run 'M2X_PROD=1 m2d --runtime fake solo exec echo hi')
case "$out" in
  *PRODUCTION*) bad "a read-only command prompted on production" ;;
  *"t=solo"*)   ok "read-only commands never prompt, even on production" ;;
  *) bad "read-only command failed on production" "$out" ;;
esac

out=$(run 'M2X_PROD=1 m2d --runtime fake solo restart' </dev/null)
case "$out" in
  *"refusing a destructive operation"*) ok "destructive verb is refused on production without a tty" ;;
  *) bad "destructive verb was not guarded" "$out" ;;
esac

out=$(run 'M2X_PROD=1 M2X_ASSUME_YES=1 m2d --runtime fake solo restart' </dev/null)
case "$out" in
  *"RESTART t=solo"*) ok "M2X_ASSUME_YES allows automation through the guard" ;;
  *) bad "ASSUME_YES did not let the operation through" "$out" ;;
esac

out=$(run 'm2d --runtime fake solo restart' </dev/null)
case "$out" in
  *PRODUCTION*) bad "non-production context prompted" ;;
  *"RESTART t=solo"*) ok "non-production restart runs unprompted" ;;
  *) bad "restart failed off production" "$out" ;;
esac

# Context detection must read the context string, not a flag.
out=$(run 'FAKE_CONTEXT=k8s:acme-production m2d --runtime fake solo restart' </dev/null)
case "$out" in
  *"refusing a destructive operation"*) ok "a production-looking context name triggers the guard" ;;
  *) bad "context pattern did not trigger the guard" "$out" ;;
esac

out=$(run 'FAKE_CONTEXT=k8s:acme-staging m2d --runtime fake solo restart' </dev/null)
case "$out" in
  *"RESTART t=solo"*) ok "a staging context does not trigger the guard" ;;
  *) bad "staging context was treated as production" "$out" ;;
esac

# A guard that cannot tell destructive from safe must stop, not wave everything
# through. Emptying the list used to silently disable production protection.
out=$(run 'FAKE_CONTEXT=k8s:acme-production; _M2X_DESTRUCTIVE=(); m2d --runtime fake solo restart')
case "$out" in
  *"cannot run"*) ok "an emptied destructive list refuses instead of executing" ;;
  *) bad "an emptied destructive list let a production restart through" "$out" ;;
esac

out=$(run 'FAKE_CONTEXT=k8s:acme-production; _M2X_DESTRUCTIVE=oops; m2d --runtime fake solo restart')
case "$out" in
  *"cannot run"*) ok "a non-array destructive list refuses too" ;;
  *) bad "a scalar destructive list was accepted" "$out" ;;
esac

# --------------------------------------------------------------------------
head_ "parameter namespace"

# Configuration stays available for assignments and variable expansion, even
# though command-position completion hides these names.
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

out=$(run 'm2d --runtime fake solo cache')
case "$out" in
  *"cmd=bin/magento cache:clean"*) ok "a shortcut maps to the magento CLI" ;;
  *) bad "shortcut did not map correctly" "$out" ;;
esac

out=$(run 'm2d --runtime fake solo mage indexer:status')
case "$out" in
  *"cmd=bin/magento indexer:status"*) ok "mage passes an arbitrary command through" ;;
  *) bad "mage passthrough broken" "$out" ;;
esac

out=$(run 'M2X_APP_USER=someone m2d --runtime fake solo cache')
case "$out" in
  *"u=someone"*) ok "M2X_APP_USER is honoured" ;;
  *) bad "M2X_APP_USER ignored" "$out" ;;
esac

out=$(run 'm2d --runtime fake solo not-a-verb')
case "$out" in *"unknown verb"*) ok "an unknown verb is rejected" ;;
               *) bad "unknown verb was accepted" "$out" ;; esac

# --------------------------------------------------------------------------
head_ "listing and context"

out=$(run 'm2d --runtime fake')
case "$out" in *mysql-backup*) ok "no arguments lists the targets" ;;
               *) bad "bare invocation did not list targets" "$out" ;; esac

out=$(run 'FAKE_CONTEXT=k8s:prod-eu m2d --runtime fake context')
case "$out" in *production*) ok "context reports production status" ;;
               *) bad "context did not report production" "$out" ;; esac

# --------------------------------------------------------------------------
head_ "runtime aliases"

# Narrow PATH inside zsh so host-installed engines cannot affect this matrix.
# Executables record calls: loading the plugin must never contact an engine.
for engine_set in none docker podman kubectl all; do
  ENGINE_DIR="$SANDBOX/engines-$engine_set"
  ENGINE_LOG="$SANDBOX/engines-$engine_set.log"
  mkdir -p "$ENGINE_DIR"
  case "$engine_set" in
    none) engines=""; expected_commands="m2d" ;;
    docker) engines="docker"; expected_commands="m2d" ;;
    podman) engines="podman"; expected_commands="m2d m2p" ;;
    kubectl) engines="kubectl"; expected_commands="m2d m2k" ;;
    all) engines="docker podman kubectl"; expected_commands="m2d m2p m2k" ;;
  esac
  for engine in $engines; do
    cat > "$ENGINE_DIR/$engine" <<'ENGINE_PRESENCE'
#!/bin/sh
printf 'called\n' >> "$ENGINE_LOG"
exit 1
ENGINE_PRESENCE
    chmod +x "$ENGINE_DIR/$engine"
  done
  for plugin in mage2x.plugin.zsh dist/mage2x.plugin.zsh; do
    out=$(ENGINE_LOG="$ENGINE_LOG" zsh -f -c '
      PATH=$1
      source "$2"
      present=()
      for name in m2d m2p m2k m2x; do
        (( $+functions[$name] )) && present+=($name)
      done
      print -r -- "${(j: :)present}"
    ' -- "$ENGINE_DIR" "$REPO/$plugin" 2>&1)
    if [ "$out" = "$expected_commands" ]; then
      ok "$plugin exposes only installed engine commands ($engine_set)"
    else
      bad "$plugin has the wrong command surface ($engine_set)" "$out"
    fi
  done
  if [ ! -s "$ENGINE_LOG" ]; then
    ok "loading with $engine_set does not probe an engine"
  else
    bad "loading with $engine_set contacted an engine"
  fi
done

out=$(run 'm2d --runtime docker --runtime fake solo exec echo hi')
case "$out" in
  *"EXEC t=solo"*) ok "the final explicit runtime overrides the m2d default" ;;
  *) bad "the final runtime flag did not win" "$out" ;;
esac

# shellcheck disable=SC2016  # Expansion belongs to the inner zsh.
out=$(run 'M2X_RUNTIME=ambient; m2d --runtime fake solo exec echo hi; print -r -- "after=$M2X_RUNTIME"')
if [[ "$out" == *"EXEC t=solo"* && "$out" == *"after=ambient"* ]]; then
  ok "an explicit runtime does not overwrite the ambient configuration"
else
  bad "the command changed M2X_RUNTIME beyond its invocation" "$out"
fi

for invalid_runtime in '--runtime' '--runtime ""' '--runtime --help'; do
  out=$(run "m2d $invalid_runtime")
  if [ "$?" -eq 2 ] && [[ "$out" == *"--runtime requires an adapter name"* ]]; then
    ok "an invalid runtime argument is rejected ($invalid_runtime)"
  else
    bad "an invalid runtime argument was accepted ($invalid_runtime)" "$out"
  fi
done

for plugin in mage2x.plugin.zsh dist/mage2x.plugin.zsh; do
  out=$(zsh -f -c '
    PATH=$1
    source "$3"
    m2x() { print stale }
    PATH=$2
    source "$3"
    present=()
    for name in m2d m2p m2k m2x; do
      (( $+functions[$name] )) && present+=($name)
    done
    print -r -- "${(j: :)present}"
  ' -- "$SANDBOX/engines-all" "$SANDBOX/engines-none" "$REPO/$plugin" 2>&1)
  if [ "$out" = m2d ]; then
    ok "$plugin removes retired and unavailable commands on reload"
  else
    bad "$plugin retained stale commands on reload" "$out"
  fi
done

out=$(zsh -f -c '
  PATH=$1
  source "$2"
  M2X_RUNTIME=podman
  m2d solo exec echo hi
' -- "$SANDBOX/engines-none" "$REPO/mage2x.plugin.zsh" 2>&1)
if [[ "$out" == *docker* && "$out" != *"tried docker, podman, kubectl"* ]]; then
  ok "m2d reports missing Docker without falling back to other engines"
else
  bad "m2d did not report its pinned missing engine" "$out"
fi

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
  ZSH_CUSTOM='$MHOME/omz' HOME='$MHOME' m2d --runtime fake migrate" 2>&1)
case "$out" in
  *"nothing to migrate"*) ok "migrate is a no-op with nothing to retire" ;;
  *) bad "migrate misbehaved on a clean host" "$out" ;;
esac

# A plain directory may hold edits that exist nowhere else: refuse it.
mkdir -p "$MHOME/omz/plugins/mage2docker"
echo local-edit > "$MHOME/omz/plugins/mage2docker/thing.zsh"
out=$(zsh -c "
  source '$REPO/mage2x.plugin.zsh'
  ZSH_CUSTOM='$MHOME/omz' HOME='$MHOME' m2d --runtime fake migrate" 2>&1)
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
  ZSH_CUSTOM='$MHOME/omz' HOME='$MHOME' m2d --runtime fake migrate" 2>&1)
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
  ZSH_CUSTOM='$MHOME/omz' HOME='$MHOME' m2d --runtime fake migrate" 2>&1)
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

# Completion must use the same final override as command dispatch.
# shellcheck disable=SC2016
out=$(run 'source "'"$REPO"'/_mage2x" 2>/dev/null
  words=(m2d --runtime podman --runtime fake ""); CURRENT=6
  _m2x_comp_runtime')
if [ "$out" = fake ]; then
  ok "completion uses the final explicit runtime"
else
  bad "completion differs from runtime dispatch" "$out"
fi

# shellcheck disable=SC2016
out=$(run 'source "'"$REPO"'/_mage2x" 2>/dev/null
  words=(m2d -- --runtime fake ""); CURRENT=5
  _m2x_comp_runtime')
if [ "$out" = docker ]; then
  ok "completion ignores runtime flags after the option terminator"
else
  bad "completion parsed a runtime after the option terminator" "$out"
fi

for plugin in mage2x.plugin.zsh dist/mage2x.plugin.zsh; do
  out=$(zsh -f -c '
    zstyle ":completion:*:-command-:*:parameters" ignored-patterns "KEEP_*"
    zstyle ":completion:*:parameters" ignored-patterns "OTHER_*"
    source "$1"
    source "$1"
    zstyle -a ":completion::complete:-command-::parameters" ignored-patterns command_patterns
    zstyle -a ":completion::complete:-parameter-::parameters" ignored-patterns variable_patterns
    print -r -- "command=${(j: :)command_patterns}"
    print -r -- "variable=${(j: :)variable_patterns}"
    print -r -- "knob=${+parameters[M2X_RUNTIME]}"
  ' -- "$REPO/$plugin" 2>&1)
  if [[ "$out" == *"command=KEEP_* M2X_*"* && "$out" == *"variable=OTHER_*"* && "$out" == *"knob=1"* ]]; then
    ok "$plugin hides configuration only in command completion and preserves styles on reload"
  else
    bad "$plugin lost existing patterns or changed variable completion" "$out"
  fi
done

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
help_out=$(run 'm2d --runtime fake --help')
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
case "$1" in
  ps)   printf 'alpha\nbeta\n' ;;
  info) : ;;
  *)    exit 1 ;;
esac
ENGINE
cp "$STUB/docker" "$STUB/podman"
# Records the duration it was handed, then behaves like coreutils': drop it and
# exec the rest.
cat > "$STUB/timeout" <<'TMO'
#!/bin/sh
[ -n "$BOUND_LOG" ] && printf '%s\n' "$1" >> "$BOUND_LOG"
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

# The availability probe is the other call that reaches the engine, and the one
# whose failure is loudest: it decides whether the tool has a runtime at all.
out=$(PATH="$STUB:$PATH" zsh -c "source '$REPO/mage2x.plugin.zsh'
                                 _m2x_docker_available && print usable" 2>&1)
case "$out" in
  *usable*) ok "the availability probe survives a present timeout" ;;
  *) bad "the availability probe failed while timeout was available" "${out:-<empty>}" ;;
esac

# Both bounds must still be applied, or the fix traded a silent empty list for a
# shell that hangs on an unreachable engine. The two durations differ on
# purpose: a listing only decorates a TAB, a probe that gives up makes the tool
# refuse everything, so it is the one allowed to wait.
LOG="$SANDBOX/bound.log"
: > "$LOG"
BOUND_LOG="$LOG" PATH="$STUB:$PATH" zsh -c "source '$REPO/mage2x.plugin.zsh'
                                            _m2x_docker_list
                                            _m2x_docker_available" >/dev/null 2>&1
bounds=$(tr '\n' ' ' < "$LOG" | sed 's/ *$//')
if [ "$bounds" = "3 10" ]; then
  ok "the listing is bounded at 3s and the probe at 10s"
else
  bad "the engine calls are not bounded as intended" "got: ${bounds:-<none>}"
fi

# And both must work where there is no timeout at all, which is stock macOS.
# $PATH is narrowed INSIDE zsh rather than around it: every Linux runner carries
# /usr/bin/timeout, so leaving a system directory on the path to find zsh with
# would quietly turn this into a second copy of the test above. The probe
# reports what it found, so a passing assertion means the branch was real.
BARE="$SANDBOX/bare"
mkdir -p "$BARE"
cp "$STUB/docker" "$BARE/docker"
chmod +x "$BARE/docker"
out=$(zsh -c "PATH='$BARE'
              print \"have_timeout=\${+commands[timeout]}\"
              source '$REPO/mage2x.plugin.zsh'
              _m2x_docker_available && _m2x_docker_list" 2>/dev/null)
case "$out" in
  *have_timeout=0*alpha*beta*) ok "the adapter works with no timeout on PATH" ;;
  *have_timeout=1*) bad "the no-timeout case never ran: timeout was still on PATH" "$out" ;;
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
    (( \$+functions[m2d] )) || print m2d
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
    m2d --runtime fake ph exec true" 2>&1)
  case "$out" in
    *ambiguous*) ok "the bundle refuses an ambiguous target too" ;;
    *) bad "the bundle behaves differently from the checkout" "$out" ;;
  esac
else
  bad "dist/mage2x.plugin.zsh was never built"
fi

# --------------------------------------------------------------------------
head_ "syntax"

out=$(run 'M2X_ASSUME_YES=token-must-not-leak M2X_PROD=1 m2d --runtime fake audit --json')
audit_code=$?
if [ "$audit_code" -eq 1 ] && printf '%s' "$out" | node --input-type=module -e '
import assert from "node:assert/strict";
let raw = ""; for await (const chunk of process.stdin) raw += chunk;
const report = JSON.parse(raw);
assert.equal(report.scope, "local-configuration");
assert.equal(report.runtimeProbed, false);
assert.equal(report.productionForced, true);
assert(report.findings.some(f => f.ruleId === "invalid-confirmation-override"));
assert(!raw.includes("token-must-not-leak"));
'; then ok "JSON audit reports invalid confirmation override without exposing environment values"
else bad "JSON audit report failed" "$out"; fi

if out=$(run '_m2x_fake_available() { print SHOULD_NOT_RUN; return 1 }
            _m2x_fake_context() { print SHOULD_NOT_RUN; return 1 }
            M2X_ASSUME_YES= m2d --runtime fake audit --json') && [[ "$out" != *SHOULD_NOT_RUN* ]]; then
  ok "audit never probes an engine or context even when unavailable"
else bad "audit contacted the runtime" "$out"; fi

out=$(run '_M2X_DESTRUCTIVE=(); M2X_PROD_PATTERNS=; m2d --runtime fake audit --json')
if [ "$?" -eq 1 ] && [[ "$out" == *broken-production-guard* && "$out" == *empty-production-patterns* ]]; then
  ok "audit reports broken guard configuration"
else bad "audit missed broken guard" "$out"; fi

out=$(run 'M2X_RUNTIME=unknown-secret _m2x_dispatch audit --json')
if [ "$?" -eq 1 ] && [[ "$out" == *unknown-runtime* && "$out" != *unknown-secret* ]]; then
  ok "audit reports unregistered adapters without exposing their value"
else bad "audit missed invalid adapter" "$out"; fi

out=$(run 'm2d --runtime fake audit --invalid')
if [ "$?" -eq 2 ]; then ok "audit rejects unknown options"; else bad "audit accepted unknown option" "$out"; fi

out=$(run 'M2X_ASSUME_YES=1 m2d --runtime fake audit --sarif')
if printf '%s' "$out" | node --input-type=module -e '
import assert from "node:assert/strict";
let raw = ""; for await (const chunk of process.stdin) raw += chunk;
const report = JSON.parse(raw);
assert.equal(report.version, "2.1.0");
assert(report.runs[0].results.some(f => f.ruleId === "confirmation-bypassed" && f.level === "warning" && f.message.text));
assert(!raw.includes("secret"));
'; then ok "SARIF exports actual configuration findings without secrets"
else bad "SARIF audit report failed" "$out"; fi

for override in 0 false yes token-must-not-leak; do
  out=$(run "FAKE_CONTEXT=production M2X_ASSUME_YES=$override m2d --runtime fake solo restart")
  if [ "$?" -eq 1 ] && [[ "$out" == *refusing* && "$out" != *"RESTART t="* ]]; then
    ok "override $override cannot authorize unattended production restart"
  else bad "non-approval override authorized production restart" "$out"; fi
done

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
