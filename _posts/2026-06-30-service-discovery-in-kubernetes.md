---
title: "How Service Discovery Actually Works in Kubernetes: CoreDNS, Pod Networking, and Registries"
description: "Inside a cluster, 'where is service B' is answered by a layered system: a Service object, a DNS name served by CoreDNS, a control loop tracking healthy pods, and kube-proxy turning a virtual IP into a real one. Here is how each piece fits, with examples, and how it extends to external service registries."
date: 2026-06-30 12:30:00 +0000
categories: [Distributed Systems, Kubernetes]
tags: [kubernetes, service-discovery, coredns, dns, kube-proxy, endpointslice, service-mesh, networking]
image:
  path: /assets/img/posts/k8s-service-discovery/hero.svg
  alt: "A client pod resolving a Service name through CoreDNS to a ClusterIP, which kube-proxy load-balances across the healthy backend pods listed in an EndpointSlice"
---

Inside a Kubernetes cluster, every request starts with the same question I keep coming back to: **where is the service I need to call, right now?** Kubernetes answers it with a layered system that most people use without ever looking inside. A `Service` object gives you a name. CoreDNS turns that name into an address. A control loop keeps the list of real backends behind it accurate. And kube-proxy quietly rewrites that address into an actual pod. Understanding how those layers fit together is the difference between trusting the magic and debugging it at 3am.

This post is the Kubernetes-specific companion to my earlier writing on [DNS as a discovery mechanism](/2026/02/18/dns-the-silent-killer-of-distributed-systems.html) and [where DNS load balancing stops being enough](/2026/02/24/when-dns-load-balancing-is-not-enough.html). The cluster reuses DNS, but wraps it around something DNS alone could never do.

## The Objects That Make It Work

Three Kubernetes objects, plus one DNS server, carry the whole thing.

A **Service** is a stable identity. It has a name, a namespace, and (for the common type) a `ClusterIP`: a virtual IP that never changes for the life of the Service, even as the pods behind it are created and destroyed. The Service also has a label selector that defines which pods belong to it.

An **EndpointSlice** is the live answer. The Kubernetes control plane continuously watches which pods match a Service's selector and are ready to serve, and writes their IPs and ports into EndpointSlice objects. This is the part that makes the system a real service registry rather than a static config file: when a pod dies or fails its readiness probe, it is removed from the slice in near real time.

**CoreDNS** is the cluster's DNS server. It watches the Kubernetes API and answers DNS queries for Service names, returning the ClusterIP (or, for headless Services, the pod IPs directly).

**kube-proxy** is the data-plane glue. It also watches EndpointSlices and programs the node's kernel so that traffic sent to a ClusterIP is transparently load-balanced to one of the real pod IPs.

The pattern is worth naming: **a name resolves to a stable virtual IP, and a control loop keeps the real endpoints behind that IP true.** DNS does not have to be fast or fresh here, because the freshness lives in the EndpointSlice and kube-proxy, not in the DNS record.

## A Name and a Stable IP: ClusterIP + DNS

You create a Service, and Kubernetes assigns it a ClusterIP and a DNS name automatically.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">payments-service.yaml</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">apiVersion: v1
kind: Service
metadata:
  name: payments
  namespace: shop
spec:
  selector:
    app: payments        <span style="color:#64748b;"># which pods belong to this Service</span>
  ports:
    - port: <span style="color:#f0abfc;">8080</span>          <span style="color:#64748b;"># the Service port</span>
      targetPort: <span style="color:#f0abfc;">8443</span>    <span style="color:#64748b;"># the container port behind it</span>

<span style="color:#64748b;"># Kubernetes now serves a stable name and VIP:</span>
<span style="color:#64748b;">#   payments.shop.svc.cluster.local  -&gt;  10.96.0.21</span></code></pre>
</div>

The DNS name follows a fixed scheme: `service.namespace.svc.cluster.local`. From inside a pod, you rarely type the whole thing, because the pod's resolver is configured with search domains that let short names work.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">resolve from inside a pod</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">$ kubectl exec -it client -n shop -- sh

<span style="color:#64748b;"># short name resolves via the pod's search domains</span>
/ # nslookup payments
Name:    payments.shop.svc.cluster.local
Address: <span style="color:#a3e635;">10.96.0.21</span>

<span style="color:#64748b;"># an SRV record carries port + target, like classic DNS discovery</span>
/ # dig +short SRV _http._tcp.payments.shop.svc.cluster.local
<span style="color:#a3e635;">0 100 8080 payments.shop.svc.cluster.local.</span></code></pre>
</div>

