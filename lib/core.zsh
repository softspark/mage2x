# mage2x - shared core: runtime selection, target resolution, safety guard.
#
# The runtime adapters below all implement the same verb set. Nothing outside
# this contract may assume a particular container engine:
#
#   _m2x_<rt>_available            0 when the runtime can be used here
#   _m2x_<rt>_context              human-readable context (host, cluster, socket)
#   _m2x_<rt>_list                 candidate targets, one per line
#   _m2x_<rt>_exec   <t> <u> <cmd...>   run a command in the target
#   _m2x_<rt>_shell  <t> <u> <sh>       interactive shell
#   _m2x_<rt>_logs   <t> [args...]
#   _m2x_<rt>_restart <t>
#   _m2x_<rt>_forward <t> <local:remote>
#
# Target syntax is runtime-specific and parsed by the adapter, never here.

typeset -g M2X_RUNTIME="${M2X_RUNTIME:-}"          # force an adapter
typeset -g M2X_PROD_PATTERNS="${M2X_PROD_PATTERNS:-prod|production|prd|live}"
typeset -g M2X_ASSUME_YES="${M2X_ASSUME_YES:-}"

# Operations that change or destroy running state. Everything else is read-only
# and never prompts, however production-looking the context is.
typeset -ga _M2X_DESTRUCTIVE=(restart stop rm kill down scale rollout)

_m2x_err()  { print -u2 -P "%F{red}x%f $*" }
_m2x_warn() { print -u2 -P "%F{yellow}!%f $*" }
_m2x_info() { print -P "%F{cyan}>%f $*" }
_m2x_dim()  { print -P "%F{8}$*%f" }

# Bound a call to a container engine, so an unreachable one cannot hang the
# shell it was invoked from — completion above all, where nothing may block.
#
# The bound goes around the ENGINE and never around an adapter. `timeout` is an
# external binary: it execs a program, and a zsh function handed to it is simply
# not found. Wrapping the adapter instead looked equivalent and returned nothing
# on every host with coreutils installed — silently, because the adapter sends
# its own errors to /dev/null. TAB then offered no containers at all.
#
# The duration belongs to the call site, because the two uses fail differently.
# A listing that gives up leaves a TAB with nothing on it, so it is cut short at
# three seconds. An availability probe that gives up makes the tool announce it
# has no runtime at all and refuse to run anything, so it gets ten — enough for
# a first connection to a remote context over SSH before that is said.
_m2x_bounded() {
  local secs="$1"; shift
  if (( $+commands[timeout] )); then
    command timeout "$secs" "$@"
  else
    command "$@"
  fi
}

# --- runtime selection -------------------------------------------------------

# Order matters only as a tie-break: an explicit M2X_RUNTIME always wins, and a
# kubeconfig alone does not outrank a local engine that actually has containers.
_m2x_detect_runtime() {
  if [[ -n "$M2X_RUNTIME" ]]; then
    if _m2x_${M2X_RUNTIME}_available 2>/dev/null; then
      print -r -- "$M2X_RUNTIME"; return 0
    fi
    _m2x_err "M2X_RUNTIME=$M2X_RUNTIME is not usable here"
    return 1
  fi
  local rt
  for rt in docker podman kube; do
    _m2x_${rt}_available 2>/dev/null && { print -r -- "$rt"; return 0 }
  done
  return 1
}

