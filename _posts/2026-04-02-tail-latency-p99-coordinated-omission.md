---
title: "Chasing the p99: Tail Latency, Coordinated Omission, and the Tail at Scale"
description: "Averages and medians hide the requests that actually hurt. This is why the tail (p99, p99.9) is where your users live, how fan-out turns a rare slow case into the common case, and how coordinated omission makes your benchmarks quietly lie."
date: 2026-04-02 12:00:00 +0000
categories: [Distributed Systems, Performance]
tags: [latency, performance, p99, tail-latency, observability, distributed-systems]
image:
  path: /assets/img/posts/tail-latency-p99/hero.svg
  alt: "A latency distribution with a long right tail, and a fan-out request whose end-to-end time is set by its single slowest backend"
---

The first number everyone reaches for when measuring a service is the average response time. It is the wrong number. **An average tells you almost nothing about whether your users are in pain, because pain does not live in the middle of the distribution. It lives in the tail.**

A service can report a 20ms average and still make a meaningful slice of requests wait for a full second. The fast requests outnumber the slow ones so heavily that the slow ones vanish into the mean. But the slow ones are the ones a real person is staring at, watching a spinner, deciding whether to refresh or leave. This post is about why the tail matters more than the middle, why scale makes the tail worse rather than better, and why the way most people measure latency systematically hides the very thing they are trying to find.

## The Average Is a Lie You Tell Yourself

Consider a service where 99 out of 100 requests take 10ms and 1 in 100 takes 1000ms. The arithmetic is simple.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="20" x2="12" y2="10"/><line x1="18" y1="20" x2="18" y2="4"/><line x1="6" y1="20" x2="6" y2="16"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">what the mean hides</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">99 requests @ 10ms   +   1 request @ 1000ms
mean    = (99*10 + 1000) / 100   = <span style="color:#a3e635;">19.9 ms</span>   <span style="color:#64748b;"># looks healthy</span>
median  =                          <span style="color:#a3e635;">10 ms</span>   <span style="color:#64748b;"># also looks healthy</span>
p99     =                        <span style="color:#fca5a5;">1000 ms</span>   <span style="color:#64748b;"># the truth</span>

<span style="color:#64748b;"># the mean is dragged up a little; the median does not move at all.</span>
<span style="color:#64748b;"># neither one tells you 1 in 100 users waited a full second.</span></code></pre>
</div>

The median is even more seductive than the mean, because it is robust to outliers by design. That robustness is exactly the problem: the median throws away the tail on purpose. If you want to know about the slow requests, you have to ask a question that the slow requests can answer, and that means percentiles: **p99 (the value 99% of requests come in under), p99.9, p99.99.** These are not exotic. At the volumes a modern service handles, p99.9 is not a rounding error. One in a thousand requests, at a million requests a minute, is a thousand suffering users every minute.

## Why Scale Makes the Tail Worse: the Tail at Scale

Here is the part that surprises people. You might assume that as a system grows and gets more redundant, the tail gets smoothed away. The opposite is true. **The more backends a single request touches, the more likely it is to hit at least one slow one, and the slowest one sets the clock.**

This is the central insight from Dean and Barroso's "The Tail at Scale," and it is worth making concrete. Suppose each backend is fast 99% of the time, with a 1% chance of a slow response on any given call. A request that fans out to one backend has a 1% chance of being slow. But a request that fans out to 100 backends and waits for all of them is slow if *any* of those 100 is slow.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/><line x1="8.59" y1="13.51" x2="15.42" y2="17.49"/><line x1="15.41" y1="6.51" x2="8.59" y2="10.49"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">fan-out amplification</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># per-backend chance of being slow: 1% (so 99% fast)</span>
<span style="color:#64748b;"># request waits on ALL N backends; it is slow if ANY one is slow</span>

P(slow end-to-end) = 1 - (0.99 ** N)

