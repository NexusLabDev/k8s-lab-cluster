#!/usr/bin/env bash
# Create the lab cluster and publish its gateways on the laptop.
#
# This script owns the two things GitOps cannot own: the cluster itself and the
# edge load balancer. Everything else is Argo CD's job -- see the "next steps"
# printed at the end.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

preflight() {
  require_tools podman kind kubectl

  podman machine inspect >/dev/null 2>&1 \
    || die "podman machine is not reachable; run 'podman machine start'"

  # kind on a rootless machine needs cgroup delegation workarounds; a rootful
  # machine needs none. Warn rather than block -- it may still work.
  local rootful
  rootful="$(podman machine inspect --format '{{.Rootful}}' 2>/dev/null | head -1)"
  [[ "$rootful" == "true" ]] \
    || warn "podman machine is rootless; kind may need cgroup delegation tweaks"

  # Ambient Istio + Argo CD + gateway replicas + tenant apps is a real
  # workload. Below ~12 GiB the cluster comes up but pods start getting
  # evicted once the tenant apps land.
  local mem
  mem="$(podman machine inspect --format '{{.Resources.Memory}}' 2>/dev/null | head -1 | tr -cd '0-9')"
  if [[ -n "$mem" && "$mem" -lt 12288 ]]; then
    warn "podman machine has ${mem} MiB; 12288 recommended for the full stack"
    warn "  podman machine stop && podman machine set --cpus 8 --memory 12288 && podman machine start"
  fi
}

create_cluster() {
  if cluster_exists; then
    info "cluster '$CLUSTER_NAME' already exists"
    return
  fi
  info "creating cluster '$CLUSTER_NAME' (1 control-plane + 1 worker)"
  kind create cluster --config "$REPO_ROOT/kind/cluster.yaml" --wait 120s
}

preflight
create_cluster
"$REPO_ROOT/scripts/corp-ca.sh"
"$REPO_ROOT/scripts/edge-lb.sh" start

cat <<EOF

Cluster is up. Nothing is deployed on it yet.

  next   cd ../k8s-lab-platform-infra && bootstrap/install.sh
  ui     https://argocd.internal.localhost:9443
  apps   https://hello.apps.localhost:8443/hello
         https://tools.internal.localhost:9443/hello
  lb     http://localhost:8404

Certificates are signed by the lab's own CA, so clients will not trust them
until you run scripts/trust-ca.sh (or pass curl -k).
EOF
