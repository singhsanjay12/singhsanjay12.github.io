---
title: "The Instance Is Up. Or Is It? Health Checking in Client-Side vs Server-Side Load Balancing"
date: 2026-01-12 00:00:00 -0700
categories: [Distributed Systems, Load Balancing]
tags: [load-balancing, health-checks, service-discovery, distributed-systems, client-side-lb]
---

A service reports healthy. The load balancer believes it. A request lands on it and times out. Another follows. Then ten more. By the time the system reacts, hundreds of requests have drained into a broken instance while users stared at a spinner.

Health checking sounds simple: ask if something is alive, stop sending traffic if it isn't. In practice, the mechanism behind that check, and *who* performs it, determines how fast your system detects failure, how accurately it responds, and how much of that complexity leaks into your application code.

The answer is fundamentally different depending on where load balancing lives: in a central proxy, or in the client itself.

## Two Models for Distributing Traffic

Before getting into health checks, it helps to be precise about what each model looks like.

### Server-Side Load Balancing

A dedicated proxy sits between clients and the backend fleet. Clients know one address: the load balancer. The load balancer knows the backend pool and decides where each request goes.

```
  Client A ──┐
             │
  Client B ──┼──► [ Load Balancer ] ──► Instance 1
             │           │
  Client C ──┘           ├──────────► Instance 2
                         │
                         └──────────► Instance 3
```

The load balancer is the single point of intelligence. It tracks backend health, maintains connection pools, and routes traffic. Clients are completely unaware of the backend topology; they see one stable address regardless of how many instances are behind it, or how many fail.

HAProxy, NGINX, AWS ALB, and most hardware appliances follow this model.

### Client-Side Load Balancing

The routing intelligence moves into the client. Each client holds a local view of the available backend instances, typically populated from a service registry, and makes its own routing decision on every request.

```
  ┌─────────────────────────────────────┐
  │ Client A                            │
  │  [instance list: 1, 2, 3]  ──────► Instance 1
  └─────────────────────────────────────┘

  ┌─────────────────────────────────────┐
  │ Client B                            │
  │  [instance list: 1, 2, 3]  ──────► Instance 2
  └─────────────────────────────────────┘

  ┌─────────────────────────────────────┐
  │ Client C                            │
  │  [instance list: 1, 2, 3]  ──────► Instance 3
  └─────────────────────────────────────┘

             ↕ all clients watch
        [ Service Registry ]
         (Zookeeper, Consul,
          etcd, custom...)
```

There is no proxy in the request path. A service registry keeps the authoritative list of instances. Clients subscribe to updates and maintain their own routing table. gRPC's built-in load balancing, Netflix Ribbon, and LinkedIn's D2 all work this way.

## Health Checking: Who Asks, and How

The two models produce fundamentally different answers to the same question: *is this instance healthy?*

### Health Checking in Server-Side Load Balancing

The load balancer owns health checking entirely. It runs periodic probes against each backend, typically a TCP connect, an HTTP request to a `/health` endpoint, or a custom command, on a fixed schedule.

```
                        ┌──────────────────────────┐
                        │      Load Balancer        │
                        │                           │
                        │  Health Check Loop:       │
                        │  every 5s, per instance   │
                        │                           │
   GET /health ────────►│──────────────────────────►│ Instance 1  ✓ 200 OK
   GET /health ────────►│──────────────────────────►│ Instance 2  ✓ 200 OK
   GET /health ────────►│──────────────────────────►│ Instance 3  ✗ timeout
                        │                           │
                        │  Instance 3: 1 failure    │
                        │  (threshold: 3 failures)  │
                        │  → still in rotation      │
                        └──────────────────────────┘
```

A typical configuration might look like:

- **Interval:** probe every 5 seconds
- **Timeout:** wait up to 2 seconds for a response
- **Rise threshold:** 2 consecutive successes to mark healthy
- **Fall threshold:** 3 consecutive failures to mark unhealthy

