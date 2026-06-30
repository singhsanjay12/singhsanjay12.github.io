---
title: "The Power of Two Choices: The Load Balancing Trick That Beats Least Connections"
description: "Random assignment leaves servers badly imbalanced, and global least-connections needs global state it cannot keep fresh. Sampling just two servers at random and picking the lighter one fixes both, and the math behind why two is the magic number is genuinely surprising."
date: 2026-04-06 12:00:00 +0000
categories: [Distributed Systems, Load Balancing]
tags: [load-balancing, power-of-two-choices, algorithms, distributed-systems, least-connections]
image:
  path: /assets/img/posts/power-of-two-choices/hero.svg
  alt: "A request sampling two servers chosen at random, comparing their load, and routing to the less loaded one while the other is left alone"
---

Pick a load balancing algorithm and you usually land in one of two camps. Either you assign requests at random (or its sibling, round-robin), which is cheap and stateless but leaves servers visibly uneven, or you track how busy every backend is and always send the next request to the least loaded one, which is accurate but needs a fresh, global view of the fleet that nobody can actually keep current. Both have a hidden failure mode. There is a third option that sits between them, costs almost nothing, and performs astonishingly close to perfect. It is called the **Power of Two Choices**, and once you understand why it works, you start seeing it everywhere.

This is a companion to my [survey of load balancing algorithms](/2026/03/02/load-balancing-algorithms.html), where I laid out the menu. Here I want to zoom in on one entry, because the reasoning behind it is the most counterintuitive result in the whole field.

## Why Random Is Worse Than It Looks

Random assignment feels fair. Every request rolls a die, every server has an equal chance, and over a long enough run the averages even out. The trap is that **averages are not what hurt you: peaks are.** What a user feels is the load on the single busiest server at the moment their request lands, not the fleet-wide mean.

The classic way to think about this is the balls-into-bins model. Throw `n` balls into `n` bins uniformly at random. The average bin gets one ball, but the **fullest** bin gets roughly `log n / log log n` balls. For a fleet of 100 servers that is not 1 request of backlog on the worst server, it is around 4 or 5. The imbalance is not a rounding error: it is a structural property of randomness. Some bins get unlucky, and with pure random you have no mechanism to correct for it.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">random vs P2C · simulation sketch · Python</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#94a3b8;">import</span> random

<span style="color:#94a3b8;">def</span> <span style="color:#7dd3fc;">place</span>(n, choices):
    bins = [<span style="color:#f0abfc;">0</span>] * n
    <span style="color:#94a3b8;">for</span> _ <span style="color:#94a3b8;">in</span> <span style="color:#94a3b8;">range</span>(n):
        sample = [random.randrange(n) <span style="color:#94a3b8;">for</span> _ <span style="color:#94a3b8;">in</span> <span style="color:#94a3b8;">range</span>(choices)]
        target = <span style="color:#94a3b8;">min</span>(sample, key=<span style="color:#94a3b8;">lambda</span> i: bins[i])  <span style="color:#64748b;"># pick the lighter of the sampled bins</span>
        bins[target] += <span style="color:#f0abfc;">1</span>
    <span style="color:#94a3b8;">return</span> <span style="color:#94a3b8;">max</span>(bins)

<span style="color:#64748b;"># with n = 100000, a typical run looks like:</span>
<span style="color:#64748b;">#   place(n, 1)  -&gt;  max ~ 8   (pure random)</span>
<span style="color:#64748b;">#   place(n, 2)  -&gt;  max ~ 3   (two choices)</span>
<span style="color:#64748b;">#   place(n, 3)  -&gt;  max ~ 3   (three barely helps)</span></code></pre>
</div>

That gap between `choices = 1` and `choices = 2` is the entire story, and it is far larger than your intuition predicts.

## Why Global Least-Connections Is Not the Easy Win

If random leaves peaks, the obvious fix is to stop guessing: track the live connection count (or in-flight requests) for every backend and always route to the minimum. This is **least connections**, and at a single load balancer with a perfectly accurate view it is close to optimal. The problem is the words "perfectly accurate view."

