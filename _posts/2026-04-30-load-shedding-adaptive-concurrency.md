---
title: "Load Shedding and Adaptive Concurrency: Dropping the Right Requests"
description: "Past a saturation point, accepting more load drives goodput to zero. The fix is not more capacity: it is deciding, fast and early, which requests to drop. Here is how Little's Law, adaptive concurrency limits, and CoDel-style queue management let a server shed the right requests to stay alive."
date: 2026-04-30 12:00:00 +0000
categories: [Distributed Systems, Reliability]
tags: [load-shedding, concurrency, backpressure, reliability, resilience, distributed-systems]
image:
  path: /assets/img/posts/load-shedding/hero.svg
  alt: "A server at its concurrency limit admitting requests up to a goodput-preserving threshold while shedding excess load with fast 503s, with a queue and a latency gauge in front"
---

There is a load level past which accepting one more request makes everything worse. Not a little worse: catastrophically worse. The server keeps saying yes, queues keep filling, latency climbs until every request times out, and the throughput of *useful* work, the goodput, collapses to zero. The machine is busier than it has ever been and accomplishing nothing.

The instinct is to treat this as a capacity problem and add servers. Sometimes that is right. But the more important truth is the one engineers avoid: **when you are over capacity, doing nothing is a choice, and it is the choice that fails worst.** A server that does not actively decide which requests to drop will have that decision made for it by timeouts, OOM kills, and thread-pool exhaustion, all of which discard work at the worst possible moment, after you have already paid for it. Load shedding is the discipline of dropping the right requests, early, on purpose.

## The Congestion Collapse Curve

Plot goodput against offered load and the shape is not a line that flattens. It rises, peaks, and then falls off a cliff. Below the peak, more load means more useful work. At the peak, the server is at capacity. Past it, goodput *decreases* as load increases, because every accepted request consumes resources (memory, connections, CPU on context switches) that it then fails to convert into a completed response.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="20" x2="12" y2="10"/><line x1="18" y1="20" x2="18" y2="4"/><line x1="6" y1="20" x2="6" y2="16"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">goodput vs offered load</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">goodput
  |          <span style="color:#22c55e;">.--.</span>         &lt;- peak: server at capacity
  |        <span style="color:#22c55e;">.&#39;</span>    <span style="color:#ef4444;">&#39;.</span>
  |      <span style="color:#22c55e;">.&#39;</span>        <span style="color:#ef4444;">&#39;.</span>       <span style="color:#64748b;"># past the peak, accepting more</span>
  |    <span style="color:#22c55e;">.&#39;</span>            <span style="color:#ef4444;">&#39;.</span>     <span style="color:#64748b;"># load DROPS useful throughput</span>
  |  <span style="color:#22c55e;">.&#39;</span>                <span style="color:#ef4444;">&#39;._</span>
  | <span style="color:#22c55e;">/</span>                    <span style="color:#ef4444;">&#39;-.____</span>  &lt;- congestion collapse
  +--------------------------------- offered load
       healthy        overloaded</code></pre>
</div>

The goal of every technique in this post is to keep the server operating at or just below that peak, regardless of how much load arrives. You cannot control the offered load. You can control how much of it you admit.

## Little's Law Is the Lens

