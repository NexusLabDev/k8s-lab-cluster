#!/usr/bin/env bash
# Export the lab root CA so local clients trust the gateway certificates.
#
#   trust-ca.sh              export to .lab-ca.crt and print what to do with it
#   trust-ca.sh --install    also trust it system-wide (asks for your password)
#   trust-ca.sh --uninstall  remove it from the System keychain
#
# The CA is created by cert-manager from k8s-lab-platform-infra (components/pki)
# and lives in Secret cert-manager/lab-root-ca. It is regenerated whenever the
# cluster is recreated, so re-run this after every scripts/up.sh -- --install
# removes the stale root first, which is the step that is easy to forget and
# leaves the browser failing against a CA that no longer exists.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OUT="$REPO_ROOT/.lab-ca.crt"
CA_CN="k8s-lab Root CA"
KEYCHAIN=/Library/Keychains/System.keychain

export_ca() {
  kubectl get secret lab-root-ca -n cert-manager -o jsonpath='{.data.ca\.crt}' \
    | base64 -d > "$OUT"
  [[ -s "$OUT" ]] || die "lab-root-ca is empty; has platform-infra finished syncing?"
  info "wrote $OUT"
}

installed_count() {
  security find-certificate -a -c "$CA_CN" "$KEYCHAIN" 2>/dev/null \
    | grep -c 'keychain:' || true
}

# Older roots from previous clusters share the same CN, so delete in a loop:
# one call removes one certificate.
uninstall_ca() {
  local n
  n="$(installed_count)"
  if [[ "$n" -eq 0 ]]; then
    info "no '$CA_CN' in the System keychain"
    return 0
  fi
  info "removing $n stale '$CA_CN' certificate(s) (sudo)"
  while [[ "$(installed_count)" -gt 0 ]]; do
    sudo security delete-certificate -c "$CA_CN" "$KEYCHAIN" || break
  done
  info "removed"
}

install_ca() {
  [[ -t 0 ]] || die "--install needs a terminal: sudo will prompt for your password"
  warn "this trusts '$CA_CN' for every application on this machine"
  uninstall_ca
  info "trusting $OUT (sudo)"
  sudo security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN" "$OUT"
  info "done -- hard-reload the browser tab"
  warn "Firefox keeps its own trust store; import $OUT there separately"
}

case "${1:-}" in
  --install)
    export_ca
    install_ca
    ;;
  --uninstall)
    uninstall_ca
    ;;
  "")
    export_ca
    cat <<EOF

Use it per-command:

  curl --cacert $OUT https://hello.apps.localhost:8443/hello

Or trust it system-wide, which is what browsers need:

  scripts/trust-ca.sh --install

Undo that with:

  scripts/trust-ca.sh --uninstall
EOF
    ;;
  *)
    die "usage: trust-ca.sh [--install|--uninstall]"
    ;;
esac