The moment you have more than one load balancer, or any propagation delay in the load signal, least-connections develops a vicious failure mode I call **herding**. Every balancer looks at the same shared (and slightly stale) view, all of them agree that server 7 is currently the least loaded, and all of them slam server 7 simultaneously. By the time the load signal updates, server 7 is the *most* loaded, everyone now sees server 12 as the minimum, and the herd stampedes there instead. The fleet oscillates instead of settling. The very thing that makes least-connections accurate, a shared global notion of "the best server right now," is what makes it stampede when that notion is shared by many deciders.

Keeping a truly global, truly fresh view is the cost nobody mentions. It means every balancer reporting every connection open and close to a shared store, in real time, with the same staleness problem I described for health signals in [client-side vs server-side health checks](/2026/01/12/health-checks-client-vs-server-side-lb.html). You pay for coordination, and you still herd.

## The Trick: Sample Two, Pick the Lighter

The Power of Two Choices (often written P2C, or "two random choices") does something almost insultingly simple. For each request:

1. Pick **two** backends uniformly at random.
2. Query the load of just those two.
3. Send the request to whichever of the two is less loaded.

That is the whole algorithm. You never need a global view. You never rank the whole fleet. You look at two servers, which you already had to pick anyway, and you break the tie toward the lighter one.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">power of two choices · core logic</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#94a3b8;">func</span> <span style="color:#7dd3fc;">pickBackend</span>(backends []Server) Server {
    a := backends[rand.Intn(<span style="color:#94a3b8;">len</span>(backends))]
    b := backends[rand.Intn(<span style="color:#94a3b8;">len</span>(backends))]

    <span style="color:#64748b;">// compare only the two we sampled, no global scan</span>
    <span style="color:#94a3b8;">if</span> a.InFlight() &lt;= b.InFlight() {
        <span style="color:#94a3b8;">return</span> a
    }
    <span style="color:#94a3b8;">return</span> b
}</code></pre>
</div>

The cost is constant per request and there is no coordination, yet the result is nearly as smooth as a perfect global least-connections without any of its herding. That is the surprise.

## The Math: Why Two Is the Magic Number

Here is the result that earned this its own line of research. With pure random the fullest bin holds about `log n / log log n` balls. Add a single extra choice, look at two bins instead of one, and the maximum collapses to roughly:

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">expected max load</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">  1 choice  (random) :   max  ~  log n / log log n
  2 choices (P2C)     :   max  ~  log log n / log 2  +  O(1)
  d choices           :   max  ~  log log n / log d  +  O(1)</code></pre>
</div>

Read those carefully. Going from one choice to two does not shave a constant factor off the imbalance, it changes the **functional form**, from `log n / log log n` down to `log log n`. For a fleet of 100,000 servers, `log n` is large but `log log n` is tiny, a small single-digit number. The worst server goes from carrying a meaningful backlog to carrying barely more than the average. This is the result Mitzenmacher, Azar, and others made famous, and it is why people call it a "phase change" rather than an improvement.

Now look at the third line. Going from two choices to `d` choices only swaps `log 2` for `log d` in the denominator. That is a constant-factor tweak, not another phase change. **Two choices buys you the exponential improvement; every choice after that buys you almost nothing.** Three choices is marginally tighter, but you pay an extra load probe per request for a benefit you will not measure in production. Two is not just good enough, it is the point where the curve bends, and that is why it is the default and not three or five.

## Where You Already Use It

This is not an academic curiosity. It is the quiet default inside a lot of infrastructure you already run.