N = 1     -&gt;  <span style="color:#a3e635;">1.0%</span>     <span style="color:#64748b;"># a rare event for one backend...</span>
N = 10    -&gt;  <span style="color:#fde047;">9.6%</span>
N = 100   -&gt; <span style="color:#fca5a5;">63.4%</span>     <span style="color:#64748b;"># ...is the common case at fan-out 100</span>
N = 500   -&gt; <span style="color:#fca5a5;">99.3%</span>     <span style="color:#64748b;"># almost every request now waits on a slow backend</span></code></pre>
</div>

A per-backend slow rate of 1% (something you would barely notice in isolation) becomes a 63% chance of a slow response once a request fans out to 100 backends. **The rare per-backend event becomes the common end-to-end event.** This is why a search query, a feed assembly, or any scatter-gather request is so sensitive to tail latency: its response time is the maximum of its parts, not the average, and the maximum of many samples drifts steadily toward the tail of the underlying distribution.

The same dynamic is why load balancing choices matter so much under fan-out. A balancer that occasionally parks a request behind a slow or overloaded backend is feeding the tail directly, which is exactly the failure mode I dug into in [load balancing algorithms](/2026/03/02/load-balancing-algorithms.html). And the cure for a backend that has gone bad is to stop sending it traffic before it pollutes the tail, which is the whole argument for [health checking in client vs server-side load balancing](/2026/01/12/health-checks-client-vs-server-side-lb.html).

## Coordinated Omission: How Your Benchmark Lies to You

Now the subtle part, the one that quietly invalidates a large fraction of latency benchmarks in the wild. **Most load generators systematically under-measure the tail, and they do it in the exact moment the system is at its worst.**

The mechanism is called coordinated omission, a term coined by Gil Tene. A naive load generator works in a closed loop: send a request, wait for the response, record the time, send the next request. That loop sounds reasonable, but it has a fatal coupling. When the system stalls (a GC pause, a lock, a slow backend), the load generator stalls too. It is sitting there waiting for the in-flight response, so it does not send the requests it was supposed to send during the stall. Those requests are never issued, never timed, and never counted.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">closed-loop vs constant-rate</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># intended rate: 1 request every 10ms. then the server stalls for 1s.</span>

<span style="color:#fca5a5;">CLOSED LOOP (coordinated omission):</span>
  t=0     send req, server hangs 1000ms
  t=1000  response arrives, record <span style="color:#a3e635;">1000ms</span>   <span style="color:#64748b;"># ONE slow sample</span>
  <span style="color:#64748b;"># the ~100 requests that SHOULD have fired during the stall</span>
  <span style="color:#64748b;"># were never sent. the tail is erased.</span>

<span style="color:#a3e635;">CONSTANT RATE (correct):</span>
  t=0     send req, server hangs 1000ms
  <span style="color:#64748b;"># requests keep being scheduled at t=10, 20, 30 ... 990</span>
  <span style="color:#64748b;"># each is measured from its SCHEDULED time, not its send time</span>
  <span style="color:#64748b;"># the request due at t=10 waited 990ms; at t=20 waited 980ms ...</span>
  <span style="color:#64748b;"># now you have ~100 slow samples. the tail is real.</span></code></pre>
</div>

The closed-loop generator records one slow sample where a real system, serving a steady arrival of real users, would have produced a hundred. Real users do not politely wait for your server to recover before clicking again: they arrive at whatever rate they arrive, stall or no stall. A correct benchmark models that with a constant arrival rate (an open-loop model) and measures each request's latency from the time it was *supposed* to start, not the time the generator happened to get around to sending it. Tools like [wrk2](https://github.com/giltene/wrk2) exist precisely to fix this, and the correction is dramatic: the same system can show a p99 of 8ms under coordinated omission and a p99 of several hundred milliseconds once you measure it honestly.

If you take one practical thing from this post, take this: **before you trust a latency benchmark, ask whether the load generator kept sending at a fixed rate during a stall, or paused to wait. If it paused, the tail it reports is fiction.**

