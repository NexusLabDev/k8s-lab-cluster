#!/usr/bin/env bash
# Start (or restart) the edge load balancer in front of the cluster.
#
#   edge-lb.sh start     create the container if it is missing
#   edge-lb.sh restart   recreate it -- do this after any node is recreated,
#                        because HAProxy resolves node names once at startup
#   edge-lb.sh stop      remove the container, leave the cluster alone
#   edge-lb.sh status    is it up, and are both backends healthy
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

start() {
  cluster_exists || die "cluster '$CLUSTER_NAME' does not exist; run scripts/up.sh first"

  if edge_lb_exists; then
    info "edge LB already exists; use 'edge-lb.sh restart' to pick up node changes"
    podman start "$EDGE_LB_NAME" >/dev/null
    return
  fi

  local publish=()
  for port in "${EDGE_LB_PORTS[@]}"; do
    publish+=(--publish "${port}:${port}")
  done

  info "starting edge LB ($EDGE_LB_IMAGE) on ${EDGE_LB_PORTS[*]}"
  podman run --detach \
    --name "$EDGE_LB_NAME" \
    --network "$KIND_NETWORK" \
    --restart unless-stopped \
    "${publish[@]}" \
    --volume "$REPO_ROOT/edge-lb/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" \
    "$EDGE_LB_IMAGE" >/dev/null

  # HAProxy exits immediately on a bad config; catch that here rather than
  # letting the user discover it as a connection refused ten minutes later.
  sleep 2
  if [[ "$(podman inspect -f '{{.State.Running}}' "$EDGE_LB_NAME")" != "true" ]]; then
    podman logs "$EDGE_LB_NAME" >&2 || true
    die "edge LB failed to start (see logs above)"
  fi
  info "edge LB up; stats at http://localhost:8404"
}

stop() {
  edge_lb_exists || { info "edge LB is not present"; return; }
  info "removing edge LB"
  podman rm --force "$EDGE_LB_NAME" >/dev/null
}

status() {
  if ! edge_lb_exists; then
    echo "edge LB: absent"
    return 1
  fi
  echo "edge LB: $(podman inspect -f '{{.State.Status}}' "$EDGE_LB_NAME")"
  # The stats page in CSV form: one line per backend server, with its state.
  curl -sf 'http://localhost:8404/;csv' 2>/dev/null \
    | awk -F, '$2!="FRONTEND" && $2!="BACKEND" && $1!="" {printf "  %-22s %-14s %s\n", $1, $2, $18}' \
    || warn "stats endpoint not answering yet"
}

case "${1:-start}" in
  start)   start ;;
  restart) stop; start ;;
  stop)    stop ;;
  status)  status ;;
  *)       die "usage: edge-lb.sh [start|restart|stop|status]" ;;
esac
