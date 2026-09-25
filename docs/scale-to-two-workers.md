# Scaling to two workers

The lab runs one control-plane and one worker. This is what changes if you add
a second worker, and what it actually buys you.

## What it buys

Today every workload lands on the single worker, because kind taints the
control-plane as soon as a worker exists. Both `public` gateway replicas sit on
that one node. The PodDisruptionBudget (`minAvailable: 1`) is satisfiable, so
Kubernetes considers the gateway highly available — but it is not: one node
reboot takes both replicas with it.

A second worker makes that HA real, and only then do anti-affinity and topology
spread constraints mean anything. Without it they are no-ops at best and
unschedulable pods at worst.

## Cost

Roughly +1 GiB of VM memory for the node's kubelet, kube-proxy, kindnet and
ztunnel, before any workload. On a 12 GiB machine that is comfortable; on 8 GiB
it is not.

## Step 1 — recreate the cluster

**kind cannot add a node to a running cluster.** There is no `kind add node`;
the node set is fixed at create time. This is a teardown.

That is cheaper than it sounds — the cluster holds no unique state. Everything
on it is reproducible from the GitOps repos, and the only thing you lose is
time (~10 minutes for a full resync).

Uncomment the second worker in [`../kind/cluster.yaml`](../kind/cluster.yaml):

```yaml
  - role: worker
    labels:
      k8s-lab.io/role: worker
```

Then:

```bash
scripts/down.sh
scripts/up.sh
cd ../k8s-lab-platform-infra && bootstrap/install.sh
cd ../k8s-lab-cluster && scripts/trust-ca.sh   # the CA is regenerated
```

## Step 2 — nothing to do for the load balancer

cloud-provider-kind adds every Ready node to each load balancer's backends on
its own, so the new worker starts taking gateway traffic as soon as it joins.
Check both gateways still have an address and their ports:

```bash
scripts/lb.sh status
```

## Step 3 — make the gateway actually spread

This is the part that is easy to forget, and without it the new worker changes
nothing for ingress: the scheduler is free to put both `public` replicas back
on the same node.

The fix lives in **k8s-lab-platform-infra**, not here. The `platform-gateway`
chart passes a `deployment` key through the gateway's `parametersRef`
ConfigMap, which Istio merges into the Deployment it generates. Add a topology
spread constraint there:

```yaml
# components/platform-gateway/templates/gateways.yaml, under the deployment key
spec:
  template:
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              gateway.networking.k8s.io/gateway-name: public
```

`DoNotSchedule` is the right choice once two workers exist, and the reason this
change must not be made before then: with one schedulable node the second
replica would stay `Pending` forever. `ScheduleAnyway` would be safe on one
node but is a preference the scheduler may ignore, which is how you end up
believing you have HA when you do not.

Verify the spread landed:

```bash
kubectl -n infra-gw get pods -o wide -l gateway.networking.k8s.io/gateway-name=public
```

Two pods, two different nodes. Then drain one and confirm the targets still
answer:

```bash
kubectl drain k8s-lab-worker --ignore-daemonsets --delete-emptydir-data
curl --cacert .lab-ca.crt https://hello.apps.localhost:8443/hello
kubectl uncordon k8s-lab-worker
```

## Beyond two workers

The same three steps apply per node, and the `maxSkew: 1` constraint keeps
working unchanged. The control-plane stays a single node — kind supports
stacked HA control planes, but three etcd members on a laptop costs far more
memory than the failure mode is worth in a lab.