The cleanest way to reason about a server's state is [Little's Law](https://en.wikipedia.org/wiki/Little%27s_law): the average number of requests in flight equals the arrival rate multiplied by the average time each spends in the system.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="4" y1="9" x2="20" y2="9"/><line x1="4" y1="15" x2="20" y2="15"/><line x1="10" y1="3" x2="8" y2="21"/><line x1="16" y1="3" x2="14" y2="21"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">Little&#39;s Law</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">concurrency (L)  =  arrival rate (&#955;)  &#215;  latency (W)

<span style="color:#64748b;"># 2000 req/s &#215; 0.050s latency  =  100 in flight</span>
<span style="color:#64748b"># latency is not independent: as L rises past the</span>
<span style="color:#64748b"># server&#39;s real capacity, W climbs, which raises L further.</span>
<span style="color:#64748b"># That feedback loop IS congestion collapse.</span></code></pre>
</div>

Read it as a control statement. If you cap the concurrency L at the value the server can actually serve with healthy latency, then arrivals beyond that point have nowhere to go except a queue or the door. The whole problem reduces to one question: **what is the right value of L?**

A **fixed** concurrency limit is the obvious answer, and it is genuinely hard to get right. Pick it too low and you waste capacity, rejecting traffic the server could have served. Pick it too high and it does not protect you at all, because the server collapses before the limit is reached. Worse, the right number is not a constant. It moves with payload size, cache hit rate, a slow downstream dependency, a noisy neighbor on the same host, or a garbage-collection pause. A limit you tuned during a calm afternoon is wrong during the incident you actually needed it for.

## Adaptive Concurrency: Let Latency Set the Limit

The better approach is to stop guessing the number and instead *infer* it from the server's own behavior. The signal is latency. When in-flight concurrency is below the true capacity, adding more requests barely moves latency. Once you cross capacity, queueing begins and latency rises sharply. That inflection is the limit, and the server can find it continuously.

This is exactly the insight behind TCP congestion control, repurposed for application concurrency. [Netflix's concurrency-limits](https://github.com/Netflix/concurrency-limits) library implements several variants. The simplest is **AIMD** (additive increase, multiplicative decrease): grow the limit by a small step on success, and cut it by a multiplicative factor the moment you see the signal of overload (a timeout, a rejection, or a latency spike).

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">AIMD adaptive limit · pseudocode</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#94a3b8;">on</span> request_success(rtt):
    <span style="color:#94a3b8;">if</span> rtt &lt; threshold <span style="color:#94a3b8;">and</span> in_flight &gt;= limit * <span style="color:#f0abfc;">0.9</span>:
        limit = limit + <span style="color:#f0abfc;">1</span>            <span style="color:#64748b;"># additive increase: probe upward</span>

<span style="color:#94a3b8;">on</span> request_drop_or_timeout():
    limit = max(<span style="color:#f0abfc;">1</span>, limit * <span style="color:#f0abfc;">0.8</span>)    <span style="color:#64748b;"># multiplicative decrease: back off fast</span>

<span style="color:#94a3b8;">on</span> new_request():
    <span style="color:#94a3b8;">if</span> in_flight &gt;= limit:
        reject_fast()                  <span style="color:#64748b;"># 503 now, do not queue</span>
    <span style="color:#94a3b8;">else</span>:
        in_flight += <span style="color:#f0abfc;">1</span>; serve()</code></pre>
</div>

The Gradient and Vegas-style limiters in the same family are smarter still: they hold a baseline of the minimum observed latency (the latency with no queueing) and compare it to a short-term sample. The ratio is a gradient. When current latency drifts above the no-queue baseline, queueing has started, and the limiter shrinks the limit proportionally rather than waiting for an outright failure. The limit tracks real capacity as it shifts under you, with no number to hand-tune. That is the same control-plane-driven, measure-then-react philosophy I described for [concurrent connection handling in reverse proxies](/2026/03/09/concurrent-requests-reverse-proxy.html), pushed down to the level of an individual server's admission decision.

## Manage the Queue, Not Just the Limit

A concurrency limit decides what to admit. But requests that are admitted and then wait still need managing, because a request that has sat in a queue for three seconds is often worthless: the client gave up, or its own deadline has passed. Serving it now spends capacity producing a response nobody will read. This is **head-of-line latency**, and naive FIFO queues are bad at it.

[CoDel](https://queue.acm.org/detail.cfm?id=2209336) (controlled delay), borrowed from network queue management, fixes this by tracking how long requests *dwell* in the queue rather than how long the queue *is*. A short, persistently slow-draining queue is the real warning sign, not a momentary burst. When the minimum dwell time over a window exceeds a target, CoDel starts dropping from the queue, and crucially it drops the **oldest** requests first.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">CoDel-style queue admission</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#94a3b8;">on</span> dequeue(req):
    dwell = now() - req.enqueued_at
    <span style="color:#94a3b8;">if</span> dwell &gt; req.deadline:
        drop(req)                  <span style="color:#64748b;"># already stale: serving it wastes capacity</span>
        <span style="color:#94a3b8;">continue</span>
    <span style="color:#94a3b8;">if</span> min_dwell_in_window &gt; TARGET:  <span style="color:#64748b;"># e.g. TARGET = 5ms sustained</span>
        drop_oldest()              <span style="color:#64748b;"># shed the head, keep fresh requests moving</span>
    serve(req)</code></pre>
</div>

Dropping the oldest request is counterintuitive and exactly right. The oldest request has waited longest, is closest to its client's deadline, and is the one most likely to be abandoned already. Newer requests have the best chance of completing within their budget. CoDel keeps goodput high by spending capacity on requests that can still be useful, which is the entire point.

## Load Shedding Is a Policy, Not a Reflex

Knowing you must drop requests is half the work. Choosing *which* ones is the other half, and it is where engineering judgment lives. A few principles hold up across systems.

**Shed by priority and cost.** Not all requests are equal. A health check, a payment, a paying user's checkout, and a speculative prefetch have wildly different value. Tag traffic with a priority class and shed the cheapest, least important classes first. When the server is at its limit, the request to drop is the one whose loss hurts least, never a random victim. This is why [health checks deserve their own protected path](/2026/01/12/health-checks-client-vs-server-side-lb.html): shedding the very signal load balancers use to judge your health turns a local overload into a fleet-wide outage as the balancer pulls a still-useful instance.

**Shed early, at the edge.** A request rejected after it has traversed three hops, opened a database connection, and deserialized a payload has already cost you most of what it would have cost to serve. Reject at the outermost layer you can, ideally the load balancer or the edge proxy, before the expensive work begins. The cheapest request to shed is the one you never let in.

**Reject fast, do not queue.** When you must say no, say it immediately with a fast 503 (or 429). A request held in a queue until it times out consumes a connection slot and memory the whole time and then fails anyway: the worst of both worlds. A fast rejection frees the resource instantly and lets a well-behaved client back off or fail over. The fast no is a feature.

**Protect critical traffic explicitly.** Reserve a slice of capacity for the traffic you cannot lose. When load sheds, the protected class keeps flowing while the discretionary classes absorb the cut. The decision of what is critical belongs in your config, not in the random order that a saturated thread pool happens to drop work.

## The Retry Trap and Backpressure

Load shedding interacts badly with one nearly universal client behavior: the retry. A shed request returns an error, the client retries, and now your offered load has *increased* precisely when you were trying to reduce it. Blind retries against an overloaded server are a feedback loop that turns a brief overload into a sustained one, a retry storm. Shedding plus naive retries is worse than either alone.

The defenses are well known and must be in place before shedding helps: retry budgets that cap retries as a small fraction of total requests, exponential backoff with jitter so clients do not retry in lockstep, and circuit breakers that stop retrying a backend that is clearly down. A 503 that means *do not come back right now* should be honored, not hammered.

The broader frame is **backpressure**: an overloaded component must be able to push its overload signal upstream so the pressure is relieved at the source rather than absorbed silently. A server that sheds is sending backpressure to its callers. A caller that respects it slows down or shifts traffic. A caller that ignores it converts your protective shedding into a denial-of-service attack against yourself. Shedding and backpressure are two halves of one mechanism: the server signals, and the system as a whole must respond. This is the same dynamic that governs how [load balancers spread and react to per-instance pressure](/2026/03/02/load-balancing-algorithms.html); the admission decision on a single server only works when the layer above it honors the answer.

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">A server cannot choose how much load arrives. It can only choose how much it admits, which requests it drops, and how fast it says no. Make those choices on purpose, or the timeouts will make them for you, and they will choose worst.</p>

---

*This builds on my earlier pieces on [concurrent request handling in reverse proxies](/2026/03/09/concurrent-requests-reverse-proxy.html), [load balancing algorithms](/2026/03/02/load-balancing-algorithms.html), and [health checking in client vs server-side load balancing](/2026/01/12/health-checks-client-vs-server-side-lb.html).*

*Tuning admission control or fighting retry storms in production? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
