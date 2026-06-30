---
title: "Multi-Cluster Service Discovery: When cluster.local Runs Out"
description: "A single cluster answers 'where is service B' with CoreDNS and EndpointSlices, but that whole machinery stops at cluster.local. Here is what changes when discovery has to span clusters: the MCS API, mesh federation, registry bridges, GSLB, and the shared-identity problem underneath all of them."
date: 2026-05-18 12:00:00 +0000
categories: [Distributed Systems, Kubernetes]
tags: [kubernetes, multi-cluster, service-discovery, service-mesh, networking, distributed-systems]
image:
  path: /assets/img/posts/multi-cluster-discovery/hero.svg
  alt: "Two Kubernetes clusters in different regions exporting and importing services to each other, with a federation and GSLB layer above them and a health-filtered endpoint sync between their EndpointSlices"
---

Inside one Kubernetes cluster, discovery is a solved problem. A `Service` gives you a name, CoreDNS resolves it, an EndpointSlice keeps the real backends accurate, and kube-proxy turns a virtual IP into a real pod. I walked through that whole machinery in [how service discovery actually works in Kubernetes](/2026/06/30/service-discovery-in-kubernetes.html). It works so well that you stop thinking about it.

Then you stand up a second cluster, and the magic quietly stops at the edge. A client in cluster A asks for `payments.shop.svc.cluster.local` and gets nothing, because the name `cluster.local` means *this* cluster, and the EndpointSlices that back it never leave home. The hidden assumption baked into every in-cluster name is that there is exactly one cluster. The moment that assumption breaks, you are back to the cross-datacenter coordination problem that Kubernetes had been hiding from you.

## Why You End Up With More Than One Cluster

Nobody adds a second cluster for fun. The reasons are the same forces that shape any distributed system.

**High availability.** A cluster is a blast radius. A bad control-plane upgrade, a corrupted etcd, a network partition that isolates a region: all of these take down everything in one cluster at once. A second cluster in a second failure domain means a regional outage degrades rather than destroys.

**Locality.** Users in Frankfurt should not have their requests hairpin through Virginia. Putting a cluster near each population keeps the common path short, and that latency budget is exactly what client-side and DNS-based balancing fight over in [when DNS load balancing is not enough](/2026/02/24/when-dns-load-balancing-is-not-enough.html).

**Blast-radius isolation.** Even within one region, teams split workloads across clusters so that a noisy neighbor or a runaway rollout in one cluster cannot starve another.

**Migration.** Cluster upgrades, CNI swaps, and cloud-region moves are all easier when you can stand up the new cluster, shift traffic gradually, and tear down the old one. That only works if a service in the new cluster is discoverable from the old one during the overlap.

Every one of these needs the same thing: a client in one cluster has to find a healthy endpoint that may live in another cluster. There is no single right way to provide that. There are four common ones, and they differ mostly in where the source of truth lives.

## Approach 1: The Multi-Cluster Services API

The Kubernetes-native answer is the **Multi-Cluster Services (MCS) API**, which adds two objects on top of the model you already know: `ServiceExport` and `ServiceImport`.

You create a `ServiceExport` in the cluster that owns a service. An MCS controller (GKE Multi-Cluster Services, Cilium ClusterMesh, Admiralty, and others implement it) watches for that object and propagates the service's endpoints to every other cluster in the clusterset.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">export a service to the clusterset</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># In cluster A, where the payments pods actually run:</span>
apiVersion: multicluster.x-k8s.io/v1alpha1
kind: ServiceExport
metadata:
  name: payments        <span style="color:#64748b;"># same name as the local Service</span>
  namespace: shop

<span style="color:#64748b;"># A ServiceImport now appears automatically in every other cluster,</span>
<span style="color:#64748b;"># resolvable at a clusterset-scoped DNS name:</span>
<span style="color:#64748b;">#   payments.shop.svc.clusterset.local</span></code></pre>
</div>

