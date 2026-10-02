---
title: "Rate Limiting at Scale: Token Bucket vs Leaky Bucket vs Sliding Window"
description: "Rate limiting looks like a one-liner until you run it across a fleet. Here is how token bucket, leaky bucket, fixed window, and sliding window actually behave, why distributed counting is the hard part, and where to enforce the limit."
date: 2026-04-09 12:00:00 +0000
categories: [Distributed Systems, Reliability]
tags: [rate-limiting, token-bucket, sliding-window, reliability, distributed-systems, traffic]
image:
  path: /assets/img/posts/rate-limiting/hero.svg
  alt: "A token bucket refilling at a steady rate while admitting requests when tokens are available and dropping them when empty, alongside a sliding window counting recent requests"
---

Every rate limiter answers one deceptively simple question: **is this request allowed right now, or not?** The interface is a boolean. The implementation behind that boolean is where the interesting decisions live, and where most production limiters quietly get one of them wrong.

Rate limiting exists for three reasons, and they pull in slightly different directions. The first is **protection**: a service can only handle so many requests per second before latency climbs and it falls over, so you cap the inflow to keep it inside its safe envelope. The second is **fairness**: one noisy tenant should not be able to consume the capacity that a hundred quiet tenants paid for, so you enforce a per-caller share. The third is **defense**: a credential-stuffing script or a scraping bot should hit a wall long before it does damage. The same primitive serves all three, but the limit you choose and where you enforce it depend on which one you are solving for.

This post is about the algorithms behind that boolean, and the part nobody warns you about: making them correct when the limiter is not one process but a fleet of them.

## Token Bucket: Allow Bursts, Cap the Average

The token bucket is the algorithm I reach for first, because it matches how real traffic behaves. Imagine a bucket that holds up to `B` tokens and refills at `R` tokens per second. Each request removes one token. If a token is available, the request is admitted; if the bucket is empty, the request is rejected (or queued). The bucket caps the long-run average at `R` requests per second, but it tolerates a **burst** of up to `B` requests when it is full, which is exactly what you want for traffic that arrives in clumps.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">token bucket · Python</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#94a3b8;">import</span> time

<span style="color:#94a3b8;">class</span> <span style="color:#7dd3fc;">TokenBucket</span>:
    <span style="color:#94a3b8;">def</span> <span style="color:#7dd3fc;">__init__</span>(self, rate, burst):
        self.rate = rate          <span style="color:#64748b;"># tokens added per second (R)</span>
        self.burst = burst         <span style="color:#64748b;"># max tokens the bucket holds (B)</span>
        self.tokens = burst
        self.last = time.monotonic()

    <span style="color:#94a3b8;">def</span> <span style="color:#7dd3fc;">allow</span>(self):
        now = time.monotonic()
        <span style="color:#64748b;"># refill lazily: no background timer, just elapsed time</span>
        self.tokens = min(self.burst, self.tokens + (now - self.last) * self.rate)
        self.last = now
        <span style="color:#94a3b8;">if</span> self.tokens &gt;= <span style="color:#f0abfc;">1</span>:
            self.tokens -= <span style="color:#f0abfc;">1</span>
            <span style="color:#94a3b8;">return</span> <span style="color:#f0abfc;">True</span>     <span style="color:#64748b;"># admit</span>
        <span style="color:#94a3b8;">return</span> <span style="color:#f0abfc;">False</span>         <span style="color:#64748b;"># reject: bucket empty</span></code></pre>
</div>

The detail worth noticing is the **lazy refill**. You do not need a background thread topping up every bucket every tick; you store the last timestamp and compute how many tokens accrued the next time someone asks. That makes a token bucket cheap enough to keep one per caller, per route, per anything, with a single multiply and a `min` on the hot path. It is the algorithm behind most API gateway rate limits for a reason.

## Leaky Bucket: Smooth the Output to a Constant Rate

The leaky bucket is the token bucket's stricter sibling, and people conflate the two constantly. Picture a bucket with a hole in the bottom that drains at a constant rate. Requests pour in and queue up; they leave the bucket at a fixed pace no matter how bursty the arrivals were. The key difference: a token bucket lets a burst **pass through** when it has saved up tokens, while a leaky bucket **paces the output** to a steady drip regardless of arrivals.

