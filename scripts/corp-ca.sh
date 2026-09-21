#!/usr/bin/env bash
# Teach the cluster to trust the corporate TLS-inspecting proxy.
#
# On a managed laptop an outbound proxy terminates and re-signs TLS. macOS
# trusts its CA, which is why `podman pull` and `helm repo add` work on the
# host -- but a kind node is a container with its own trust store, so
# containerd fails every image pull with:
#
#   x509: certificate signed by unknown authority
#
# This script:
#   1. detects which locally-installed CA is doing the interception
#   2. installs it into every node, for containerd
#   3. publishes it as Secret argocd/corp-ca, for Argo CD's repo-server
#      (a pod does not inherit node trust, and repo-server fetches Helm
#      charts over HTTPS itself)
#
# Nothing here is vendor-specific and no certificate is committed: the CA is
# read from this machine's keychain at run time. Run after every cluster
# create -- nodes are thrown away with the cluster, so the trust goes too.
#
# Set CORP_CA_FILE to a PEM to skip detection entirely.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CA_FILE="$REPO_ROOT/pki/corp-ca.crt"

# Hosts the lab actually fetches from. Interception is usually applied per
# destination category, so probing one host proves nothing about the rest.
PROBE_HOSTS=(
  charts.jetstack.io
  istio-release.storage.googleapis.com
  argoproj.github.io
  kubernetes-sigs.github.io
  github.com
  registry.k8s.io
  registry-1.docker.io
)

TIMEOUT="$(command -v timeout || command -v gtimeout || true)"

probe() {
  local host="$1"
  ${TIMEOUT:+$TIMEOUT 8} openssl s_client -connect "$host:443" -servername "$host" \
    -showcerts </dev/null 2>/dev/null
}

# Every CA that signed something in the chains we were served, by CN.
# Both line shapes matter: "issuer=" is only the leaf's issuer, while the
# " i:" chain lines carry the rest -- including the root, which is the one
# actually installed in the keychain.
observed_issuers() {
  local host
  for host in "${PROBE_HOSTS[@]}"; do
    probe "$host" | sed -n -e 's/^issuer=.*CN *= *//p' -e 's/^ *i:.*CN *= *//p'
  done | sed 's/,.*//; s/^ *//; s/ *$//' | sort -u
}

split_keychain() {
  security find-certificate -a -p /Library/Keychains/System.keychain 2>/dev/null \
    | awk -v d="$1" '/BEGIN CERT/{n++} n{print > (d "/cert-" n ".pem")}'
}

is_ca() {
  openssl x509 -in "$1" -noout -text 2>/dev/null \
    | grep -A1 'Basic Constraints' | grep -q 'CA:TRUE'
}

subject_cn() {
  openssl x509 -in "$1" -noout -subject 2>/dev/null \
    | sed 's/.*CN *= *//; s/,.*//; s/^ *//; s/ *$//'
}

# Export only the CAs that both (a) appear as an issuer in a chain we were
# actually served and (b) are installed on this machine. A managed laptop
# carries many corporate CAs -- MDM, device identity, internal PKI -- and the
# lab has no business trusting any of them except the one intercepting it.
extract() {
  if [[ -n "${CORP_CA_FILE:-}" ]]; then
    mkdir -p "$(dirname "$CA_FILE")"
    cp "$CORP_CA_FILE" "$CA_FILE"
    info "using CA from CORP_CA_FILE"
    return 0
  fi

  local tmp issuers found=0 pem cn
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  issuers="$(observed_issuers)"
  [[ -n "$issuers" ]] || return 1

  split_keychain "$tmp"
  mkdir -p "$(dirname "$CA_FILE")"
  : > "$CA_FILE"

  for pem in "$tmp"/cert-*.pem; do
    [[ -s "$pem" ]] || continue
    is_ca "$pem" || continue
    cn="$(subject_cn "$pem")"
    [[ -n "$cn" ]] && grep -Fxq "$cn" <<<"$issuers" || continue
    info "intercepting CA detected: $cn"
    cat "$pem" >> "$CA_FILE"
    found=$((found + 1))
  done

  [[ $found -gt 0 ]] || { rm -f "$CA_FILE"; return 1; }
}

inject() {
  local nodes
  nodes="$(kind get nodes --name "$CLUSTER_NAME")"
  for node in $nodes; do
    info "trusting CA in $node"
    podman cp "$CA_FILE" "$node:/usr/local/share/ca-certificates/corp-ca.crt"
    podman exec "$node" update-ca-certificates >/dev/null
    # containerd reads the bundle once at startup.
    podman exec "$node" systemctl restart containerd
  done

  for node in $nodes; do
    podman exec "$node" timeout 60 sh -c \
      'until crictl info >/dev/null 2>&1; do sleep 1; done' \
      || die "containerd did not come back on $node"
  done
  info "all nodes trust the corporate CA"
}

# Mounted by repo-server; see components/argocd/values.yaml in
# k8s-lab-platform-infra. Created before the bootstrap so it is already there
# when repo-server first starts.
publish_secret() {
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create secret generic corp-ca \
    --namespace argocd \
    --from-file=corp-ca.crt="$CA_FILE" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  info "published Secret argocd/corp-ca"
}

if ! extract; then
  info "no TLS interception detected on the probed hosts; nothing to trust"
  exit 0
fi
inject
publish_secret
