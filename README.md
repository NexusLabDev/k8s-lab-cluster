# k8s-lab-cluster

Owned by **platform-team**. The bottom layer of the lab: the kind cluster and
the edge load balancer that publishes its gateways on the laptop.

This is the only repo in the lab that is **not** GitOps-managed, for the
obvious reason that something has to exist before Argo CD can run. It is two
scripts and two config files, and nothing that runs *on* the cluster belongs
here.

```
kind/cluster.yaml     node topology
edge-lb/haproxy.cfg   host ports -> gateway NodePorts
scripts/              up, down, edge-lb, corp-ca, trust-ca
docs/                 scale-to-two-workers, corporate-tls-interception
```

## The contract

The gateway NodePorts are pinned by the `platform-gateway` chart in
`k8s-lab-platform-infra`. This repo only publishes them; it does not get to
choose them. Changing either side without the other breaks ingress.

| Gateway | Hostnames | NodePort https/http | Host port | Redirect target |
|---|---|---|---|---|
| `public` | `*.apps.localhost` | 30443 / 30080 | 8443 / 8080 | 8443 |
| `internal` | `*.internal.localhost` | 31443 / 31080 | 9443 / 9080 | 9443 |

`*.localhost` resolves to the local machine without DNS or `/etc/hosts`.

## Bring the lab up

```bash
scripts/up.sh                                    # cluster + edge LB
cd ../k8s-lab-platform-infra && bootstrap/install.sh   # Argo CD, then Git owns it
cd ../k8s-lab-cluster && scripts/trust-ca.sh     # once the pki app has synced
```

Verify:

```bash
curl --cacert .lab-ca.crt https://hello.apps.localhost:8443/hello
curl --cacert .lab-ca.crt https://tools.internal.localhost:9443/hello
open https://argocd.internal.localhost:9443
```

Tear it down with `scripts/down.sh`.

## Why an edge LB and not `extraPortMappings`

kind can publish a node's ports directly, which would need no proxy at all.
It is rejected here for one reason: it binds the ingress path to a *named
node*. The moment the topology changes the mapping is wrong, and it models
something no real cluster does — production traffic arrives at a load
balancer, not at a node.

HAProxy is `mode tcp` throughout. The Istio gateways terminate TLS and route
on SNI, so the edge must pass bytes through untouched; terminating here would
break both the certificate chain and hostname routing.

Both nodes are backends even though only the worker runs gateway pods.
NodePorts answer on every node (`externalTrafficPolicy: Cluster`), so the
control-plane forwards to the worker, and the edge LB survives losing either
one. `http://localhost:8404` shows which backends are up.

HAProxy resolves node names once at startup, so **after anything recreates a
node container, run `scripts/edge-lb.sh restart`**.

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
| `curl: (7) connection refused` on 8443 | edge LB down — `scripts/edge-lb.sh status` |
| Backends `DOWN` at :8404 | node names stale after a restart — `edge-lb.sh restart` |
| `curl: (60)` certificate error | lab CA not exported/trusted — `scripts/trust-ca.sh` |
| `ImagePullBackOff` with `x509: certificate signed by unknown authority` | nodes don't trust the corporate CA — `scripts/corp-ca.sh` |
| Argo CD repo-server can't clone from GitHub | same corporate CA, inside the cluster — see the doc above |
| 404 from the gateway | route attached, hostname wrong, or namespace missing its `gateway-access/*` label |
| Pods `Evicted` / `OOMKilled` | podman machine memory — raise it as above |