That distinction decides which one you want. If your goal is to protect a fragile downstream that hates spikes (a legacy database, a third-party API with its own quota), the leaky bucket's smoothing is the right tool: it converts bursty input into a flat, predictable output stream. If your goal is to allow normal bursty behavior while still capping the average (most user-facing APIs), the token bucket is friendlier, because the leaky bucket adds queueing latency to every request that arrives faster than the drain rate. A burst of 50 requests against a 10-per-second leaky bucket means the 50th request waits four seconds. Sometimes that is correct shaping; often it is a latency surprise.

## Fixed Window: Cheap, and Wrong at the Edges

The simplest distributed-friendly counter is the fixed window: pick a window (say one minute), keep a counter per caller, increment on each request, and reject once the counter passes the limit. At the top of the next minute, reset to zero. It is one integer and one comparison. It is also subtly broken.

The failure mode lives at the **window boundary**. A limit of 100 per minute does not actually cap you at 100 requests in any 60-second span. A caller can send 100 requests in the last second of one window and 100 more in the first second of the next, and both windows pass their checks: 200 requests in a two-second span, double the intended ceiling.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">fixed window boundary burst</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># limit = 100 / minute</span>

window 10:00:00 .. 10:00:59   <span style="color:#64748b;"># 100 requests at 10:00:59  -&gt; all allowed</span>
window 10:01:00 .. 10:01:59   <span style="color:#64748b;"># 100 requests at 10:01:00  -&gt; all allowed</span>

<span style="color:#ef4444;"># 200 requests inside a 2-second span, both windows pass their check</span></code></pre>
</div>

For coarse abuse protection that 2x slack is fine. For anything where the limit is a real capacity number, the boundary burst means you must provision for double, which defeats the point.

## Sliding Window: Accurate, at the Cost of State

The sliding window fixes the boundary problem by always looking back exactly one window from *now* instead of from a fixed grid. There are two common flavors.

The **sliding window log** keeps a timestamp for every request, drops the ones older than the window, and counts what remains. It is exact: it answers "how many requests in the last 60 seconds" precisely. The cost is memory and work proportional to the request rate, because you store one entry per request and prune on every check. At high volume that is expensive.

The **sliding window counter** is the approximation most production systems actually run. It keeps the current and previous fixed-window counts and blends them by how far you are into the current window: if you are 30 percent into the current minute, you count all of this window plus 70 percent of the previous one.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">sliding window counter · Python</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#94a3b8;">def</span> <span style="color:#7dd3fc;">allow</span>(now, window, limit, prev_count, curr_count):
    <span style="color:#64748b;"># fraction of the current window already elapsed</span>
    elapsed = (now % window) / window
    <span style="color:#64748b;"># weight the previous window by the part still inside our lookback</span>
    estimate = prev_count * (<span style="color:#f0abfc;">1</span> - elapsed) + curr_count
    <span style="color:#94a3b8;">return</span> estimate &lt; limit          <span style="color:#64748b;"># admit if under the blended count</span>

<span style="color:#64748b;"># two integers per caller, no per-request timestamps,</span>
<span style="color:#64748b;"># and no 2x boundary burst</span></code></pre>
</div>

This is accurate to within a percent or two for steady traffic, costs two integers per caller instead of a timestamp per request, and kills the boundary burst. For most APIs it is the sweet spot between the fixed window's cheapness and the log's precision.

## The Hard Part: Counting Across a Fleet

Everything above assumes one process holds the counter. In production your limiter runs on every node behind a load balancer, and now the question is brutal: **100 requests per second across the fleet, or 100 per node?** Those are wildly different limits, and the algorithm does not answer it. The coordination does.

The naive split is to divide the limit by the node count: 10 nodes, 100 per second total, so 10 per node with a local token bucket. It is fast (no network call on the hot path) and it is wrong the moment traffic is uneven. A [load balancer that hashes on client IP or uses least-connections](/2026/03/02/load-balancing-algorithms.html) does not spread one caller's requests evenly. A single hot caller can saturate the node it lands on, getting rejected at 10 per second, while nine other nodes sit idle and the global limit of 100 is nowhere near reached. You reject traffic you had capacity for.

