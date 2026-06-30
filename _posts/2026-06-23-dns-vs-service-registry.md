---
title: "DNS or a Service Registry? How Services Should Find Each Other, and When Each One Breaks"
description: "Service discovery has two families of answers: plain DNS and a dedicated registry like Consul, etcd, or xDS. They look interchangeable on a diagram. They are not. Here is what each one actually guarantees, the options in each camp, and how to choose."
date: 2026-06-23 12:00:00 +0000
categories: [Distributed Systems, Service Discovery]
tags: [service-discovery, dns, consul, etcd, kubernetes, load-balancing, distributed-systems, registry]
image:
  path: /assets/img/posts/dns-vs-registry/hero.svg
  alt: "A client asking where service B is, with two answers: a cached DNS record that lags, and a registry that pushes live, health-aware endpoints"
---

Every distributed system eventually asks the same question on every request: **where is the service I need to call, right now?** That question is service discovery, and there are two broad families of answers. One is DNS, the naming system you already run. The other is a dedicated service registry: Consul, etcd, ZooKeeper, Eureka, Kubernetes endpoints, or an xDS control plane.

On an architecture diagram the two look interchangeable. A box labeled "discovery" sits between the caller and the callee either way. In production they behave very differently, and choosing the wrong one means your system is slow to notice failure, or carries operational weight it did not need. This post is about where the line is.

If you have read my earlier posts on [DNS as a silent killer](/2026/02/18/dns-the-silent-killer-of-distributed-systems.html) and [when DNS load balancing is not enough](/2026/02/24/when-dns-load-balancing-is-not-enough.html), this is the companion piece. Those posts were about DNS failing. This one is about deciding when to use it at all.

## What DNS Gives You for Free

DNS is the discovery mechanism you do not have to adopt, because it is already there. Every language, every runtime, every operating system can resolve a hostname without a library, a sidecar, or a client SDK. You write `payments.internal` in a config file and the platform underneath turns it into an address. That universality is the whole pitch, and it is a strong one.

DNS also caches aggressively at every layer (the stub resolver, the OS, the recursive resolver), which keeps lookup cost near zero on the hot path. And it carries more than addresses. An SRV record encodes host, port, priority, and weight, so DNS can express a basic preference and weighting scheme without any application awareness.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">SRV record + lookup</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># zone file: priority weight port target</span>
_payments._tcp.internal. <span style="color:#f0abfc;">30</span> IN SRV <span style="color:#f0abfc;">10 60</span> <span style="color:#f0abfc;">8443</span> pay-a.internal.
_payments._tcp.internal. <span style="color:#f0abfc;">30</span> IN SRV <span style="color:#f0abfc;">10 40</span> <span style="color:#f0abfc;">8443</span> pay-b.internal.

<span style="color:#64748b;"># the client just asks; no SDK involved</span>
$ dig +short SRV _payments._tcp.internal
<span style="color:#a3e635;">10 60 8443 pay-a.internal.</span>
<span style="color:#a3e635;">10 40 8443 pay-b.internal.</span></code></pre>
</div>

For services that change slowly and tolerate a few seconds of staleness, that is genuinely all you need. Do not reach for more machinery than the problem has.

## Where DNS Runs Out

DNS is a pull-based, cache-everywhere system, and that design is exactly what limits it as a discovery layer for dynamic fleets.

The first limit is **propagation lag**. A client does not learn about a change until its cached record expires and it asks again. The TTL is a floor on how stale your view can be, and it is routinely ignored: resolvers and language runtimes have historically cached records past TTL, and some clients resolve a hostname once at startup and never again. When an instance dies, callers keep dialing the corpse until the cache turns over.

The second limit is that **DNS has no health signal**. A record answers "what is the address" and nothing else. It does not know whether the instance behind that address is serving traffic, returning 500s, or a zombie that passes its own liveness check while failing real requests. I went deep on exactly this failure in the [health-checking post](/2026/01/12/health-checks-client-vs-server-side-lb.html): the address resolving does not mean the thing answering is healthy.

The third limit is **no metadata and no push**. DNS cannot tell a client a backend's current load, its zone, its version, or its connection count, so it cannot support load-aware client-side balancing. And it cannot proactively tell a client that the topology changed. The client has to come back and ask. For a fleet that autoscales every few minutes, a TTL-bound pull loop is structurally behind the truth. This is the wall I described in [when DNS load balancing is not enough](/2026/02/24/when-dns-load-balancing-is-not-enough.html): the moment the fleet becomes dynamic, DNS stops being a discovery system and becomes a stale cache.

## What a Service Registry Adds

A registry is a database of "who is serving what, and is it healthy," that clients can **watch** rather than poll. That single difference, push instead of pull, is the reason registries exist.

When an instance registers, it appears in the registry with metadata: address, port, zone, version, weight, and arbitrary tags. The registry integrates with health checking, so an instance that fails its checks is withdrawn from the answer set in seconds, not at the next TTL boundary. Clients (or a sidecar, or a control plane) hold an open watch and receive the updated set the moment it changes. No staleness window bounded by a TTL, because there is no TTL.

That richer answer is what makes real client-side load balancing possible. A client that can see every healthy endpoint, its weight, and its zone can run least-connections or zone-aware routing locally, with no round trip to a load balancer. The registry is the data plane that DNS could never be. The cost is equally real: every client now needs to speak the registry's protocol, through a library or a sidecar, and you have one more stateful, consistency-sensitive system to operate and keep available. When the registry is down or partitioned, discovery is at risk, so registries live or die on their availability story.

