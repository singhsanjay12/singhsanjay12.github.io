---
title: "When DNS Load Balancing Is Good Enough — and When It Will Quietly Fail You"
description: "DNS round-robin works fine until your fleet becomes dynamic, your services multiply, or your datacenters need to coordinate. Here is where the line is, and what breaks when you cross it."
date: 2026-02-24 12:00:00 +0000
categories: [Distributed Systems, Load Balancing]
tags: [dns, load-balancing, service-discovery, distributed-systems, microservices, active-active]
image:
  path: /assets/img/posts/dns-lb/hero.svg
  alt: "DNS record pointing to multiple instances, some healthy, some dead, client unaware"
---

An autoscaling event fires. Three new instances come up, registered and ready. Six old instances are terminating. The DNS record is updated. Traffic should shift.

But the clients resolved that name four minutes ago. Their stub resolvers cached it. Their HTTP client libraries cached it. Their connection pools are holding long-lived TCP connections to the old addresses. For the next several minutes, requests keep landing on instances that are shutting down, even as healthy capacity sits idle.

This is not a bug in DNS. It is DNS working exactly as designed. The problem is that DNS was designed as a directory service, not a load balancer. It works as load balancing until the moment it doesn't, and when it stops working the failure is usually silent.

## What DNS Load Balancing Actually Does

The mechanism is simple: a single hostname resolves to multiple A records. The client receives the full list and picks one, usually the first. Resolvers and clients rotate through the list on each query, which produces a rough distribution across addresses.

```
$ dig api.example.com +short
10.0.1.4
10.0.1.7
10.0.1.12
10.0.1.3
```

No proxy, no sidecar, no infrastructure beyond your existing nameserver. Every language, every runtime, every tool that speaks TCP knows how to resolve a hostname. The operational cost is near zero.

At small scale and with stable fleets, this is genuinely good enough. The question is where "good enough" ends.

## When DNS Round-Robin Is Fine

DNS load balancing is a reasonable choice when these conditions hold.

**Your fleet is small and changes infrequently.** If you are running three to five backend instances that only change during planned deploys, TTL propagation lag is a manageable inconvenience rather than a continuous source of misdirected traffic.

**Connections are short-lived.** DNS distributes load at resolution time. If your clients open a new connection per request, and each connection resolves the hostname fresh, you get reasonable distribution. HTTP/1.1 without keep-alive, CLI tools, batch jobs, and short-lived scripts all behave this way.

**You do not need per-request routing decisions.** DNS commits a client to an address for the duration of the TTL. If the only thing you need is "some instance that can handle this", and any instance is equally good, DNS delivers that.

**Geographic routing at the edge.** GeoDNS, where a nameserver returns different records based on the client's region, is a legitimate and widely deployed pattern. CDNs, global API gateways, and regional entry points use it routinely. The key distinction: GeoDNS routes clients to a region, where a real load balancer takes over. DNS is doing coarse-grained steering, not per-request distribution.

If your service lives in any of these categories, DNS load balancing is probably fine. The rest of this post is about what happens when you move outside them.

## The Fleet Becomes Dynamic

Modern deployments are not static. Autoscaling adds instances when load spikes and removes them when it drops. Rolling deploys replace instances one by one. Spot or preemptible instances appear and disappear on short notice. A fleet of twenty instances might cycle through half its membership in an hour.

DNS was not built for this. Every change to the backend pool requires a DNS record update, and that update propagates through a chain of resolvers that each cache independently for the duration of the TTL.

```
Instance terminates at 10:00:00
DNS record updated at 10:00:05
Your VPC resolver TTL: 60 seconds
Application stub resolver TTL: 30 seconds
HTTP client internal cache: indefinite (until connection drop)

Client at 10:00:10: still resolving to terminated instance
Client at 10:01:00: stub resolver expired, re-resolves
Client at 10:01:30: VPC resolver expired, picks up new record
Client with keep-alive connection: still connected to old instance until TCP reset
```

