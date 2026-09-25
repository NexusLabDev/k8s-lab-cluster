# k8s-lab-cluster

Owned by **platform-team**. The bottom layer of the lab: the kind cluster and
the load balancer that publishes its gateways on the laptop.

This is the only repo in the lab that is **not** GitOps-managed, for the
obvious reason that something has to exist before Argo CD can run. It is two
scripts and two config files, and nothing that runs *on* the cluster belongs
here.

```
kind/cluster.yaml         node topology
podman/registries.conf    the lab's registries config (the user-wide one is never read)
scripts/                  up, down, lb, corp-ca, trust-ca
docs/                     scale-to-two-workers, corporate-tls-interception
```

## The contract

The gateways are `LoadBalancer` Services whose ports are set by the
`platform-gateway` chart in `k8s-lab-platform-infra`. This repo runs the load
balancer that publishes them; it does not get to choose them. The load
balancer publishes each Service port 1:1 on the laptop, so the ports in the
chart *are* the laptop ports.

| Gateway | Hostnames | Service = host port https/http | Redirect target |
|---|---|---|---|
| `public` | `*.apps.localhost` | 8443 / 8080 | 8443 |
| `internal` | `*.internal.localhost` | 9443 / 9080 | 9443 |

`*.localhost` resolves to the local machine without DNS or `/etc/hosts`.

## Bring the lab up

```bash
scripts/up.sh                                    # cluster + load balancer
cd ../platform-infra && bootstrap/install.sh           # Argo CD, then Git owns it
cd ../k8s-lab-cluster && scripts/trust-ca.sh --install # once the pki app has synced
```

Verify:

```bash
curl --cacert .lab-ca.crt https://hello.apps.localhost:8443/hello
curl --cacert .lab-ca.crt https://tools.internal.localhost:9443/hello
open https://argocd.internal.localhost:9443
```

`--install` trusts the lab CA system-wide, which is what browsers need; plain
`trust-ca.sh` only writes the file for `curl --cacert`. Both are safe to re-run.

Tear it down with `scripts/down.sh`.

## Why cloud-provider-kind, and not `extraPortMappings`

kind can publish a node's ports directly, which would need nothing else. It is
rejected here because it binds the ingress path to a *named node*: the moment
the topology changes the mapping is wrong, and it models something no real
cluster does. Production traffic arrives at a load balancer, not at a node.

[cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind)
is the kind project's cloud controller. It gives the gateways the same shape
they would have on EKS -- `type: LoadBalancer`, with an address in
`status.loadBalancer` -- by starting one Envoy container (`kindccm-*`) per
LoadBalancer Service. Every Ready node is a backend, and nodes that join later
are added on their own. TLS passes through untouched to the Istio gateways,
which terminate it.

Three things about running it on podman on macOS, all found the hard way:

- **It runs as a container, not the Homebrew binary.** The macOS binary
  refuses to start without `sudo`. Inside the podman VM it is Linux and needs
  no root on the Mac. `scripts/lb.sh` runs it as `k8s-lab-ccm`.
- **SELinux.** The podman VM enforces SELinux, which denies the container the
  podman socket; the controller then fails with "no supported container
  runtime found". `lb.sh` runs it with `--security-opt label=disable`.
- **Every LoadBalancer needs its own ports.** Each load balancer binds its
  Service ports on the laptop, so two Services on the same port can't both
  exist; the second stays `<pending>`. That is why the gateways listen on
  8443/8080 and 9443/9080 instead of both on 443/80 -- and why the chart
  removes Istio's health port 15021, which Istio adds to *every* gateway
  Service (`hideStatusPort` in the platform-gateway chart).

It also runs with Gateway API and its default ingress **disabled**: Istio is the
lab's Gateway API implementation, and a second one would fight it for the
CRDs. And it serves *every* kind cluster on the machine, not only this one, so
its log shows errors for any other cluster that is stopped. Those are harmless.

**The load balancer has to be running before the bootstrap.** Istio marks a
Gateway `Programmed` only once its Service has an address. Without the
controller the `platform-gateway` app never turns Healthy, and Argo CD's wave
gate holds back everything after it. `scripts/up.sh` starts it for you.

## Topology

One control-plane, one worker. kind taints the control-plane as soon as a
worker exists, so every workload — including both `public` gateway replicas —
lands on that single worker. The PodDisruptionBudget stays satisfiable, but
the two replicas are not genuinely fault-tolerant: one node reboot takes both.

That is a deliberate tradeoff against a 6 CPU / 8 GiB VM. See
[docs/scale-to-two-workers.md](docs/scale-to-two-workers.md) for what the
second worker buys and what it costs.

## Two CAs, and they are not the same thing

This lab deals with two unrelated certificate authorities. Confusing them
costs an afternoon.

| | Corporate CA | Lab CA (`lab-ca`) |
|---|---|---|
| Who | Your organisation's TLS-inspecting proxy | cert-manager, from `components/pki` |
| Signs | Everything the cluster pulls *from the internet* | The gateway certs *inside* the lab |
| Needed by | containerd on each node, Argo CD's repo-server | curl and your browser, on the host |
| Script | `scripts/corp-ca.sh` (run by `up.sh`) | `scripts/trust-ca.sh` (run by you) |

Without the first, image pulls fail with `x509: certificate signed by unknown
authority` and Argo CD stalls at wave −7 before any gateway exists. Without the
second, every `curl` fails with a certificate error. `corp-ca.sh` detects the
intercepting CA at run time and publishes Secret `argocd/corp-ca` for Argo CD's
repo-server; no certificate is committed. See
[docs/corporate-tls-interception.md](docs/corporate-tls-interception.md).

## Requirements

| Tool | Version used |
|---|---|
| podman | 6.1.2, machine rootful |
| kind | 0.33 |
| cloud-provider-kind | v0.11.1, as a container (pulled by `lb.sh`) |
| kubectl, helm | any recent |

The full stack (ambient Istio, Argo CD, 2 gateway replicas, 4 app pods) is
tight on 8 GiB. `scripts/up.sh` warns below 12 GiB:

```bash
podman machine stop
podman machine set --cpus 8 --memory 12288
podman machine start
```

## Troubleshooting

| Symptom | Cause |
|---|---|
| `curl: (7) connection refused` on 8443 | load balancer down — `scripts/lb.sh status` |
| Gateway Service EXTERNAL-IP `<pending>`, `platform-gateway` stuck Progressing | controller not running — `scripts/lb.sh status`, then `lb.sh restart` |
| Second gateway `<pending>`, first fine, its `kindccm-*` container stuck `Created` | two LoadBalancer Services share a port (check 15021 too) — give each its own ports, then `lb.sh restart` |
| `curl: (60)` certificate error | lab CA not exported — `scripts/trust-ca.sh` |
| Browser cert error, `curl --cacert` fine | lab CA not in the keychain — `scripts/trust-ca.sh --install` |
| Browser cert error *after* a cluster recreate | keychain holds the previous cluster's root — `trust-ca.sh --install` replaces it |
| `ImagePullBackOff` with `x509: certificate signed by unknown authority` | nodes don't trust the corporate CA — `scripts/corp-ca.sh` |
| Argo CD repo-server can't clone from GitHub | same corporate CA, inside the cluster — see the doc above |
| 404 from the gateway | route attached, hostname wrong, or namespace missing its `gateway-access/*` label |
| Pods `Evicted` / `OOMKilled` | podman machine memory — raise it as above |
