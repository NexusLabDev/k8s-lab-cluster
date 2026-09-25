#!/usr/bin/env bash
# Start (or restart) the load balancer controller for the cluster.
#
# cloud-provider-kind watches Services of type LoadBalancer and gives each one
# an Envoy container (kindccm-*) that publishes the Service's ports on the
# laptop -- the lab's stand-in for a cloud provider's load balancer.
#
#   lb.sh start     create the controller if it is missing
#   lb.sh restart   recreate the controller and its load balancers
#   lb.sh stop      remove the controller and its load balancers
#   lb.sh status    controller state, published ports, gateway addresses
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# How long to wait for the controller to reach the cluster's API server.
CONNECT_TIMEOUT=30

start() {
  cluster_exists || die "cluster '$CLUSTER_NAME' does not exist; run scripts/up.sh first"

  if ccm_exists; then
    info "load balancer controller already exists; use 'lb.sh restart' to recreate it"
    podman start "$CCM_NAME" >/dev/null
    return
  fi

  # label=disable: the podman VM runs SELinux, which otherwise denies the
  # container access to the podman socket ("no supported container runtime").
  info "starting load balancer controller ($CCM_IMAGE)"
  podman run --detach \
    --name "$CCM_NAME" \
    --network "$KIND_NETWORK" \
    --restart unless-stopped \
    --security-opt label=disable \
    --volume "$PODMAN_SOCKET:/var/run/docker.sock" \
    "$CCM_IMAGE" "${CCM_ARGS[@]}" >/dev/null

  # The controller exits at once if it can't find a container runtime, and
  # otherwise keeps retrying forever; catch both here rather than as a gateway
  # stuck Progressing ten minutes into the bootstrap.
  local waited=0
  # No `grep -q`: it exits on the first match, podman logs then dies of
  # SIGPIPE, and pipefail turns a match into a failure.
  until podman logs "$CCM_NAME" 2>&1 | grep "Connected successfully.*cluster=\"$CLUSTER_NAME\"" >/dev/null; do
    if [[ "$(podman inspect -f '{{.State.Running}}' "$CCM_NAME")" != "true" ]]; then
      podman logs "$CCM_NAME" >&2 || true
      die "load balancer controller exited (see logs above)"
    fi
    (( waited >= CONNECT_TIMEOUT )) && die "controller did not reach cluster '$CLUSTER_NAME' in ${CONNECT_TIMEOUT}s; check 'podman logs $CCM_NAME'"
    sleep 2; waited=$((waited + 2))
  done
  info "load balancer controller connected to '$CLUSTER_NAME'"
}

stop() {
  if ccm_exists; then
    info "removing load balancer controller"
    podman rm --force "$CCM_NAME" >/dev/null
  else
    info "load balancer controller is not present"
  fi

  # The Envoy containers outlive both the controller and `kind delete cluster`.
  local lbs
  lbs="$(podman ps --all --quiet --filter "label=$CCM_LB_LABEL")"
  if [[ -n "$lbs" ]]; then
    info "removing $(wc -l <<<"$lbs" | tr -d ' ') load balancer container(s)"
    # shellcheck disable=SC2086 # one container ID per word
    podman rm --force $lbs >/dev/null
  fi
}

status() {
  if ! ccm_exists; then
    echo "controller: absent"
    return 1
  fi
  echo "controller: $(podman inspect -f '{{.State.Status}}' "$CCM_NAME")"

  echo "load balancers:"
  podman ps --all --filter "label=$CCM_LB_LABEL" \
    --format '  {{.Names}}  {{.Status}}  {{.Ports}}'

  echo "gateway services:"
  kubectl --context "kind-$CLUSTER_NAME" get service --namespace infra-gw \
    --field-selector spec.type=LoadBalancer 2>/dev/null \
    | sed 's/^/  /' \
    || warn "no gateway services yet (has Argo CD synced platform-gateway?)"
}

case "${1:-start}" in
  start)   start ;;
  restart) stop; start ;;
  stop)    stop ;;
  status)  status ;;
  *)       die "usage: lb.sh [start|restart|stop|status]" ;;
esac