## Where the Tail Actually Comes From

Knowing the tail matters is one thing. The next question is what produces it, and the sources are mostly mundane infrastructure behavior rather than application logic.

**Garbage collection pauses.** A stop-the-world GC freezes every request in flight on that instance. The pause is brief and rare per instance, but under fan-out it becomes the common case described above.

**Queueing.** When arrival rate approaches service rate, queues form, and queue waiting time grows non-linearly as utilization climbs toward 100%. A service running at 80% utilization has a very different tail from the same service at 95%, even though the average barely moved.

**Head-of-line blocking.** One slow request in front of others on the same connection or worker thread delays everything behind it. This is the connection-management problem I covered in [how reverse proxies handle concurrent connections](/2026/03/09/concurrent-requests-reverse-proxy.html): a single blocking operation on a shared event loop stalls every connection sharing it.

**Retries.** A retry meant to mask a single failure can double the work during an incident, push utilization up, lengthen queues, and make the tail worse for everyone. Retries are a tail-management tool that becomes a tail-amplification tool the moment they are uncapped.

**Cold caches and noisy neighbors.** A freshly started instance with a cold cache serves slowly until it warms. A co-located workload contending for CPU, memory bandwidth, or disk introduces latency that has nothing to do with your code and everything to do with what is running next to it.

## Designing for the Tail

You cannot eliminate the tail. Hardware, kernels, and runtimes all produce occasional slow events, and at scale occasional means constant. The goal is to be tail-tolerant: to keep a slow component from setting the response time.

**Hedged and backup requests.** The most effective tactic from "The Tail at Scale." Send the request to one backend, and if no response arrives within, say, the p95 latency, send a second copy to another backend and take whichever returns first. You pay a small amount of extra load (only the slow tail of requests ever get hedged) to cut the tail dramatically, because you only lose when *both* backends are slow, which is far rarer than one being slow.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="23 4 23 10 17 10"/><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">hedged request (pseudocode)</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">send request to backend A
wait up to p95_latency for a response

<span style="color:#94a3b8;">if</span> no response yet:
    send the SAME request to backend B   <span style="color:#64748b;"># the hedge</span>
    take whichever of A or B returns first
    cancel the loser

<span style="color:#64748b;"># cost: only the slowest ~5% of requests ever fire a hedge</span>
<span style="color:#64748b;"># payoff: you only stay slow if BOTH A and B are slow</span></code></pre>
</div>

**Run with headroom.** Because queueing latency explodes near full utilization, the cheapest tail improvement is often to not run hot. Capacity you "waste" at the average is capacity that absorbs the tail.

**Cap and budget retries.** Treat retries as a limited budget (a small percentage of total traffic) so they help individual slow requests without amplifying load during an incident.

**Measure percentiles correctly, and never average them.** This last one trips up even experienced teams. **You cannot average percentiles.** If one server reports a p99 of 100ms and another reports a p99 of 200ms, the fleet p99 is not 150ms. A percentile is a property of a distribution, and you cannot recover the combined distribution's percentile from two summary numbers. The correct approach is to aggregate the underlying distribution (with histograms, for example [HdrHistogram](https://github.com/HdrHistogram/HdrHistogram) or t-digests) and compute the percentile from the merged data. Averaging the per-host p99s produces a number that is not the fleet p99 and is usually optimistic, hiding the very tail you built the dashboard to watch.

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">The average is the story you tell your dashboard. The tail is the story your users tell each other. Measure the one they live in.</p>

---

*This connects to my earlier writing on [load balancing algorithms](/2026/03/02/load-balancing-algorithms.html), [health checking in client vs server-side load balancing](/2026/01/12/health-checks-client-vs-server-side-lb.html), and [how reverse proxies handle concurrent connections at scale](/2026/03/09/concurrent-requests-reverse-proxy.html).*

*Chasing a tail that will not behave, or arguing about whether a benchmark is honest? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
