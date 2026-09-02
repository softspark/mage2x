# mage2x - run commands in a container workload, whatever runs it.
#
# One command across docker, podman and kubectl: `x` is whichever of them is in
# front of you.
#
#   m2x                            list targets in the current runtime
#   m2x <target> shell             interactive shell
#   m2x <target> cache             magento cache:clean
#   m2x <target> mage <cmd...>     any magento CLI command
#   m2x <target> logs -f
#   m2x <target> restart           guarded on production
#   m2x --runtime kube prod/web:php shell
#
# Targets are matched on a fragment, but an ambiguous fragment is refused rather
# than guessed: matching `mysql` against a `mysql-backup` sidecar instead of
# mysqld has already cost this fleet an incident.

typeset -g MAGE2X_SRC="${0:A:h}"

local _f
for _f in core rt-cli rt-kube catalog; do
  source "$MAGE2X_SRC/lib/$_f.zsh"
done
unset _f

_m2x_usage() {
  print -- "mage2x - run commands in a container workload, whatever runs it

  m2x [--runtime docker|podman|kube] [<target> [<verb> [args...]]]
  m2d / m2p / m2k       the same, pinned to docker / podman / kubectl

  no arguments          list targets in the detected runtime
  <target> shell        interactive shell (\$M2X_APP_USER, default www-data)
  <target> root         interactive shell as root
  <target> exec <cmd>   run a command
  <target> logs [args]  container logs
  <target> restart      restart; on production this asks first
  <target> forward L:R  port-forward (kubectl only)
  context               show which runtime and context would be used
  migrate               retire a superseded plugin and point ~/.zshrc here

  magento shortcuts     ${(j:, :)${(ko)M2X_MAGE_SHORTCUTS}}
  <target> mage <cmd>   any other magento CLI command
  also                  magento, report, applog, composer,
                        redis-flush, varnish-purge, varnish-stat

environment
  M2X_RUNTIME           force an adapter instead of detecting one
  M2X_KUBE_NS           default namespace for kubectl
  M2X_APP_USER          user for application commands (default www-data)
  M2X_PROD_PATTERNS     regex marking a context as production
  M2X_PROD=1            treat the current context as production
  M2X_ASSUME_YES=1      skip the production prompt (for automation)"
}

