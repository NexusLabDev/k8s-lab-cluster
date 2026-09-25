# Design: replace the HAProxy edge LB with cloud-provider-kind

Date: 2026-09-25 · Status: implemented locally; end-to-end check pending the platform-infra push · Repos: `k8s-lab-cluster`, `k8s-lab-platform-infra`

## Goal

The platform gateways become real `Service type: LoadBalancer` objects with a
populated `status.loadBalancer`, the same shape they would have on EKS, instead
of pinned NodePorts fronted by a hand-maintained HAProxy. Every URL the lab
documents stays exactly as it is today.

## Non-goals

- No change to the app repos (`k8s-lab-hello-alpha`, `k8s-lab-hello-beta`).
- No change to the node topology (1 control-plane + 1 worker).
- No Gateway API from cloud-provider-kind: Istio stays the only implementation.
- No in-place migration of the existing `k8s-lab` cluster (see Migration).

## Spike findings (2026-09-25, throwaway cluster `cpk-spike`, since deleted)

Environment: podman 6.1.2 client / 5.6.2 in a rootful `applehv` machine,
6 CPU / 8 GiB, kind 0.33.0, node image kindest/node v1.37.0.

| Finding | Consequence for the design |
|---|---|
| The host binary refuses to start on macOS unless root (`cmd/app.go`: `GOOS == "darwin" && Geteuid() != 0`). | Run the controller as a **container inside the podman VM**, where the check does not apply. No sudo on the laptop. |
| In the container it fails with `no supported container runtime found`; `docker info` gets `permission denied` on the socket. Cause: SELinux in the Fedora CoreOS VM. | Run with `--security-opt label=disable`. Do not relabel the socket with `:z`. |
| Image is `FROM docker:29-cli`; Docker CLI 29.6 negotiates API 1.41 with podman 5.6.2 fine. | Mount the VM's rootful socket `/run/podman/podman.sock` as `/var/run/docker.sock`. |
| With `--enable-lb-port-mapping` on rootful podman, **host port = Service port** (not the ephemeral port the upstream README describes), reachable from macOS through gvproxy (HTTP 200). | Pin the host ports by pinning the Service ports, which Istio takes from the Gateway listener ports. |
| Two LB Services on the same port: the second stays `<pending>`, its Envoy container fails to be created. | **Every gateway needs unique listener ports.** |
| Host ports survived a controller restart and a deleted-and-recreated Envoy container; only Envoy's admin port (10000 → ephemeral) changed. | Ports are stable enough to document. The admin port cannot be documented. |
| Controller and each Envoy LB use ~11–15 MB. | Cheaper than the HAProxy container it replaces. |
| Defaults `--gateway-channel standard` and `--enable-default-ingress true` would install a second Gateway API controller. | Always pass `--gateway-channel disabled --enable-default-ingress=false`. |
| The controller manages **every** kind cluster on the machine, not just `k8s-lab`. | Harmless, but it logs errors for stopped clusters. Worth a README note. |
| `kind create` failed because the user-wide `~/.config/containers/registries.conf` did not parse; the spike only worked with `CONTAINERS_REGISTRIES_CONF` pointing at a scratch file. | The lab ships its own registries config and never reads the user-wide one. |

## Design

### 1. `k8s-lab-platform-infra`: platform-gateway chart

- `templates/gateways.yaml`: listener ports come from values:
  `port: {{ $gw.ports.https | default 443 }}` and `{{ $gw.ports.http | default 80 }}`.
  Defaults stay 443/80, so the chart remains correct on a cloud cluster.
  The NodePort `service` patch is already guarded by `with $gw.nodePorts`;
  its hard-coded `port: 443` / `port: 80` must follow the same values so the
  guard stays correct if anyone re-adds NodePorts.
- `values.yaml`, both gateways: `serviceType: LoadBalancer`, remove `nodePorts`,
  add `ports`. `redirectPort` unchanged.

  | Gateway | Listener / Service / host port (https, http) | Redirect target |
  |---|---|---|
  | `public` (`*.apps.localhost`) | 8443, 8080 | 8443 |
  | `internal` (`*.internal.localhost`) | 9443, 9080 | 9443 |

- `README.md`: replace the NodePort exposure table with the one above and
  describe how cloud-provider-kind publishes the gateways.

Unaffected (verified by grep): tenant HTTPRoutes attach by `sectionName`; the
Argo CD and traffic-console HTTPRoutes' `port: 80` is a backend Service port.

### 2. `k8s-lab-cluster`: containerized controller replaces the edge LB