That short-name resolution is driven by the pod's `/etc/resolv.conf`, which the kubelet writes:

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">/etc/resolv.conf inside the pod</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">nameserver 10.96.0.10                 <span style="color:#64748b;"># the CoreDNS ClusterIP</span>
search shop.svc.cluster.local svc.cluster.local cluster.local
options ndots:<span style="color:#f0abfc;">5</span></code></pre>
</div>

The `ndots:5` option is a common source of confusion and latency. It means any name with fewer than five dots is first tried against each search domain before being treated as absolute. Looking up `payments` generates several queries (`payments.shop.svc.cluster.local`, then the shorter suffixes) until one resolves. It is convenient, but a chatty external hostname can multiply DNS traffic, which is why you sometimes see fully qualified names with a trailing dot to short-circuit the search.

## CoreDNS: the Cluster's DNS Server

CoreDNS is a plugin-chained DNS server, and in a cluster its most important plugin is `kubernetes`, which watches the API for Services and EndpointSlices and answers queries directly from that live view. It is configured by a Corefile.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">CoreDNS Corefile</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">.:53 {
    errors
    health
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
        pods insecure
        fallthrough in-addr.arpa ip6.arpa
    }
    forward . /etc/resolv.conf     <span style="color:#64748b;"># non-cluster names go upstream</span>
    cache <span style="color:#f0abfc;">30</span>                       <span style="color:#64748b;"># cache answers for 30s</span>
}</code></pre>
</div>

This is the key insight about cluster DNS: CoreDNS is **DNS sitting on top of a live registry**. The query interface is ordinary DNS, with all its universality, but the answers come from the Kubernetes control plane's real-time view rather than a hand-maintained zone file. When a Service's pods change, CoreDNS reflects it on the next query (subject to its small cache). You get DNS's zero-integration client story without DNS's usual staleness problem, because the source of truth is the EndpointSlice, not a TTL.

