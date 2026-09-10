# mage2x - run commands in a container workload, whatever runs it.
#
# The command chooses the runtime: m2d for Docker, m2p for Podman, m2k for kubectl.
#
#   m2d                            list Docker targets
#   m2d <target> shell             interactive shell
#   m2d <target> cache             magento cache:clean
#   m2d <target> mage <cmd...>     any magento CLI command
#   m2d <target> logs -f
#   m2d <target> restart           guarded on production
#   m2k prod/web:php shell
#
# Targets are matched on a fragment, but an ambiguous fragment is refused rather
# than guessed: matching `mysql` against a `mysql-backup` sidecar instead of
# mysqld has already cost this fleet an incident.

typeset -g _MAGE2X_SRC="${0:A:h}"

local _f
for _f in core rt-cli rt-kube catalog; do
  source "$_MAGE2X_SRC/lib/$_f.zsh"
done
unset _f

_m2x_usage() {
  print -- "mage2x - run commands in a container workload, whatever runs it

  m2d [--runtime docker|podman|kube] [<target> [<verb> [args...]]]
  m2p / m2k            Podman / kubectl, available when the CLI is installed

  no arguments          list targets in the command's runtime
  <target> shell        interactive shell (\$M2X_APP_USER, default www-data)
  <target> root         interactive shell as root
  <target> exec <cmd>   run a command
  <target> logs [args]  container logs
  <target> restart      restart; on production this asks first
  <target> forward L:R  port-forward (kubectl only)
  context               show which runtime and context would be used
  audit [--json|--sarif] inspect local configuration without contacting an engine
  migrate               retire a superseded plugin and point ~/.zshrc here

  magento shortcuts     ${(j:, :)${(ko)_M2X_MAGE_SHORTCUTS}}
  <target> mage <cmd>   any other magento CLI command
  also                  magento, report, applog, composer,
                        redis-flush, varnish-purge, varnish-stat

environment
  M2X_RUNTIME           force an adapter instead of detecting one
  M2X_KUBE_NS           default namespace for kubectl
  M2X_APP_USER          user for application commands (default www-data)
  M2X_PROD_PATTERNS     Zsh pattern alternatives marking a context as production
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

_m2x_dispatch() {
  emulate -L zsh
  local rt="" target="" verb="" resolved
  local -a rest

  while (( $# )); do
    case "$1" in
      --runtime)
        (( $# >= 2 )) && [[ -n "$2" && "$2" != -* ]] || {
          _m2x_err "--runtime requires an adapter name"; return 2
        }
        rt="$2"; shift 2 ;;
      -h|--help) _m2x_usage; return 0 ;;
      --) shift; rest+=("$@"); break ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  set -- "${rest[@]}"

  if [[ "${1:-}" == migrate ]]; then _m2x_migrate; return $?; fi

  local M2X_RUNTIME="${rt:-$M2X_RUNTIME}"
  if [[ "${1:-}" == audit ]]; then shift; _m2x_audit "$@"; return $?; fi
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
    exec)    (( $# )) || { _m2x_err "usage: m2d <target> exec <command...>"; return 2 }
             _m2x_${rt}_exec "$resolved" "$M2X_APP_USER" "$@" ;;
    logs)    _m2x_${rt}_logs "$resolved" "$@" ;;
    restart) _m2x_${rt}_restart "$resolved" ;;
    forward) (( $# )) || { _m2x_err "usage: m2k <target> forward <local:remote>"; return 2 }
             _m2x_${rt}_forward "$resolved" "$1" ;;
    context) print -r -- "$(_m2x_${rt}_context)" ;;
    *)
      _m2x_catalog_run "$rt" "$resolved" "$verb" "$@" && return 0
      _m2x_err "unknown verb '$verb' (see: m2d --help)"
      return 2 ;;
  esac
}

# Clear the old entry points when re-sourcing an already loaded plugin.
unfunction m2x m2p m2k 2>/dev/null
m2d() { _m2x_dispatch --runtime docker "$@" }
if (( $+commands[podman] )); then
  m2p() { _m2x_dispatch --runtime podman "$@" }
fi
if (( $+commands[kubectl] )); then
  m2k() { _m2x_dispatch --runtime kube "$@" }
fi

# Configuration remains available for assignments and $M2X_* expansion, but
# does not compete with command names on `m2<TAB>`. Preserve existing filters.
() {
  local context=':completion:*:-command-:*:parameters'
  local -a ignored
  zstyle -a "$context" ignored-patterns ignored
  (( ${ignored[(Ie)M2X_*]} )) || ignored+=('M2X_*')
  zstyle "$context" ignored-patterns "${ignored[@]}"
}
