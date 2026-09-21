#!/usr/bin/env bash
# Destroy the lab cluster and the edge load balancer.
#
# This deletes the cluster and everything running on it. Nothing of value
# should live only here -- all state is reproducible from the GitOps repos.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ "${1:-}" != "-y" ]]; then
  read -rp "Delete kind cluster '$CLUSTER_NAME' and the edge LB? [y/N] " reply
  [[ "$reply" == [yY] ]] || { info "aborted"; exit 0; }
fi

"$REPO_ROOT/scripts/edge-lb.sh" stop

if cluster_exists; then
  info "deleting cluster '$CLUSTER_NAME'"
  kind delete cluster --name "$CLUSTER_NAME"
else
  info "cluster '$CLUSTER_NAME' is not present"
fi
