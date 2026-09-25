#!/usr/bin/env bash
# Shared constants and helpers. Sourced by the other scripts, not run directly.

# kind talks to podman, not docker.
export KIND_EXPERIMENTAL_PROVIDER=podman

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The lab's own registries config, never the user-wide one. See the file.
export CONTAINERS_REGISTRIES_CONF="$REPO_ROOT/podman/registries.conf"

CLUSTER_NAME=k8s-lab
# kind creates and owns this podman network; the controller joins it so it can
# reach the API server by node name.
KIND_NETWORK=kind

# cloud-provider-kind: turns Services of type LoadBalancer into Envoy containers
# that publish the Service ports on the laptop. Run as a container inside the
# podman VM -- the macOS binary refuses to start without sudo.
CCM_NAME=k8s-lab-ccm
CCM_IMAGE=registry.k8s.io/cloud-provider-kind/cloud-controller-manager:v0.11.1
CCM_ARGS=(
  # Istio is the only Gateway API implementation in the lab.
  --gateway-channel disabled
  --enable-default-ingress=false
  # Publish LB ports on the host; the nodes' IPs are unreachable from macOS.
  --enable-lb-port-mapping
)
# The VM's rootful podman socket, mounted as the controller's docker socket.
# The path is inside the podman VM, not on the Mac.
PODMAN_SOCKET=/run/podman/podman.sock
# Label cloud-provider-kind puts on the Envoy containers it creates.
CCM_LB_LABEL="io.x-k8s.cloud-provider-kind.cluster=$CLUSTER_NAME"

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

ccm_exists() {
  podman container exists "$CCM_NAME"
}