- Delete `edge-lb/haproxy.cfg` and `scripts/edge-lb.sh`.
- New `scripts/lb.sh start|stop|restart|status`, same shape as `edge-lb.sh`:
  - `start`: if absent, `podman run --detach --name k8s-lab-ccm --network kind
    --restart unless-stopped --security-opt label=disable
    --volume /run/podman/podman.sock:/var/run/docker.sock
    registry.k8s.io/cloud-provider-kind/cloud-controller-manager:v0.11.1
    --gateway-channel disabled --enable-default-ingress=false --enable-lb-port-mapping`;
    after ~5 s fail loudly (with logs) if it is not running.
  - `stop`: remove `k8s-lab-ccm` **and** every container labelled
    `io.x-k8s.cloud-provider-kind.cluster=k8s-lab`.
  - `status`: controller state; each `kindccm-*` container with its published
    ports; `kubectl get svc -n infra-gw` with EXTERNAL-IP.
- New `podman/registries.conf`, owned by the lab:
  `unqualified-search-registries = ["docker.io"]` and nothing else. Every image
  the lab uses is fully qualified (`docker.io/...`, `registry.k8s.io/...`).
- `scripts/lib.sh`: export `CONTAINERS_REGISTRIES_CONF="$REPO_ROOT/podman/registries.conf"`
  so kind, podman and the controller never read the user's
  `~/.config/containers/registries.conf`. A broken or environment-specific
  global config can then neither break the lab nor leak into it. Replace
  `EDGE_LB_*` constants with `CCM_NAME`, `CCM_IMAGE`, `CCM_ARGS`,
  `PODMAN_SOCKET`; replace `edge_lb_exists` with `ccm_exists`.
- `scripts/up.sh`: call `lb.sh start` instead of `edge-lb.sh start`; drop the
  `lb http://localhost:8404` line from the next-steps text.
- `scripts/down.sh`: call `lb.sh stop` (which also removes the Envoy
  containers `kind delete` leaves behind).
- `kind/cluster.yaml`: comments only. The no-`extraPortMappings` reasoning holds.
- `README.md`: contract table (LoadBalancer, no NodePorts), rewrite "Why an edge
  LB" as "Why cloud-provider-kind" (sudo gate, SELinux, unique-ports rule), and
  update the troubleshooting table (see below). Remove the `:8404` references.
- `docs/scale-to-two-workers.md`: new nodes become LB backends automatically;
  remove the edge-LB restart step and the `:8404` check.

What is lost: the HAProxy stats page on `:8404`. `lb.sh status` replaces it.

### 3. Ordering requirement

Istio marks a LoadBalancer Gateway `Programmed` only once its Service has an
address. Without a running controller the `platform-gateway` wave (-3) never
turns Healthy, and the root app's wave gate stalls everything after it
(Argo CD self-management, traffic-console, both tenants). Therefore:

- `up.sh` starts the controller before printing the bootstrap step.
- README troubleshooting: *gateway / platform-gateway app stuck Progressing,
  EXTERNAL-IP `<pending>`* → `scripts/lb.sh status`, then `lb.sh restart`.

## Migration

Recreate, don't retrofit: cloud-provider-kind does not support mutating the
ports of an existing LB Service, and the migration changes every gateway
Service's type and ports.

1. Apply both repo changes locally; the user pushes `k8s-lab-platform-infra`
   **before** bootstrapping, because Argo CD syncs it from GitHub.
2. `scripts/down.sh -y` (removes the old cluster and HAProxy container), then
   `scripts/up.sh`, then `bootstrap/install.sh`, then `scripts/trust-ca.sh`.

## Verification

- `helm template` of `components/platform-gateway`: both Gateways render the
  new listener ports, `service-type: LoadBalancer`, no `nodePort` anywhere.
- `shellcheck` on every changed script.
- Isolation: with `~/.config/containers/registries.conf` deliberately
  unparseable (temporarily, restored afterwards), `scripts/up.sh` still creates
  the cluster.
- After bring-up: all Argo CD Applications Synced/Healthy; both gateway Services
  have an EXTERNAL-IP; `lb.sh status` shows two `kindccm-*` containers on
  8443/8080 and 9443/9080.
- `curl --cacert .lab-ca.crt` → 200 for `https://hello.apps.localhost:8443/hello`
  and `https://tools.internal.localhost:9443/hello`;
  `https://argocd.internal.localhost:9443` loads;
  `curl -I http://hello.apps.localhost:8080/hello` → 301 to `:8443`.

## Found during rollout

- Istio adds its health port **15021** to every gateway Service, so the two
  gateways collided on it even with unique listener ports: `internal` got it,
  `public` stayed `<pending>` (`AddressNotAssigned`) and wave −3 stalled.
  Fix: `hideStatusPort: true` makes the options ConfigMap patch the Service
  with `- port: 15021` / `$patch: delete` (Istio merges it as a strategic
  merge patch; verified on a scratch Gateway, pod probes unaffected).
  The spike missed this because it used plain Services.
- `lb.sh`'s readiness check used `grep -q` under `pipefail`, so it reported a
  timeout even though the controller connected in 1 s. Fixed.