The window here is not a corner case. It is the steady state of any dynamically scaled fleet. At any given moment, some fraction of your clients are routing to instances that have already been replaced. The larger the fleet and the faster it changes, the larger that fraction becomes.

![Three snapshots showing DNS record, stale resolver cache, and terminated instance during a rolling deploy](/assets/img/posts/dns-lb/fleet-churn-ttl.svg)

Low TTLs help but do not eliminate the problem. A TTL of 5 seconds limits propagation lag, but it also generates continuous query load against your nameservers, and as covered in [It's Always DNS](/2026/02/18/dns-the-silent-killer-of-distributed-systems.html), aggressive short-TTL strategies create their own failure modes when the nameserver itself is under stress.

## Connections Outlive the Resolution

Even if DNS propagates instantly, you have a second problem: TCP connections.

HTTP clients, database drivers, gRPC channels, and most connection pool implementations maintain long-lived connections to backend instances. They resolve the hostname once, establish a connection, and reuse that connection for subsequent requests. The connection stays alive until one side closes it or it times out.

This means DNS updates are invisible to any client holding an open connection. A client that connected to `10.0.1.4` twenty minutes ago will keep sending requests to `10.0.1.4` until the connection is closed, regardless of what DNS says. Changing the DNS record does nothing for that client until its connection pool expires and reconnects.

In systems with long-lived connections, the actual traffic distribution at any point in time is determined by which instances were healthy when each connection was established, not by the current DNS state. DNS round-robin governs new connections. It has no visibility into, or control over, existing ones.

![Client A stays pinned to a terminated instance via old connection while Client B routes correctly after fresh DNS resolution](/assets/img/posts/dns-lb/connection-reuse.svg)

## DNS Has No Health Signal

A record in DNS is an address. It carries no information about whether the instance at that address is healthy, overloaded, or gone.

When an instance fails, it keeps its DNS record until someone removes it. Traffic keeps arriving. The instance keeps failing requests. Nothing in the DNS layer reacts.

You can work around this with external monitors that remove unhealthy records, but now you have a separate health-checking system whose updates propagate through DNS TTLs before taking effect. You have rebuilt a slow, asynchronous version of the health-aware routing that a real load balancer gives you by default. The detection-to-removal-to-propagation chain adds seconds to minutes of continued traffic to failed instances.

How load balancers (server-side and client-side) solve this properly, with active and passive health checking that reacts in sub-second time, is covered in [The Instance Is Up. Or Is It?](/2026/01/12/health-checks-client-vs-server-side-lb.html).

## Many Microservices: The Lag Multiplies

In a monolith, a DNS propagation delay of 60 seconds for one service is annoying. In a system with dozens or hundreds of microservices calling each other, the same delay is happening simultaneously across every service boundary.

Consider a request that traverses five services in a chain. Each hop uses DNS-based service discovery. An instance in the second service is removed and its DNS record updated. Every service that calls into that second service continues routing to the dead instance for up to one TTL period. Meanwhile, services further down the chain may also be experiencing their own propagation events.

The more services, the more call edges, the more places where stale DNS state is silently misdirecting traffic. The aggregate misdirection in a large microservices system can be substantial even when each individual TTL is short.

This is why large microservices architectures do not use DNS as their primary service discovery mechanism for internal calls. They use a service registry with push-based or subscription-based updates: a client-side load balancer that knows immediately when an instance is removed, not after a TTL expires. LinkedIn's D2, Consul with client agents, and Kubernetes Endpoints (not DNS, but the raw API) all follow this model.

## Active-Active Datacenters

Running the same service across two or more datacenters simultaneously is a common pattern for resilience and latency. DNS can steer traffic between datacenters at a coarse level, but it is the wrong tool for the moment-to-moment coordination that active-active requires.

**Capacity-proportional routing** is the first problem. DNS round-robin distributes requests equally across all listed addresses. If Datacenter A has twenty instances and Datacenter B has five, both receive the same number of DNS-level requests. The result is that Datacenter B is overloaded while Datacenter A runs light. Fixing this requires weighting records, which most DNS implementations support, but weights are static. They do not track current capacity or queue depth.

**Draining one datacenter** is the second problem. When you need to take a datacenter offline for maintenance or redirect it during an incident, you update DNS to stop sending new clients to that datacenter. But existing clients that already resolved to Datacenter B keep sending traffic there until their TTLs expire and connections close. There is no mechanism in DNS to say "finish your current requests and then stop". You get a gradual, uncontrolled drain with no visibility into progress.

**Cross-datacenter failover** is the third. If Datacenter A degrades, you want traffic to move to Datacenter B. The TTL timer starts when you make the DNS change. During propagation, traffic is split between a degraded datacenter and a healthy one in proportions you cannot control.

```
10:00  Datacenter A degrades. DNS updated to remove DC-A records.
10:00  Clients with fresh resolutions: hit DC-B. Good.
10:00  Clients with cached resolutions: still hitting DC-A. Still degrading.
10:03  Some resolvers expire. Partial shift to DC-B.
10:08  Most resolvers have shifted. DC-A still receiving ~15% of traffic.
10:15  Long-TTL resolvers finally expire. DC-A traffic finally drops.
```

![Traffic distribution between DC-A and DC-B during DNS-based failover showing the 20-minute uncontrolled drain window](/assets/img/posts/dns-lb/active-active-drain.svg)

Real active-active systems use a load balancer with a health-aware control plane at each entry point and a mechanism for propagating capacity signals between datacenters. DNS can be involved at the outermost layer for initial region selection, but the within-region and cross-datacenter routing happens in something that can react in milliseconds, not minutes.

## No Weights, No Circuit Breaking, No Canaries

DNS round-robin distributes traffic equally across all records, with limited ability to do anything else. Modern traffic management requires more.

**Weighted routing** lets you send 5% of traffic to a new version during a canary deployment and gradually increase it as confidence grows. DNS supports weighted records in some implementations, but changes require a record update and propagate with TTL lag. You cannot react to real-time error rates by adjusting DNS weights.

**Circuit breaking** removes a backend from rotation when it is returning errors above a threshold, and restores it when recovery is confirmed. This requires per-request outcome tracking and sub-second response. DNS has no mechanism for this.

**Retries and hedging** require the routing layer to know that a request failed and direct the retry to a different instance. DNS makes its decision before the connection is established and has no visibility into whether the request succeeded.

These capabilities are not optional features in a large system. They are the mechanisms by which a fleet of imperfect instances behaves as a reliable service. They require a routing layer that has per-request observability. DNS has per-resolution observability at best.

## What to Use Instead

The replacement depends on the scale and the failure modes you are optimizing for.

For services with external clients, a server-side load balancer (HAProxy, NGINX, AWS ALB, GCP Load Balancer) gives you health-aware routing, circuit breaking, weighted traffic, and graceful draining. Clients still use DNS to find the load balancer, but the load balancer handles all the routing intelligence from there.

For internal service-to-service calls at scale, a service mesh with a control plane (Envoy with xDS, Istio, Linkerd) or a client-side load balancer backed by a service registry gives you sub-second health propagation, per-request routing decisions, and the ability to drain and shift traffic without waiting for TTLs.

DNS does not disappear in either model. It is how clients find the load balancer, how the control plane endpoint is bootstrapped, and how external names are resolved. Its role is to point clients at a system that handles real-time routing — not to be that system itself.

## Where the Line Is

DNS load balancing works when the fleet is stable, connections are short-lived, any backend is interchangeable, and failures are acceptable to handle slowly. Small services, internal tools, batch jobs, and edge geographic routing all fit comfortably in this space.

It breaks down when the fleet is dynamic, connections are long-lived, health matters, services are numerous, or datacenters need to coordinate. In those cases, DNS is not failing — it is doing exactly what it was designed to do. The problem is asking it to do something it was never designed for.

The engineers who design this correctly are not the ones who tune their TTLs most aggressively. They are the ones who know which layer should own each routing decision, and put the intelligence there from the start.
