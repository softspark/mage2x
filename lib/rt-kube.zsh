# mage2x - kubectl adapter.
#
# Kubernetes is not docker with a different binary, and pretending otherwise is
# where these tools usually break:
#
#   * a target needs a namespace, and a pod may hold several containers, so the
#     address is [namespace/]pod[:container], not a bare name
#   * "restart" is not an operation on the pod; it is a rollout of the workload
#     that owns it, and restarting the pod object alone means deleting it
#   * there is no routable pod IP from a workstation, so anything that wants a
#     TCP connection goes through port-forward rather than an address

typeset -g M2X_KUBE_NS="${M2X_KUBE_NS:-}"

# Unbounded on purpose, unlike the docker and podman probes: this reads the
# kubeconfig on disk and never contacts an API server, so there is nothing here
# that can block on an unreachable cluster.
_m2x_kube_available() {
  command -v kubectl >/dev/null 2>&1 || return 1
  command kubectl config current-context >/dev/null 2>&1
}

_m2x_kube_context() {
  print -r -- "k8s:$(command kubectl config current-context 2>/dev/null)"
}

# Default namespace: explicit override, else whatever the context selects,
# else "default" - the same order kubectl itself uses.
_m2x_kube_ns() {
  [[ -n "$M2X_KUBE_NS" ]] && { print -r -- "$M2X_KUBE_NS"; return }
  local ns
  ns=$(command kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
  print -r -- "${ns:-default}"
}

# Targets are listed as namespace/pod so an ambiguous fragment can be resolved
# across namespaces rather than silently inside one.
_m2x_kube_list() {
  if [[ -n "$M2X_KUBE_NS" ]]; then
    _m2x_bounded 3 kubectl get pods -n "$M2X_KUBE_NS" --no-headers -o custom-columns=':metadata.name' 2>/dev/null \
      | sed "s#^#$M2X_KUBE_NS/#"
  else
    _m2x_bounded 3 kubectl get pods --all-namespaces --no-headers \
      -o custom-columns=':metadata.namespace,:metadata.name' 2>/dev/null \
      | awk 'NF==2 {print $1"/"$2}'
  fi
}

# [namespace/]pod[:container] -> ns, pod, container
_m2x_kube_parse() {
  local t="$1" ns pod c
  case "$t" in
    */*) ns=${t%%/*}; t=${t#*/} ;;
    *)   ns=$(_m2x_kube_ns) ;;
  esac
  case "$t" in
    *:*) pod=${t%%:*}; c=${t#*:} ;;
    *)   pod=$t; c="" ;;
  esac
  print -r -- "$ns"; print -r -- "$pod"; print -r -- "$c"
}

_m2x_kube_exec() {
  local t=$1 u=$2; shift 2
  local -a p; p=(${(f)"$(_m2x_kube_parse "$t")"})
  # A pod's containers do not run as an arbitrary user on request; -u has no
  # kubectl equivalent. Saying so beats silently ignoring the argument.
  [[ -n "$u" ]] && _m2x_warn "kubectl cannot switch user; ignoring -u $u"
  local -a cf; [[ -n "$p[3]" ]] && cf=(-c "$p[3]")
  command kubectl exec -i -n "$p[1]" "$p[2]" $cf -- "$@"
}

_m2x_kube_shell() {
  local t=$1 u=$2 sh=$3
  local -a p; p=(${(f)"$(_m2x_kube_parse "$t")"})
  [[ -n "$u" ]] && _m2x_warn "kubectl cannot switch user; ignoring -u $u"
  local -a cf; [[ -n "$p[3]" ]] && cf=(-c "$p[3]")
  command kubectl exec -it -n "$p[1]" "$p[2]" $cf -- "$sh" -l
}

_m2x_kube_logs() {
  local t=$1; shift
  local -a p; p=(${(f)"$(_m2x_kube_parse "$t")"})
  local -a cf; [[ -n "$p[3]" ]] && cf=(-c "$p[3]")
  command kubectl logs -n "$p[1]" "$p[2]" $cf "$@"
}

# Restarting a pod is not a thing. Roll the workload that owns it, and say which
# one, because the blast radius is every replica rather than the one pod named.
_m2x_kube_restart() {
  local t=$1
  local -a p; p=(${(f)"$(_m2x_kube_parse "$t")"})
  local owner
  owner=$(command kubectl get pod -n "$p[1]" "$p[2]" \
            -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}' 2>/dev/null)
  case "$owner" in
    ReplicaSet/*)
      local rs=${owner#ReplicaSet/} dep
      dep=$(command kubectl get rs -n "$p[1]" "$rs" \
              -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null)
      [[ -n "$dep" ]] || { _m2x_err "cannot find the Deployment behind $rs"; return 1 }
      _m2x_info "rolling deployment/$dep in $p[1] (every replica, not just $p[2])"
      command kubectl rollout restart -n "$p[1]" "deployment/$dep"
      ;;
    StatefulSet/*|DaemonSet/*)
      local kind=${owner%%/*} name=${owner#*/}
      _m2x_info "rolling ${kind:l}/$name in $p[1]"
      command kubectl rollout restart -n "$p[1]" "${kind:l}/$name"
      ;;
    "")
      _m2x_err "pod $p[2] has no controller - deleting it would not recreate it"
      return 1 ;;
    *)
      _m2x_err "unsupported owner: $owner"; return 1 ;;
  esac
}

_m2x_kube_forward() {
  local t=$1 spec=$2
  local -a p; p=(${(f)"$(_m2x_kube_parse "$t")"})
  _m2x_info "port-forward $p[1]/$p[2] $spec  (ctrl-c to stop)"
  command kubectl port-forward -n "$p[1]" "pod/$p[2]" "$spec"
}