The key design choice is the new DNS zone: `clusterset.local` instead of `cluster.local`. A client that wants any healthy `payments` endpoint anywhere in the clusterset resolves the clusterset name, and the importing cluster's CoreDNS hands back a local `ServiceImport` IP. Behind that IP sits an EndpointSlice populated with endpoints synced from the exporting clusters, so the same readiness-gated, health-filtered membership you get in one cluster now spans several.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">resolve a clusterset name</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># From a pod in cluster B, calling a service homed in cluster A:</span>
/ # nslookup payments.shop.svc.clusterset.local
Address: <span style="color:#a3e635;">10.74.0.31</span>     <span style="color:#64748b;"># a local ServiceImport VIP in cluster B</span>

<span style="color:#64748b;"># the EndpointSlice behind it carries cluster-A pod IPs,</span>
<span style="color:#64748b;"># synced and health-filtered by the MCS controller</span></code></pre>
</div>

The strength of MCS is that it stays inside the Kubernetes object model, so it composes with everything you already run. The cost is that you need a controller and flat cross-cluster pod connectivity (or a tunnel) for the synced endpoint IPs to actually be reachable.

## Approach 2: Mesh Federation

If you already run a service mesh, federation is often the cleaner path, because the mesh control plane is already a registry that pushes endpoints to sidecars over xDS. Extending it across clusters is a matter of letting one control plane see another cluster's endpoints.

Istio's **multi-primary** topology does exactly this: each cluster runs its own istiod, and each istiod is given read access to the other clusters' API servers (via a remote secret) so it can watch their services and EndpointSlices.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">istio multi-primary · grant cross-cluster read</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># Give cluster A's istiod read access to cluster B's API,</span>
<span style="color:#64748b;"># so it can watch B's services and push them to A's sidecars:</span>
$ istioctl create-remote-secret \
    --context=clusterB --name=clusterB \
    | kubectl apply --context=clusterA -f -

<span style="color:#64748b;"># Now a sidecar in A sees both local and remote endpoints for</span>
<span style="color:#64748b;"># a service of the same name+namespace, merged into one cluster.</span></code></pre>
</div>

Once both control planes see both clusters, a service that exists with the same name and namespace in each is treated as one logical service. A sidecar's Envoy holds a merged, weighted, health-aware endpoint set spanning clusters, and load-balances locally. DNS is barely in the routing path at all, which is the same xDS-driven model I described for east-west traffic in the [proxy concurrency post](/2026/03/09/concurrent-requests-reverse-proxy.html), now stretched across cluster boundaries. The mesh also gives you the cross-cluster mTLS you will need, which I come back to at the end.

## Approach 3: An External Registry Bridge

When Kubernetes is one island in a larger estate that already standardized on a registry, the bridge model fits better than anything Kubernetes-native. This is the cross-cluster version of the DNS-or-registry tradeoff I worked through in [DNS or a Service Registry?](/2026/06/23/dns-vs-service-registry.html).

Consul is the common example. A Consul agent in each cluster syncs Kubernetes Services into a shared catalog, and surfaces catalog entries back into each cluster as synthetic Services. The registry, not any one cluster's API server, becomes the source of truth that spans clusters and VMs alike.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">consul catalog sync across clusters</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">syncCatalog:
  enabled: true
  toConsul: true     <span style="color:#64748b;"># register this cluster's Services in Consul</span>
  toK8S: true        <span style="color:#64748b;"># mirror Consul services back as K8s Services</span>

<span style="color:#64748b;"># A client resolves a Consul-backed name and reaches an endpoint</span>
<span style="color:#64748b;"># that may live in another cluster, a VM, or a different cloud:</span>
<span style="color:#64748b;">#   payments.service.consul</span></code></pre>
</div>