These thresholds exist to avoid flapping: toggling an instance in and out of rotation on a single transient failure. The downside is latency. With a 5-second interval and a fall threshold of 3, a hard failure takes up to 15 seconds to detect. During that window, real traffic continues to hit the broken instance.

Once the load balancer marks an instance unhealthy, it removes it from the rotation immediately. No client needs to be updated; the change is in one place, takes effect instantly, and is consistent for all callers.

### Health Checking in Client-Side Load Balancing

With no central proxy, health checking is distributed. Each client must independently determine which instances in its local list are safe to use. There are two approaches, and most production systems use both.

**Active health checks:** the client (or a sidecar process) periodically probes each known instance, just like a server-side load balancer would. The difference is that every client runs its own probe loop. With 500 clients each checking 20 instances every 5 seconds, that is 2,000 probe requests per second hitting your fleet, just for health signals, before any real traffic.

```
  Client A                         Client B
  probe loop:                      probe loop:
  Instance 1 → healthy             Instance 1 → healthy
  Instance 2 → healthy             Instance 2 → healthy
  Instance 3 → timeout             Instance 3 → healthy  ← different result
```

Each client forms its own independent view. Two clients probing the same instance at different moments can reach different conclusions, especially during the brief window when an instance is degrading. The fleet's health state is eventually consistent rather than authoritative.

**Passive health checks** (also called outlier detection or failure tracking) take a different approach: instead of probing, the client watches the outcomes of real requests. A connection refused, a timeout, a stream of 500s. These are signals that something is wrong with that instance. The client marks it unhealthy locally and stops routing to it for a backoff period.

```
  Client A sends request to Instance 3
       │
       ▼
  Instance 3 → connection refused
       │
       ▼
  Client A marks Instance 3 unhealthy
  Client A stops routing to Instance 3 for 30s
  Client B has not sent a request yet → still considers Instance 3 healthy
```

Passive checking has a meaningful advantage: failure detection is immediate. The first failed request triggers the response; there is no polling interval to wait through. The cost is that at least one real request must fail before the client reacts. In high-throughput systems this is usually acceptable; in low-traffic or bursty scenarios it can mean more user-visible errors.

## What Each Model Gets Right

**Server-side load balancing** gives you a single, consistent view of fleet health. Every client gets the same routing decisions without knowing anything about the backend topology. This is operationally simple: health check configuration lives in one place, changes take effect instantly across all callers, and the backend is completely decoupled from the routing logic. At modest scale, a few dozen services and hundreds of clients, this is almost always the right default.

**Client-side load balancing** trades that simplicity for scale. When you have thousands of services talking to each other at high call rates, a central proxy becomes a bottleneck and a single point of failure. Removing it from the request path reduces latency and eliminates a class of infrastructure failure. Passive health checking gives clients sub-request-latency failure detection that a polling-based central proxy simply cannot match.

The cost is real: distributed health state is harder to reason about. Two clients can disagree on whether an instance is healthy. Debugging a routing anomaly requires looking at state spread across hundreds of processes rather than one. And the health check logic itself (thresholds, backoff, jitter) needs to live in every client library, tested and maintained across every language your organization uses.

## Choosing Between Them

There is no universal answer. The right model depends on your fleet size, call rates, operational maturity, and how much complexity you can manage in client libraries.

Server-side load balancing is simpler to operate and reason about. For most teams and most services, it is the right starting point.

Client-side load balancing pays off when scale makes a central proxy genuinely painful: when the proxy itself becomes a bottleneck, when you need sub-millisecond failure detection, or when the overhead of a proxy hop is measurable and matters.

Many large systems end up using both: server-side load balancing at the ingress layer where clients are external and uncontrollable, and client-side load balancing for internal service-to-service calls where the client library can be standardized. The health checking story in each layer is different, the failure modes are different, and understanding both is what lets you reason clearly about where traffic actually goes when things go wrong.