# Retire a superseded plugin of the same purpose and point the shell here.
# Destructive, so it names every step and refuses anything it did not create.
_m2x_migrate() {
  emulate -L zsh
  local custom="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
  local zshrc="$HOME/.zshrc" found=0 old dir line new tmp
  local -a legacy=(mage2docker) names keep

  for old in $legacy; do
    dir="$custom/plugins/$old"
    [[ -e "$dir" ]] || continue
    found=1
    if [[ -L "$dir" ]]; then
      print -P "%F{yellow}~%f $old is a symlink - unlinking"
      command rm -f "$dir" && print -P "  %F{green}v%f ${dir/#$HOME/~}"
    elif [[ -d "$dir/.git" ]]; then
      print -P "%F{yellow}~%f $old is a checkout at $(command git -C $dir rev-parse --short HEAD 2>/dev/null) - removing"
      command rm -rf "$dir" && print -P "  %F{green}v%f ${dir/#$HOME/~}"
    else
      # Neither a checkout nor a link: it may hold edits that exist nowhere else.
      print -P "%F{red}x%f $old is a plain directory, not a checkout - leaving it alone"
      print -P "  %F{8}move it aside yourself: ${dir/#$HOME/~}%f"
    fi
  done

  if [[ -f "$zshrc" ]]; then
    line=$(grep -m1 '^plugins=(' "$zshrc")
    if [[ -n "$line" ]]; then
      # The parens must be escaped: unescaped, zsh reads them as a glob pattern
      # and the substitution dies with "bad pattern", leaving ~/.zshrc untouched
      # while the plugin directory has already been removed.
      names=(${(s: :)${${line#plugins=\(}%\)}})
      keep=()
      for old in $names; do
        (( ${legacy[(I)$old]} )) && { found=1; continue }
        keep+=($old)
      done
      (( ${keep[(I)mage2x]} )) || keep+=(mage2x)
      new="plugins=(${(j: :)keep})"
      if [[ "$new" != "$line" ]]; then
        command cp "$zshrc" "$zshrc.bak-mage2x"
        tmp=$(mktemp)
        sed "s|^plugins=(.*)|$new|" "$zshrc" > "$tmp" && command mv "$tmp" "$zshrc"
        print -P "%F{green}v%f ~/.zshrc: $new"
        print -P "  %F{8}backup: ~/.zshrc.bak-mage2x%f"
      else
        print -P "%F{8}=%f ~/.zshrc already lists mage2x and nothing superseded"
      fi
    else
      print -P "%F{yellow}!%f no plugins=(...) line in ~/.zshrc - add mage2x yourself"
    fi
  fi

  (( found )) || print -P "%F{8}=%f nothing to migrate"
  print -P "\nreload the shell:  exec zsh"
}

m2x() {
  emulate -L zsh
  local rt="" target="" verb="" resolved
  local -a rest

  while (( $# )); do
    case "$1" in
      --runtime) rt="$2"; shift 2 ;;
      -h|--help) _m2x_usage; return 0 ;;
      --) shift; rest+=("$@"); break ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  set -- "${rest[@]}"

  if [[ "${1:-}" == migrate ]]; then _m2x_migrate; return $?; fi

  [[ -n "$rt" ]] && M2X_RUNTIME="$rt"
  rt=$(_m2x_detect_runtime) || {
    # A pinned runtime has already reported precisely why it is unusable.
    # Adding "tried docker, podman, kubectl" on top would claim a search that
    # never happened.
    [[ -z "$M2X_RUNTIME" ]] && \
      _m2x_err "no usable container runtime found (tried docker, podman, kubectl)"
    return 1
  }

  # No target: list what is reachable. This is the honest answer to "what can I
  # even talk to from here", which is most of what the tool gets used for.
  if (( ! $# )); then
    _m2x_dim "runtime: $rt   context: $(_m2x_${rt}_context)"
    _m2x_${rt}_list
    return 0
  fi

  target="$1"; shift
  verb="${1:-shell}"; (( $# )) && shift

  # `context` needs no target resolution and must work when nothing is running.
  if [[ "$target" == context ]]; then
    print -r -- "runtime: $rt"
    print -r -- "context: $(_m2x_${rt}_context)"
    _m2x_is_production "$rt" && print -P "%F{red}production%f (destructive verbs will ask)" \
                             || print -P "%F{green}non-production%f"
    return 0
  fi

  resolved=$(_m2x_resolve "$rt" "$target") || return 1
  _m2x_confirm_destructive "$rt" "$verb" "$resolved" || return 1

  case "$verb" in
    shell)   _m2x_${rt}_shell "$resolved" "$M2X_APP_USER" "${1:-bash}" ;;
    root)    _m2x_${rt}_shell "$resolved" root "${1:-bash}" ;;
    sh)      _m2x_${rt}_shell "$resolved" "$M2X_APP_USER" sh ;;
    exec)    (( $# )) || { _m2x_err "usage: m2x <target> exec <command...>"; return 2 }
             _m2x_${rt}_exec "$resolved" "$M2X_APP_USER" "$@" ;;
    logs)    _m2x_${rt}_logs "$resolved" "$@" ;;
    restart) _m2x_${rt}_restart "$resolved" ;;
    forward) (( $# )) || { _m2x_err "usage: m2x <target> forward <local:remote>"; return 2 }
             _m2x_${rt}_forward "$resolved" "$1" ;;
    context) print -r -- "$(_m2x_${rt}_context)" ;;
    *)
      _m2x_catalog_run "$rt" "$resolved" "$verb" "$@" && return 0
      _m2x_err "unknown verb '$verb' (see: m2x --help)"
      return 2 ;;
  esac
}

# One alias per runtime, so the engine is chosen by which letter you type rather
# than by a flag. Auto-detection is right when only one engine is present; on a
# workstation with docker running and a kubeconfig loaded it is a coin toss, and
# a coin toss is not what anyone wants before `restart`.
m2d() { m2x --runtime docker "$@" }
m2p() { m2x --runtime podman "$@" }
m2k() { m2x --runtime kube   "$@" }
