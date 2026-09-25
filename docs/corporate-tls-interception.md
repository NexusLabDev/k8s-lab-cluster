# Corporate TLS interception

On a managed laptop an outbound proxy terminates and re-signs TLS. macOS
trusts its CA, so the host is fine — `podman pull`, `helm repo add` and
`git clone` all work. Nothing *inside* the cluster inherits that trust.

Verified from inside a kind node:

```
$ openssl s_client -connect registry.k8s.io:443 -servername registry.k8s.io
   i:CN=<corporate intermediate CA>
   i:CN=<corporate root CA>
```

## Symptom

```
Failed to pull image "registry.k8s.io/...":
  failed to do request: tls: failed to verify certificate:
  x509: certificate signed by unknown authority
```

A kind node is a container with its own `/etc/ssl/certs`. containerd is a Go
binary reading that bundle, so it rejects the re-signed certificate.

## Two places it bites

Node trust only covers image pulls. Argo CD's `repo-server` fetches Helm
charts and clones Git itself, in a pod, with its own trust store — so it fails
independently:

```
helm pull --repo https://charts.jetstack.io cert-manager
  x509: certificate signed by unknown authority
```

That one stalls the whole lab: cert-manager is sync-wave −7, so pki (−5) and
platform-gateway (−3) never run, no gateway Services exist, and
`scripts/lb.sh status` shows no load balancers. The visible symptom is "I can't reach the Argo CD URL", three
layers away from the cause.

## How the CA is found

`scripts/corp-ca.sh` detects it rather than hardcoding a vendor:

1. Probe the hosts the lab actually fetches from and collect every issuer CN
   in the chains that come back.
2. List the CA certificates installed in `/Library/Keychains/System.keychain`.
3. Export only the certificates present in **both** sets.

Step 3 is the important one. A managed laptop typically carries a dozen
corporate CAs — MDM, device identity, internal PKI, code signing. The lab has
no business trusting any of them except the one actually intercepting it, and
a blanket export would quietly widen the cluster's trust far beyond the
problem being solved.

Interception is usually applied per destination category, so probing a single
host proves nothing about the rest — hence the list. If detection is wrong or
you want to supply the CA yourself:

```bash
CORP_CA_FILE=/path/to/root.pem scripts/corp-ca.sh
```

The result lands in `pki/corp-ca.crt`, which is **gitignored**. It is a public
certificate rather than a secret, but it names the organisation, and these
repos are public.

## How it is delivered

**To the nodes** — copied to `/usr/local/share/ca-certificates/`, then
`update-ca-certificates` and a `containerd` restart, because containerd reads
the bundle only at startup. The `rehash: warning: skipping
ca-certificates.crt` line is normal noise, not a failure.

**To Argo CD** — published as Secret `argocd/corp-ca` before the bootstrap, so
it exists when repo-server first starts. `components/argocd/values.yaml` in
**k8s-lab-platform-infra** mounts it at `/etc/ssl/corp` and sets:

```yaml
SSL_CERT_DIR: /etc/ssl/certs:/etc/ssl/corp
```

Go reads the default bundle *and* every directory in `SSL_CERT_DIR`, so this
adds the corporate root without replacing the public ones. The volume is
`optional: true`, so a machine with no interception still starts.

This is deliberately system-wide rather than a per-hostname
`configs.tls.certificates` entry: the per-host form works until the proxy's
policy moves to another domain, then fails silently.

Because nodes are destroyed with the cluster, this must run after every
`scripts/up.sh` — which is why it is wired into that script rather than
written up as a manual step.

## One subtlety, because it looks like it should fail

Kubernetes projects Secret keys as symlinks (`corp-ca.crt -> ..data/corp-ca.crt`),
and Go's certificate loader deliberately skips symlinks in a cert directory.
It skips only *same-directory* symlinks, and this target contains a `/`, so it
is read.

That was confirmed by running the failing `helm pull` inside the pod, not by
reading the source — it is too easy to get backwards.

## What needs nothing

`argocd-server` and the application controller do not fetch remote repos. An
application calling an external API over HTTPS would need its own trust
configuration; none do today.
