#!/usr/bin/env bash
# Destroy the lab cluster and its load balancers.
#
# This deletes the cluster and everything running on it. Nothing of value
# should live only here -- all state is reproducible from the GitOps repos.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ "${1:-}" != "-y" ]]; then
  read -rp "Delete kind cluster '$CLUSTER_NAME' and its load balancers? [y/N] " reply
  [[ "$reply" == [yY] ]] || { info "aborted"; exit 0; }
fi

"$REPO_ROOT/scripts/lb.sh" stop

if cluster_exists; then
  info "deleting cluster '$CLUSTER_NAME'"
  kind delete cluster --name "$CLUSTER_NAME"
else
  info "cluster '$CLUSTER_NAME' is not present"
fi

# The lab CA dies with the cluster; leaving it trusted is a dangling root.
if security find-certificate -c "k8s-lab Root CA" /Library/Keychains/System.keychain >/dev/null 2>&1; then
  warn "'k8s-lab Root CA' is still trusted system-wide; remove it with scripts/trust-ca.sh --uninstall"
fi