The accurate fix is a **shared counter**, usually Redis: every node does an atomic increment-and-check against one central count. Now the limit is truly global. The cost is a network round trip on every single request, which adds latency and makes Redis a hard dependency in the request path. If Redis hiccups, your whole fleet's admission decision hiccups with it. The same [per-request coordination tax I wrote about for reverse proxies](/2026/03/09/concurrent-requests-reverse-proxy.html) shows up here: a shared decision is accurate but it is never free.

The pragmatic middle ground is **local buckets with periodic sync**. Each node keeps a local token bucket and serves the hot path entirely from memory, then every few hundred milliseconds it reports its consumption to a central coordinator and receives an adjusted share of the global budget. Nodes seeing more traffic get a larger slice; idle nodes give theirs back. You trade a little accuracy (the global count can briefly drift between sync intervals) for keeping the hot path local and removing the per-request round trip. This is the design most large-scale distributed rate limiters converge on, and it is the same lesson that keeps recurring in distributed systems: a local decision plus periodic reconciliation beats a perfectly consistent decision you have to make synchronously every time.

There is a subtler trap worth naming. An **approximate distributed counter** that tolerates some slack is usually the right call, because the alternative (strict global consistency on every request) buys you a precision that the business almost never needs. Nobody cares whether the limit was exactly 100 or briefly 104 per second. They care a great deal whether the limiter added 5 milliseconds to the p99 of every request. Pick the looseness on purpose.

## Where to Enforce, and What to Return

The last decision is placement, and it follows a simple gradient: enforce as early as possible for the crude limits, and as close to the resource as possible for the precise ones.

The **edge proxy** is where you stop volumetric abuse and obvious floods, before that traffic costs you anything downstream. This is the same edge where I argued [authentication and zero-trust checks belong](/2025/08/03/zero-trust-with-reverse-proxy.html): rejecting a bad request at the front door is always cheaper than rejecting it three hops in. The **API gateway** is where per-API-key and per-tenant quotas live, because that is the layer that knows the caller's identity and plan. The **per-service** limiter is the last line: a service protecting its own database connection pool knows its real capacity better than any upstream does, and should defend it regardless of what slipped past the gateway. These layers are complementary, not redundant.

When you do reject, return the right signal. For HTTP that is **429 Too Many Requests**, and critically, a **Retry-After** header telling the client how long to back off.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">a well-formed rejection</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">HTTP/1.1 <span style="color:#ef4444;">429 Too Many Requests</span>
Retry-After: <span style="color:#f0abfc;">2</span>
X-RateLimit-Limit: <span style="color:#f0abfc;">100</span>
X-RateLimit-Remaining: <span style="color:#f0abfc;">0</span>
X-RateLimit-Reset: <span style="color:#f0abfc;">1712664002</span>

<span style="color:#64748b;"># Retry-After lets a well-behaved client back off cleanly</span>
<span style="color:#64748b;"># instead of hammering you into a retry storm.</span></code></pre>
</div>

The `Retry-After` header matters more than it looks. Without it, a rejected client retries immediately, and a fleet of rejected clients retrying immediately is a self-inflicted [thundering herd](/2026/01/12/health-checks-client-vs-server-side-lb.html) that can be worse than the original spike. Telling the client when to come back turns a stampede into an orderly queue. A good limiter does not just say no; it says no and tells you when to ask again.

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">Choosing a rate-limiting algorithm is easy. The hard question is who owns the count, and the right answer is almost never a perfectly consistent global one: it is a local decision, periodically reconciled, that you tuned the slack on yourself.</p>

---

*This pairs with my writing on [how reverse proxies handle concurrent connections](/2026/03/09/concurrent-requests-reverse-proxy.html), [load balancing algorithms](/2026/03/02/load-balancing-algorithms.html), and [enforcing zero trust at the reverse proxy](/2025/08/03/zero-trust-with-reverse-proxy.html).*

*Tuning rate limits across a fleet and fighting the accuracy-versus-latency tradeoff? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
