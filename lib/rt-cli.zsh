# mage2x - docker and podman adapters.
#
# The two engines share a CLI surface close enough that one implementation
# parameterised by binary is honest rather than lazy; where they diverge, the
# divergence is handled explicitly rather than hidden behind an alias.

_m2x_cli_bin() { print -r -- "$1" }   # runtime name == binary name for both

# --- docker ------------------------------------------------------------------

_m2x_docker_available() {
  command -v docker >/dev/null 2>&1 || return 1
  command docker info >/dev/null 2>&1
}

_m2x_docker_context() {
  local c
  c=$(command docker context show 2>/dev/null)
  # DOCKER_HOST wins when set: it is what the client will actually talk to,
  # whatever `context show` reports.
  [[ -n "$DOCKER_HOST" ]] && { print -r -- "docker:$DOCKER_HOST"; return }
  print -r -- "docker:${c:-default}@${HOST:-$(hostname -s 2>/dev/null)}"
}

_m2x_docker_list()  { _m2x_bounded docker ps --format '{{.Names}}' 2>/dev/null }
# ${u:+-u $u} expands to ONE word in zsh, so docker receives "-u www-data" as a
# single argument and reports it cannot find a user with a leading space.
_m2x_docker_exec() {
  local t=$1 u=$2; shift 2
  local -a uf; [[ -n "$u" ]] && uf=(-u "$u")
  command docker exec -i $uf "$t" "$@"
}
_m2x_docker_shell() {
  local t=$1 u=$2 sh=$3
  local -a uf; [[ -n "$u" ]] && uf=(-u "$u")
  command docker exec -it -e LINES=$(tput lines 2>/dev/null) -e COLUMNS=$(tput cols 2>/dev/null) \
    $uf "$t" "$sh" -l
}
_m2x_docker_logs()    { local t=$1; shift; command docker logs "$@" "$t" }
_m2x_docker_restart() { command docker restart "$1" }
_m2x_docker_forward() {
  _m2x_err "docker has no port-forward; publish the port or use the container IP"
  _m2x_dim "   ip: $(command docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1" 2>/dev/null)"
  return 1
}

# --- podman ------------------------------------------------------------------

_m2x_podman_available() {
  command -v podman >/dev/null 2>&1 || return 1
  command podman info >/dev/null 2>&1
}

_m2x_podman_context() {
  [[ -n "$CONTAINER_HOST" ]] && { print -r -- "podman:$CONTAINER_HOST"; return }
  local c
  c=$(command podman system connection list --format '{{.Name}}' 2>/dev/null | head -1)
  print -r -- "podman:${c:-local}@${HOST:-$(hostname -s 2>/dev/null)}"
}

_m2x_podman_list()  { _m2x_bounded podman ps --format '{{.Names}}' 2>/dev/null }
_m2x_podman_exec() {
  local t=$1 u=$2; shift 2
  local -a uf; [[ -n "$u" ]] && uf=(-u "$u")
  command podman exec -i $uf "$t" "$@"
}
_m2x_podman_shell() {
  local t=$1 u=$2 sh=$3
  local -a uf; [[ -n "$u" ]] && uf=(-u "$u")
  command podman exec -it -e LINES=$(tput lines 2>/dev/null) -e COLUMNS=$(tput cols 2>/dev/null) \
    $uf "$t" "$sh" -l
}
_m2x_podman_logs()    { local t=$1; shift; command podman logs "$@" "$t" }
_m2x_podman_restart() { command podman restart "$1" }
_m2x_podman_forward() {
  _m2x_err "podman has no port-forward; publish the port or use the container IP"
  _m2x_dim "   ip: $(command podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1" 2>/dev/null)"
  return 1
}
