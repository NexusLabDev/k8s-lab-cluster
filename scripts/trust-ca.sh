#!/usr/bin/env bash
# Export the lab root CA so local clients trust the gateway certificates.
#
# The CA is created by cert-manager from k8s-lab-platform-infra (components/pki)
# and lives in Secret cert-manager/lab-root-ca. It is regenerated whenever the
# cluster is recreated, so re-run this after every scripts/up.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OUT="$REPO_ROOT/.lab-ca.crt"

kubectl get secret lab-root-ca -n cert-manager -o jsonpath='{.data.ca\.crt}' \
  | base64 -d > "$OUT"

[[ -s "$OUT" ]] || die "lab-root-ca is empty; has platform-infra finished syncing?"

info "wrote $OUT"
cat <<EOF

Use it per-command:

  curl --cacert $OUT https://hello.apps.localhost:8443/hello

Or trust it system-wide (asks for your password, affects every app including
browsers). Remove it with 'security delete-certificate -c "k8s-lab Root CA"'
when you tear the lab down:

  sudo security add-trusted-cert -d -r trustRoot \\
    -k /Library/Keychains/System.keychain $OUT
EOF
