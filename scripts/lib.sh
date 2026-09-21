#!/usr/bin/env bash
# Shared constants and helpers. Sourced by the other scripts, not run directly.

# kind talks to podman, not docker.
export KIND_EXPERIMENTAL_PROVIDER=podman

CLUSTER_NAME=k8s-lab
EDGE_LB_NAME=k8s-lab-edge-lb
EDGE_LB_IMAGE=docker.io/library/haproxy:3.0-alpine
# kind creates and owns this podman network; the edge LB joins it so it can
# resolve node containers by name.
KIND_NETWORK=kind

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Ports published on the laptop, mirroring edge-lb/haproxy.cfg.
EDGE_LB_PORTS=(8443 8080 9443 9080 8404)

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_tools() {
  local missing=()
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "missing required tools: ${missing[*]}"
}

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"
}

edge_lb_exists() {
  podman container exists "$EDGE_LB_NAME"
}
