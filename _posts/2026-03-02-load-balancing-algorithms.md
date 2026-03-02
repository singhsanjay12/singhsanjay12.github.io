---
title: "The Algorithms Behind Load Balancing: Round Robin, Least Connections, and When Each Breaks"
description: "Every load balancing algorithm encodes a silent assumption about what equal distribution means. Understanding that assumption is what lets you pick the right one — and recognize when the default is working against you."
date: 2026-03-02 12:00:00 +0000
categories: [Distributed Systems, Load Balancing]
tags: [load-balancing, round-robin, least-connections, algorithms, distributed-systems, microservices]
image:
  path: /assets/img/posts/lb-algorithms/hero.svg
  alt: "A load balancer choosing between three servers using different algorithms: round robin cycles blindly, least connections picks the least busy"
---

You add a second server. Traffic splits 50/50. Your p99 latency does not budge. One server is still saturated, the other nearly idle. Round robin is working exactly as designed. The problem is that the design assumes something that is not true about your workload.

Every load balancing algorithm encodes an assumption about what distributing traffic fairly means. Round robin assumes every request costs the same. Least connections assumes connection count reflects work. IP hash assumes that consistency matters more than balance. The algorithm you pick is a choice about which of those assumptions matches your traffic pattern.

## Round Robin: Equality by Count

Round robin cycles through available servers in order. Request one goes to server A, request two to server B, request three to server C, then back to A.

It is the default in most load balancers, and it is the right choice more often than people expect. If your requests are roughly uniform in cost and your servers are identical in capacity, round robin produces an even distribution over time. It has no state to manage, no metrics to collect, and no decisions to make beyond maintaining the server list. That simplicity is a feature.

The assumption it makes is silent: every request is equivalent. A request to serve a cached static asset and a request to execute a complex aggregation query are treated identically. When that assumption holds, round robin is hard to beat. When it breaks, it breaks invisibly.

Consider a service where 10% of requests trigger a multi-second computation. Round robin sends that 10% evenly across all servers. But each slow request occupies a worker thread for seconds while fast requests queue behind it. Server A might be processing three slow requests simultaneously. Server B might have just finished its slow request and be sitting idle. Round robin does not see this. It keeps cycling.

![Round robin cycling through three servers in strict order, each receiving exactly one third of requests](/assets/img/posts/lb-algorithms/round-robin.svg)

## Weighted Round Robin: Equality by Proportion

Weighted round robin extends the basic algorithm with a capacity hint. You assign each server a weight proportional to its processing power. A server with weight 3 receives three requests for every one received by a server with weight 1.

This is the natural choice for heterogeneous fleets: different instance types, or servers that share capacity with another workload. It solves the capacity mismatch that pure round robin ignores.

But it inherits round robin's deeper assumption: requests are uniform. A heavier-weighted server just handles proportionally more of them. And weights are static. You configure them at deploy time and they stay fixed until you change them manually. If a server degrades in capacity due to a noisy neighbor, a memory leak, or CPU throttling, its weight stays the same. Traffic keeps arriving at the configured rate.

Weighted round robin works well when your capacity differences are predictable and stable. It is the wrong tool when capacity fluctuates or when request cost varies significantly.

![Weighted round robin: Server A with weight 3 receives three requests per cycle, Server B weight 1 receives one, Server C weight 2 receives two](/assets/img/posts/lb-algorithms/weighted-round-robin.svg)

## Least Connections: Equality by Current Load

Least connections routes each new request to the server with the fewest active connections. The load balancer tracks a counter per server: increment on connection open, decrement on close. The overhead is small, and the payoff is significant.

This algorithm sidesteps the uniform-request assumption. If server A is handling five long-running connections and server B has one, the next request goes to B regardless of what round robin would say. The algorithm responds to the actual state of the fleet rather than cycling through a fixed sequence.

![Two scenarios: round robin ignoring an overloaded server versus least connections routing around it](/assets/img/posts/lb-algorithms/round-robin-vs-least-conn.svg)

Least connections performs better than round robin in two common situations. First, long-lived connections: WebSocket connections, gRPC streams, and database sessions that stay open for seconds or minutes. Round robin does not see duration. Least connections does. Second, variable request cost: if slow requests keep connections open longer, least connections naturally routes new traffic away from the overloaded server without any explicit configuration.

The assumption least connections makes is that connection count is a reasonable proxy for work. This is generally true. It can fail when connections are cheap to hold but expensive to serve on bursts, or when a server holds many idle keepalive connections that are not consuming resources. In practice, these cases are uncommon enough that least connections is often the better default for HTTP/2 and gRPC workloads where long-lived streams are the norm.

## Weighted Least Connections: Both at Once

Weighted least connections combines the two previous approaches. The routing decision uses `active_connections / weight` for each server. A server with weight 3 can hold three times as many connections before the algorithm routes traffic elsewhere.

This handles heterogeneous fleets with variable request costs: both the static capacity difference (via weights) and the real-time load difference (via connection counts). The tradeoff is operational weight. You need to configure and maintain the weights, and getting them wrong produces systematic imbalance that is hard to debug because the algorithm appears to be working.