## The Options, Concretely

The two families are not a binary so much as a spectrum from "zero integration, low freshness" to "deep integration, high freshness."

**Plain DNS, made dynamic ([CoreDNS](https://coredns.io/), Route 53, etc.).** The lowest-integration option. Modern DNS servers can be backed by a live source and serve short TTLs, which narrows the staleness window without changing any client. You still inherit DNS's pull model and lack of health semantics, but for slow-moving services it is the cheapest thing that works.

**[Consul](https://www.consul.io/).** A full service registry with health checks, KV storage, multi-datacenter support, and rich metadata. Its defining feature for migrations is that it exposes both a registry API *and* a DNS interface, so legacy clients can resolve names while new clients watch the API. That dual personality makes it a common bridge between the two worlds.

**[etcd](https://etcd.io/) and [ZooKeeper](https://zookeeper.apache.org/).** Strongly consistent coordination stores. They are excellent as the source of truth and the primitive others build on (etcd backs Kubernetes itself), but they are general-purpose consensus stores, not turnkey discovery systems. You get consistency and watches; you build the health and service semantics on top.

**[Eureka](https://github.com/Netflix/eureka).** An AP-leaning registry from the Netflix stack, deliberately tuned to favor availability over consistency during partitions. It pairs naturally with client-side libraries that pull the registry and balance locally, which is the model a lot of JVM microservice fleets grew up on.

**Kubernetes (CoreDNS + [EndpointSlices](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/)).** Kubernetes runs both families at once. A Service gives you a stable DNS name and a virtual IP, while the EndpointSlice API is a live, health-filtered registry that the kube-proxy and any controller can watch. Most apps use the DNS name and never notice the registry underneath; service meshes use the registry directly.

**xDS control planes ([Envoy](https://www.envoyproxy.io/), service mesh).** The far end of the spectrum. The control plane streams endpoints, health, weights, and routing rules to the proxy via xDS, and the proxy load-balances with a near-real-time view of the fleet. This is the discovery model I described in the [proxy concurrency post](/2026/03/09/concurrent-requests-reverse-proxy.html): configuration and endpoints pushed to each worker, no static files, no TTL.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">a registry that also speaks DNS · Consul</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># register a service with a health check (the registry knows if it is alive)</span>
$ consul services register \
    -name=payments -port=<span style="color:#f0abfc;">8443</span> \
    -check-http=<span style="color:#a3e635;">https://localhost:8443/healthz</span> -check-interval=<span style="color:#a3e635;">5s</span>

<span style="color:#64748b;"># new clients watch the API; legacy clients resolve the SAME data over DNS</span>
$ dig +short SRV payments.service.consul
<span style="color:#a3e635;">1 1 8443 pay-a.node.dc1.consul.</span>   <span style="color:#64748b;"># only healthy instances are returned</span></code></pre>
</div>

## The Hybrid Reality

In practice almost nobody runs a pure version of either. The mature pattern is a registry as the source of truth, with a DNS interface in front of it for the clients that cannot or should not integrate. Consul's DNS endpoint and Kubernetes' Service-over-EndpointSlices are both exactly this: a live, health-aware registry underneath, a familiar DNS name on top. Legacy and polyglot clients get a hostname; meshes and smart clients watch the registry directly and get the freshness.

The useful way to think about it is by granularity. DNS is a fine answer for coarse, slow-moving routing: which datacenter, which stable virtual IP, which external dependency. A registry earns its keep for fine-grained, fast-moving routing: which of these forty autoscaled pods, weighted by current load, in my zone, that passed a health check two seconds ago. You can absolutely use DNS to find the front door and a registry to pick the exact instance behind it.

## How to Actually Choose

Strip it down to a few questions, in priority order.

**How fast does the fleet change?** If instances live for weeks, DNS with a sane TTL is fine. If they autoscale every few minutes, the TTL-bound staleness window is a liability and you want a registry's push model.

**Do you need health to drive discovery?** If callers must stop hitting an unhealthy instance within seconds, DNS cannot give you that on its own. A registry with integrated health checks can.

**How polyglot and how integrated are your clients?** DNS works everywhere with zero client code. A registry needs every client to speak its protocol, directly or through a sidecar. If you cannot put a library or a sidecar next to every caller, DNS (or a registry behind a DNS interface) is the pragmatic choice.

**What is your operational maturity?** A registry is another distributed, stateful, availability-critical system. If discovery depends on it, its uptime is your uptime. Adopt one when the freshness and health benefits clearly outweigh the cost of running it well, not before.

The trap is treating this as a status decision, reaching for a registry because it is the sophisticated answer. It is not more sophisticated. It is a different set of tradeoffs. DNS trades freshness for universality and simplicity. A registry trades simplicity for freshness and health awareness. Pick the one whose weakness you can live with for the traffic in front of you.

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">DNS tells you where a service was a TTL ago. A registry tells you where it is now. The whole decision is how much that difference costs you when something fails.</p>

---

*This continues the discovery thread from [It's Always DNS](/2026/02/18/dns-the-silent-killer-of-distributed-systems.html) and [When DNS Load Balancing Is Not Enough](/2026/02/24/when-dns-load-balancing-is-not-enough.html).*

*Choosing a discovery layer for your own fleet? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