# Local configuration only: never call an adapter, engine, or credential helper.
# Environment values and context URLs are intentionally omitted from the report.
_m2x_audit() {
  emulate -L zsh
  local format=text runtime=auto rule
  local -a findings
  if (( $# )); then
    [[ $# == 1 && ( "$1" == --json || "$1" == --sarif ) ]] || {
      _m2x_err 'usage: m2x audit [--json|--sarif]'; return 2
    }
    format=${1#--}
  fi
  if [[ -n "$M2X_RUNTIME" ]]; then
    case "$M2X_RUNTIME" in
      docker|podman|kube) runtime="$M2X_RUNTIME" ;;
      *) runtime=custom ;;
    esac
    (( $+functions[_m2x_${M2X_RUNTIME}_available] )) || findings+=(unknown-runtime)
  fi
  if [[ "$M2X_ASSUME_YES" == 1 ]]; then
    findings+=(confirmation-bypassed)
  elif [[ -n "$M2X_ASSUME_YES" ]]; then
    findings+=(invalid-confirmation-override)
  fi
  [[ -n "$M2X_PROD_PATTERNS" ]] || findings+=(empty-production-patterns)
  if [[ ${(t)_M2X_DESTRUCTIVE} != array* ]] || (( ! ${#_M2X_DESTRUCTIVE} )); then
    findings+=(broken-production-guard)
  fi
  if [[ "$runtime" == auto ]]; then
    (( $+commands[docker] || $+commands[podman] || $+commands[kubectl] )) || findings+=(runtime-binary-missing)
  elif [[ "$runtime" != custom ]]; then
    local binary="$runtime"
    [[ "$runtime" == kube ]] && binary=kubectl
    (( $+commands[$binary] )) || findings+=(runtime-binary-missing)
  fi
  if [[ "$format" == sarif ]]; then
    local -a entries
    for rule in $findings; do entries+=("{\"ruleId\":\"$rule\",\"level\":\"warning\",\"message\":{\"text\":\"$rule (local configuration)\"}}"); done
    print -r -- "{\"version\":\"2.1.0\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"mage2x\"}},\"results\":[${(j:,:)entries}]}]}"
  elif [[ "$format" == json ]]; then
    local -a entries
    for rule in $findings; do entries+=("{\"ruleId\":\"$rule\",\"level\":\"warning\"}"); done
    print -r -- "{\"schemaVersion\":1,\"tool\":\"mage2x\",\"scope\":\"local-configuration\",\"runtime\":\"$runtime\",\"runtimeProbed\":false,\"productionForced\":$([[ -n "$M2X_PROD" ]] && print true || print false),\"findings\":[${(j:,:)entries}]}"
  else
    print -r -- "mage2x audit: local configuration, runtime=$runtime (engines not contacted)"
    for rule in $findings; do print -r -- "  warning: $rule"; done
    (( ${#findings} )) || print -r -- 'No local configuration findings.'
  fi
  (( ${#findings} == 0 ))
}

# --- target resolution -------------------------------------------------------

# Resolve a user-supplied fragment to exactly one target.
#
# An ambiguous fragment is an ERROR, never a guess. This is not defensiveness
# for its own sake: `name=mysql` matching a `mysql-backup` sidecar instead of
# mysqld is a failure that has already happened in this fleet, and picking the
# first match is how it happens.
# The caller reads stdout as the resolved name, so EVERY diagnostic here goes to
# stderr. Printing the candidate list to stdout swallows it into the command
# substitution: the refusal is then correct but silent, which is worse than
# guessing because nobody learns what to type instead.
_m2x_resolve() {
  local rt="$1" want="$2"
  local -a all exact partial
  all=(${(f)"$(_m2x_${rt}_list)"})

  (( ${#all} )) || { _m2x_err "no targets found (runtime: $rt)"; return 1 }

  exact=(${all[(r)$want]})
  [[ -n "$exact" ]] && { print -r -- "$want"; return 0 }

  partial=(${(M)all:#*$want*})
  case ${#partial} in
    1) print -r -- "$partial[1]"; return 0 ;;
    0) _m2x_err "no target matches '$want'"
       print -u2 -P "%F{8}   available: ${(j:, :)all[1,8]}${${:-$([[ ${#all} -gt 8 ]] && print ' ...')}}%f"
       return 1 ;;
    *) _m2x_err "'$want' is ambiguous - refusing to guess"
       local c
       for c in $partial; do print -u2 -P "     $c"; done
       print -u2 -P "%F{8}   name the target exactly%f"
       return 1 ;;
  esac
}

# --- safety ------------------------------------------------------------------

# Does the current context look like production? Heuristic on purpose: it must
# be cheap and never wrong in the direction of staying silent.
# Case-insensitivity via ${ctx:l}, not the (#i) glob flag: (#i) needs
# extendedglob, which `emulate -L zsh` in the entry point turns off, so the
# pattern silently never matched and every context read as non-production.
_m2x_is_production() {
  local rt="$1" ctx
  [[ -n "$M2X_PROD" ]] && return 0
  ctx=$(_m2x_${rt}_context)
  [[ "${ctx:l}" == *(${~M2X_PROD_PATTERNS})* ]]
}

# Ask before a destructive verb on a production-looking context. Read-only verbs
# never reach this, so the prompt keeps its meaning instead of becoming noise
# people dismiss reflexively.
_m2x_confirm_destructive() {
  local rt="$1" verb="$2" target="$3" ctx
  # An empty or clobbered list would mean "no verb is destructive" and wave
  # every restart through on production without a word. That is a broken load,
  # not a configuration — refuse everything rather than silently protect
  # nothing. This is the failure mode the guard exists to prevent.
  if [[ ${(t)_M2X_DESTRUCTIVE} != array* ]] || (( ! ${#_M2X_DESTRUCTIVE} )); then
    _m2x_err "_M2X_DESTRUCTIVE is empty or not an array - the production guard cannot run"
    _m2x_dim "   the plugin is loaded wrong or something overwrote it; reload the shell"
    return 1
  fi
  (( ${_M2X_DESTRUCTIVE[(I)$verb]} )) || return 0
  _m2x_is_production "$rt" || return 0

  ctx=$(_m2x_${rt}_context)
  print -u2 -P "%F{red}PRODUCTION%f  $verb  %F{cyan}$target%f  on  %F{yellow}$ctx%f"

  [[ "$M2X_ASSUME_YES" == 1 ]] && { _m2x_warn "M2X_ASSUME_YES=1 - proceeding"; return 0 }
  if [[ ! -t 0 ]]; then
    _m2x_err "refusing a destructive operation on production without a terminal"
    _m2x_dim "   set M2X_ASSUME_YES=1 to override in automation"
    return 1
  fi

  local answer
  read -r "answer?type the target name to confirm: "
  if [[ "$answer" != "$target" ]]; then
    _m2x_err "aborted"
    return 1
  fi
  return 0
}