CoreDNS is also where the failure modes I described in [It's Always DNS](/2026/02/18/dns-the-silent-killer-of-distributed-systems.html) show up in cluster form: a CoreDNS outage takes discovery down cluster-wide, `ndots` amplification can flood it, and its cache plugin trades a little freshness for a lot of load relief.

## Pod Network vs Host Network

To understand what a DNS answer actually points at, you need the cluster's IP model. Under the default **pod network**, the CNI plugin gives every pod its own routable IP, independent of the node it runs on. A Service's ClusterIP is a separate virtual IP, and the EndpointSlice holds the individual pod IPs. Resolving a normal Service gives you the ClusterIP; the pod IPs stay hidden behind it.

Sometimes you want the pod IPs directly, with no virtual IP in front. That is a **headless Service**, declared with `clusterIP: None`.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">headless service + lookup</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">apiVersion: v1
kind: Service
metadata: { name: cassandra, namespace: data }
spec:
  clusterIP: None        <span style="color:#64748b;"># headless: no VIP, no kube-proxy</span>
  selector: { app: cassandra }
  ports:
    - port: <span style="color:#f0abfc;">9042</span>

<span style="color:#64748b;"># DNS now returns one A record per ready pod; the client chooses</span>
/ # dig +short cassandra.data.svc.cluster.local
<span style="color:#a3e635;">10.1.7.4</span>
<span style="color:#a3e635;">10.1.7.9</span>
<span style="color:#a3e635;">10.1.8.2</span></code></pre>
</div>

Headless Services are how stateful systems (databases, brokers) and client-side load balancers get the full membership list and address each pod individually, rather than being funneled through a single VIP. It is the cluster's version of the DNS-returns-many-instances model, with the crucial improvement that the list is health-filtered by readiness.

Then there is **host network**. A pod with `hostNetwork: true` shares the node's network namespace: its IP is the node's IP, and its ports are the node's ports. This is common for node-level agents (log shippers, CNI daemons, monitoring). The discovery gotcha is DNS. By default a host-network pod would inherit the node's `/etc/resolv.conf` and never see CoreDNS, so cluster names fail to resolve. The fix is an explicit DNS policy.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">host-network pod</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">apiVersion: v1
kind: Pod
metadata: { name: node-agent }
spec:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet   <span style="color:#64748b;"># keep using CoreDNS</span>
  containers:
    - name: agent
      image: node-agent:1.0

<span style="color:#64748b;"># Without ClusterFirstWithHostNet the pod uses the node's resolver</span>
<span style="color:#64748b;"># and cannot resolve *.svc.cluster.local at all.</span></code></pre>
</div>

## kube-proxy: From a Virtual IP to a Real Pod

Resolving a normal Service gives you a ClusterIP, but nothing actually listens on that IP. It is a fiction maintained by **kube-proxy**, which watches EndpointSlices and programs the node's kernel (iptables rules, or IPVS for larger clusters) so that a connection to `10.96.0.21:8080` is rewritten to one of the ready pod IPs and balanced across them.

Two consequences matter for discovery. First, **readiness gates membership**: a pod only enters the EndpointSlice once its readiness probe passes, and is pulled the moment it fails. This is the cluster doing the health-aware routing I argued for in [client-side vs server-side health checking](/2026/01/12/health-checks-client-vs-server-side-lb.html), except the control plane and kube-proxy do it for you. Second, **DNS staleness mostly does not matter** here. The ClusterIP a client caches is stable for the Service's whole life, so a long DNS TTL is harmless; all the churn happens behind the VIP in the EndpointSlice, which kube-proxy tracks continuously. This is precisely the property that plain DNS round-robin lacked in [when DNS load balancing is not enough](/2026/02/24/when-dns-load-balancing-is-not-enough.html).

## Working With Service Registries

Here is the reframing that ties it back to the broader topic: **Kubernetes already contains a service registry.** The EndpointSlice API is a live, health-filtered, watchable registry of endpoints. CoreDNS is just one consumer of it. That is why the cluster does not need an external registry for in-cluster discovery the way a VM fleet often does.

But the registry model extends past the cluster edge in a few ways.

**Reaching external services through cluster DNS.** An `ExternalName` Service maps a cluster name to an external hostname, so in-cluster clients discover a non-Kubernetes dependency through the same DNS they already use.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">external service via DNS</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">apiVersion: v1
kind: Service
metadata: { name: legacy-billing, namespace: shop }
spec:
  type: ExternalName
  externalName: billing.corp.internal   <span style="color:#64748b;"># CoreDNS returns a CNAME here</span></code></pre>
</div>

**External registries like Consul.** Tools such as Consul can sync in both directions: registering Kubernetes Services into the Consul catalog so VM-based clients can find them, and surfacing external Consul services inside the cluster as synthetic Services. This is the bridge when Kubernetes is one island in a larger, mixed estate that already standardized on a registry.

**Service meshes via xDS.** A mesh like Istio reads EndpointSlices directly and pushes them to each Envoy sidecar over the xDS protocol. At that point DNS is barely involved in routing: the sidecar holds a near-real-time, weighted, health-aware view of every endpoint and load-balances locally. This is the same control-plane-driven discovery model I covered in the [proxy concurrency post](/2026/03/09/concurrent-requests-reverse-proxy.html), applied to east-west cluster traffic.

**Multi-cluster.** Once you have more than one cluster, the built-in DNS scope (`cluster.local`) stops being enough, and you reach for multi-cluster Services or a mesh that federates registries across clusters. That is exactly the boundary where in-cluster discovery hands off to the cross-datacenter coordination problem.

## What to Reach For, and When

The honest summary is short. For discovery *inside* a single cluster, you almost never need anything beyond what ships in the box: Services, EndpointSlices, CoreDNS, and kube-proxy already give you health-aware, push-updated discovery behind a stable name. Use a headless Service when a client needs the raw membership list, and remember the `dnsPolicy` when you go host-network.

You reach past the built-ins for the cases that cross the cluster boundary: integrating a non-Kubernetes estate (an external registry like Consul), needing client-side load balancing with rich endpoint metadata (a mesh and xDS), or spanning multiple clusters (multi-cluster Services or a federated mesh). In every one of those, the underlying pattern is the same one the cluster taught you: a stable name in front, a live registry of healthy endpoints behind, and a control loop keeping the two honest.

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">Kubernetes did not replace DNS for service discovery. It put DNS back where it belongs: a friendly name on the front of a live, health-aware registry that someone else keeps accurate for you.</p>

---

*This builds on my earlier pieces on [It's Always DNS](/2026/02/18/dns-the-silent-killer-of-distributed-systems.html), [when DNS load balancing is not enough](/2026/02/24/when-dns-load-balancing-is-not-enough.html), and [health checking in client vs server-side load balancing](/2026/01/12/health-checks-client-vs-server-side-lb.html).*

*Running discovery across clusters or bridging Kubernetes with an external registry? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