![Weighted least connections: Server A has weight 3 and 9 connections giving score 3.0; Server B has weight 2 and 4 connections giving score 2.0 — Server B is chosen](/assets/img/posts/lb-algorithms/weighted-least-connections.svg)

## Least Response Time: Equality by Observed Latency

Least response time routes to the server with the lowest combination of active connections and measured response time. Instead of using connection count as a proxy for load, it observes the actual signal: how long requests are taking.

When one server starts returning responses slowly (due to resource contention, a slow downstream dependency, or garbage collection pauses), least response time detects this and routes new traffic elsewhere. The algorithm is self-correcting in a way that round robin and least connections are not.

The cost is measurement overhead. The load balancer must track response times per server, typically using an exponential moving average. This is small but non-trivial. Response time is also noisier than connection count: a single slow request can temporarily skew the average and cause traffic to shift away from a healthy server. In practice, least response time is most valuable for backends with high variance in response time where that variance correlates with server load, and less useful when latency spikes are caused by external dependencies rather than server-side resource pressure.

![Least response time: Server A slows to 820ms average during a GC pause, traffic automatically shifts to Server B at 58ms with no config change](/assets/img/posts/lb-algorithms/least-response-time.svg)

## Random Selection

Random selection picks a server uniformly at random for each request. This sounds naive, but it has a useful property: with a large enough server pool, it converges to even distribution over time without any coordination or state.

Random is particularly relevant in distributed load balancing, where many clients make independent routing decisions. If each client picks a random server, the aggregate distribution is even without any central coordinator. This is one reason why client-side load balancers in service meshes often use random or a variant called power-of-two-choices: pick two servers at random, route to the one with fewer connections. The random selection prevents thundering herd on any one server; the connection check prevents sending to one that is already busy.

![Power of two choices: two servers picked at random from five, compared by connection count, request routed to the one with fewer](/assets/img/posts/lb-algorithms/random.svg)

## IP Hash: Consistency Over Balance

IP hash computes a hash of the client's IP address and maps it to a server. The same client IP always reaches the same server, as long as the server list does not change.

This gives you sticky sessions without cookies. The use case is stateful backends: session data stored in memory, application-level caches that are expensive to warm, or legacy services that assume a single server handles all requests from a given client.

![IP hash routing: stable clients get consistent routing, but a shared NAT IP sends all its traffic to one overloaded server](/assets/img/posts/lb-algorithms/ip-hash.svg)

The tradeoff is significant. IP hash breaks the load balancing guarantee. If one client IP sends disproportionately more traffic (a CDN egress node, a corporate NAT gateway representing thousands of users), that server receives all of it. Adding or removing a server reshuffles many mappings, disrupting existing sessions. Mobile clients change IPs. Clients behind proxies share IPs.

IP hash is a workaround for stateful application design. If you need stickiness, cookie-based session affinity is more predictable: the routing key is controlled rather than inferred from the network, you can invalidate it explicitly, and it survives IP changes. IP hash should be a last resort, not a convenience.

## What the Algorithm Cannot Fix

No algorithm compensates for routing traffic to an unavailable server. A load balancer that picks the server with fewest connections and then sends a request to one that is down is worse than any routing decision among healthy servers. Health checking is the prerequisite; the algorithm is the refinement.

The details of how server-side and client-side load balancers detect and remove unhealthy instances are covered in [The Instance Is Up. Or Is It?](/2026/01/12/health-checks-client-vs-server-side-lb.html). And for why DNS-level routing is not a substitute for a real load balancer even for simple distributions, see [When DNS Load Balancing Is Not Enough](/2026/02/24/when-dns-load-balancing-is-not-enough.html).

## Choosing the Right Algorithm

The choice collapses to two independent questions: are your servers identical in capacity, and does request cost vary? Answer both and you have your algorithm.

![Decision guide: two questions — server homogeneity and request uniformity — determine which load balancing algorithm fits your workload](/assets/img/posts/lb-algorithms/choosing.svg)

| Workload | Algorithm | What to watch for |
|---|---|---|
| Identical servers, uniform request cost | Round robin | Slow requests queue invisibly behind fast ones |
| Identical servers, variable cost or long-lived connections | Least connections | Idle keepalives can inflate connection counts |
| Heterogeneous fleet, uniform cost | Weighted round robin | Weights go stale as capacity fluctuates |
| Heterogeneous fleet, variable cost | Weighted least connections | Misconfigured weights cause hard-to-diagnose imbalance |
| High response-time variance tied to server load | Least response time | External latency spikes misdirect traffic off healthy servers |
| Stateful backend, no other option | IP hash | NAT gateways, IP changes, and server additions all break stickiness |

The deeper pattern is this: each algorithm optimizes for a different definition of equal. Round robin makes count equal. Least connections makes current load equal. Least response time makes observed latency equal. IP hash makes routing consistent rather than equal.

Getting the wrong one means your load balancer is enforcing the wrong definition of fairness, and the resulting imbalance will show up in latency percentiles and error rates rather than in obvious failure. The servers will all report healthy. The algorithm will report no errors. The slowdown will look like a capacity problem when it is actually a routing problem.