The bridge is the most flexible option because it does not assume everything is Kubernetes, but it is also the one where staleness bites hardest, because you now have two registries (each cluster's EndpointSlices and the Consul catalog) that have to agree.

## Approach 4: Global DNS and GSLB in Front

The other three approaches make a remote endpoint look local. The GSLB approach does the opposite: it puts a global name in front of per-cluster ingress and steers whole clients to a cluster.

A global load balancer (a managed offering, or a coredns/external-dns setup wired to a GeoDNS provider) answers one hostname with the address of the nearest healthy cluster's ingress. This is coarse: it routes at the cluster granularity, not the pod, and it inherits every DNS caching and TTL pitfall I catalogued in [it's always DNS](/2026/02/18/dns-the-silent-killer-of-distributed-systems.html). But it is also the simplest thing that works for north-south traffic, and it does not require flat pod networking between clusters. In practice GSLB and one of the first three approaches coexist: GSLB picks the cluster for external clients, and MCS or a mesh handles service-to-service calls once traffic is inside.

## The Part That Actually Hurts: Sync, Staleness, and Identity

The four approaches differ on the surface, but they share the two hard problems, and the hard problems are not about wiring.

**Endpoint synchronization and staleness.** In one cluster, kube-proxy and the EndpointSlice controller keep membership fresh in near real time, and DNS staleness mostly does not matter because the ClusterIP is stable. Across clusters, you have reintroduced a propagation delay: a pod fails its readiness probe in cluster A, and there is now a window before cluster B's imported view reflects it. During that window, cluster B happily sends requests to an endpoint that is already gone. Every multi-cluster system is a bet on how small you can make that window, and the same readiness signals from [client-side vs server-side health checking](/2026/01/12/health-checks-client-vs-server-side-lb.html) are what feed it. Locality-aware routing makes this manageable: prefer local endpoints, and only spill to a remote cluster when local capacity is unhealthy, so cross-cluster failover is the exception path rather than the hot path.

**Shared identity and trust.** This is the one that quietly sinks projects. Inside a cluster, every pod has an identity and the control plane vouches for it. Across clusters, you have two separate trust domains: cluster A's ServiceAccount tokens mean nothing to cluster B, and a workload calling across the boundary needs an identity both sides agree on. You cannot solve discovery across clusters without also solving authentication across clusters, or you have simply made it easier for the wrong caller to reach a sensitive service. A mesh handles this with a shared root of trust so that mTLS identities (SPIFFE-style) are portable between clusters, which is the cross-cluster extension of the workload-identity model I argued for in [zero trust with a reverse proxy](/2025/08/03/zero-trust-with-reverse-proxy.html) and the [control plane and sessions](/2025/10/20/zero-trust-control-plane-and-sessions.html). Discovery tells a client where a service is. Identity is what decides whether it is allowed to talk to it, and across clusters those two questions stop being separable.

## What to Reach For

The honest framing is that you should add cross-cluster discovery as late as you can, and when you do, choose by where your source of truth already lives. If you are all-in on Kubernetes with flat connectivity, the MCS API keeps you inside the object model. If you already run a mesh, federate it and get cross-cluster mTLS in the same move. If Kubernetes is one part of a mixed estate on a registry, bridge to that registry. And put GSLB in front for north-south locality regardless. In every case the pattern is the one the single cluster taught you: a stable name in front, a live registry of healthy endpoints behind, and a control loop keeping them honest. Multi-cluster just means that control loop now has to run across a boundary, and that the trust boundary it crosses is suddenly your problem too.

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">cluster.local was always a promise that there is exactly one cluster. Multi-cluster discovery is the work of breaking that promise carefully, because the name was the easy part and the shared identity behind it is the hard one.</p>

---

*This continues my writing on [how service discovery actually works in Kubernetes](/2026/06/30/service-discovery-in-kubernetes.html), [DNS or a Service Registry?](/2026/06/23/dns-vs-service-registry.html), and [when DNS load balancing is not enough](/2026/02/24/when-dns-load-balancing-is-not-enough.html).*

*Stitching discovery and identity across clusters? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