- **NGINX** ships it as the `random two least_conn` directive in upstream blocks: pick two peers at random, route to the one with fewer active connections. NGINX explicitly recommends it over plain `least_conn` for multi-worker and multi-instance setups, precisely because it avoids the herding I described.
- **gRPC** offers a `weighted_round_robin` and pick-first set of policies, and its load balancing design leans on two-choice style sampling so that many clients choosing independently do not stampede the same backend.
- **Finagle** (Twitter's RPC library) made P2C its standard balancer years ago, scoring two randomly chosen endpoints on least-loaded and a few other signals, specifically to scale to large client fleets without a coordinator.
- **HAProxy** exposes `balance random` and a two-draw variant for exactly this reason: it wants the smoothing of least-connections without a single shared queue that every thread contends on.

The pattern repeats because the constraint repeats. Any time you have many independent deciders (many proxy threads, many clients, many sidecars) routing to a shared fleet, a global "best server" answer is a stampede waiting to happen, and two random choices sidesteps it.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">nginx.conf</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">upstream api {
    random two least_conn;   <span style="color:#64748b;"># sample 2 peers, send to the one with fewer active conns</span>
    server <span style="color:#a3e635;">10.0.1.10</span>:8080;
    server <span style="color:#a3e635;">10.0.1.11</span>:8080;
    server <span style="color:#a3e635;">10.0.1.12</span>:8080;
}</code></pre>
</div>

## The Stale-Load Problem in Distributed P2C

P2C is not a free lunch when it goes distributed. Its one assumption is that the load you read for the two sampled servers is **roughly current**. In a single in-process balancer that holds true: the in-flight counter is exact. But spread the decision across many clients or proxies, each caching its own view of backend load, and the same staleness that wrecks global least-connections can creep back in.

The classic distributed P2C bug looks like this. A pool of clients all observe that server A reported "5 in flight" a second ago and server B reported "20 in flight." Every client, comparing its two samples, keeps favoring A. They all pile onto A while its real load races past B, but nobody's cached number reflects that yet. You have rebuilt herding, just with a sample size of two.

The fix that the production systems converge on is to add a little **freshness and a little randomness** back into the score:

- **Age the load signal.** Weight a backend's reported load by how stale the reading is, or decay it over time, so a server everyone picked a moment ago looks heavier than its last (now obsolete) report. Finagle's load metric and many "least loaded with aging" schemes do exactly this.
- **Break ties randomly and probe live.** Where possible, prefer a near-real-time signal (active in-flight count on the connection you hold) over a cached gauge, and when two samples tie, flip a coin rather than always preferring the lower-indexed server.

The principle is the same one I keep returning to: **a shared, slightly stale notion of "best" is dangerous in the hands of many deciders.** P2C tames it by only ever comparing two servers, but if your load readings are old enough, even two-way comparisons can synchronize. Aging the signal desynchronizes them again.

## When P2C Is the Right Default, and When It Is Not

P2C should be your reflexive default for stateless request routing across a homogeneous backend pool, especially when many independent deciders share that pool. It needs no coordinator, no global state, and no shared queue, and it gets you within a small constant of optimal balance. For a typical fleet of identical service replicas behind a set of proxies, it is hard to do better for the effort.

It is the wrong tool in a few cases. When **request affinity** matters, sessions that must stick to a specific backend, a cache that must stay warm on the same node, you want consistent hashing, not two random draws. When backends are **heterogeneous**, you want weighted variants so a beefier server is sampled or scored proportionally. And for a single load balancer in front of a small pool with a perfectly fresh, exact load view, plain least-connections is genuinely fine, because the herding that motivates P2C only appears once decisions are distributed or signals go stale. The whole menu of these tradeoffs is laid out in the [load balancing algorithms survey](/2026/03/02/load-balancing-algorithms.html), and the [concurrent connections deep dive](/2026/03/09/concurrent-requests-reverse-proxy.html) shows why proxies care so much about avoiding any shared hot path in the first place.

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">The lesson of the Power of Two Choices is humbling: you do not need to know which server is best. You only need to compare two, and let the rest take care of itself. A little local information beats a lot of stale global information almost every time.</p>

---

*This zooms in on one entry from my [load balancing algorithms survey](/2026/03/02/load-balancing-algorithms.html), and connects to [client-side vs server-side health checks](/2026/01/12/health-checks-client-vs-server-side-lb.html) and the [reverse proxy concurrency deep dive](/2026/03/09/concurrent-requests-reverse-proxy.html).*

*Tuning load balancing for a large, distributed fleet? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
