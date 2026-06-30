---
title: "Cache Stampede: When a Cache Miss Takes Down the Origin"
description: "A single hot key expiring can take down the very database your cache was protecting. Here is why the cache-miss herd happens, and how request coalescing, probabilistic early expiration, and stale-while-revalidate each defuse it."
date: 2026-04-16 12:00:00 +0000
categories: [Distributed Systems, Caching]
tags: [caching, cache-stampede, request-coalescing, performance, reliability, distributed-systems]
image:
  path: /assets/img/posts/cache-stampede/hero.svg
  alt: "A popular cache key expiring while many concurrent requests all miss and hammer the origin, contrasted with a single coalesced fetch that shields it"
---

A cache exists to keep load off the origin. The uncomfortable truth is that a cache can also be the thing that takes the origin down, and it usually does so at the worst possible moment: when a single, very popular key expires. The instinct is to treat the cache as a passive speed-up layer that either has the answer or does not. The hidden assumption in that mental model is that a miss is cheap and local. For a hot key under real traffic, a miss is neither. It is a synchronized event that releases a flood.

This is the **cache stampede**, also called dog-piling or the thundering herd on a cache miss. It is worth being precise about the name, because there is a different failure with a similar shape: a retry storm, where clients all retry a failed call at once. A stampede is the cache-miss herd. Nobody failed. The key simply expired, and everyone who wanted it arrived to find it gone at the same instant.

## The Setup: One Expiry, N Simultaneous Misses

Picture a key that backs your homepage feed, or a product page for a trending item. It gets a thousand requests per second, and it is cached with a sixty-second TTL. For fifty-nine seconds, every one of those requests is a cache hit served in microseconds. The origin sees nothing.

Then the TTL elapses. The very next request misses. So does the one behind it, and the next thousand that arrive in the few hundred milliseconds it takes to recompute the value. None of them find a cached answer, so each one independently decides to do the expensive thing: query the database, render the page, call the downstream service. A workload the origin never saw suddenly hits it a thousand times over, for a single value that one request could have produced.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">naive cache-aside · the herd</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#94a3b8;">def</span> <span style="color:#7dd3fc;">get_value</span>(key):
    val = cache.get(key)
    <span style="color:#94a3b8;">if</span> val <span style="color:#94a3b8;">is</span> <span style="color:#94a3b8;">not</span> <span style="color:#f0abfc;">None</span>:
        <span style="color:#94a3b8;">return</span> val

    <span style="color:#64748b;"># Every concurrent miss reaches this line at once.</span>
    <span style="color:#64748b;"># 1000 callers =&gt; 1000 origin queries for ONE value.</span>
    val = origin.compute(key)          <span style="color:#64748b;"># the expensive call</span>
    cache.set(key, val, ttl=<span style="color:#f0abfc;">60</span>)
    <span style="color:#94a3b8;">return</span> val</code></pre>
</div>

The damage compounds. The origin, now overloaded, answers each of those thousand queries more slowly. Slower recomputes mean the window where the key is missing stays open longer, which lets even more requests pile into it. Latency climbs, the database connection pool saturates, and the failure can spread to every other key that shares that origin. A cache that was carrying 99.9% of the read load has, for a few seconds, carried none of it, and handed the origin a spike it was never provisioned for. This is the same resource-exhaustion dynamic I described for proxies in [how reverse proxies handle concurrent connections](/2026/03/09/concurrent-requests-reverse-proxy.html): the thin, fast layer protects the expensive one right up until it does not, and then the expensive layer eats the whole surge at once.

## Request Coalescing: One Recompute, Shared by All

The most direct fix is to notice that those thousand callers all want the same value, so only one of them should actually compute it. This is **request coalescing**, also known as single-flight: the first request to miss takes responsibility for the recompute, and every other caller that arrives while that work is in flight waits for it and shares the single result.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">single-flight coalescing · per process</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">inflight = {}                 <span style="color:#64748b;"># key -&gt; Future, guarded by a lock</span>

<span style="color:#94a3b8;">def</span> <span style="color:#7dd3fc;">get_value</span>(key):
    val = cache.get(key)
    <span style="color:#94a3b8;">if</span> val <span style="color:#94a3b8;">is</span> <span style="color:#94a3b8;">not</span> <span style="color:#f0abfc;">None</span>:
        <span style="color:#94a3b8;">return</span> val

    <span style="color:#94a3b8;">with</span> lock:
        <span style="color:#94a3b8;">if</span> key <span style="color:#94a3b8;">in</span> inflight:
            fut = inflight[key]    <span style="color:#64748b;"># someone is already computing; join them</span>
        <span style="color:#94a3b8;">else</span>:
            fut = inflight[key] = Future()
            owner = <span style="color:#f0abfc;">True</span>

    <span style="color:#94a3b8;">if</span> owner:
        val = origin.compute(key)  <span style="color:#64748b;"># ONLY the first caller runs this</span>
        cache.set(key, val, ttl=<span style="color:#f0abfc;">60</span>)
        fut.set_result(val)
        <span style="color:#94a3b8;">del</span> inflight[key]

    <span style="color:#94a3b8;">return</span> fut.result()           <span style="color:#64748b;"># all the others wait and share it</span></code></pre>
</div>

Go's `singleflight` package and the read-through mode of most cache libraries implement exactly this. The subtlety is scope. The map above coalesces within one process. If you run a hundred application instances, you can still get up to a hundred concurrent recomputes, one per process, which is far better than a thousand but not one. To get true single-flight across the fleet you need a shared lock, typically a short-lived key in the cache itself, which moves us to leases.

## Locks and Leases: Coordinating the Recompute Across the Fleet

To coalesce across processes, the first miss takes a **lock** in the shared cache (a `SET key NX` with a short TTL), recomputes, and writes the value. Other processes that see the miss also see the lock held, so instead of recomputing they wait briefly and re-read, or serve a slightly stale value if they have one.

The hidden failure mode here is the one people forget: **what happens when the holder of the lock dies mid-recompute?** If the lock had no expiry, every other caller would wait forever, and you would have converted a load spike into a total outage for that key. This is why the recompute lock must always be a **lease**: a lock with a TTL, so that if the owner crashes or stalls, the lease expires and another request is allowed to try. The lease TTL is a real tradeoff. Too short, and a slow-but-healthy recompute loses its lease and you get a second stampede behind it. Too long, and a genuinely stuck recompute blocks the key for that whole duration. The same liveness-versus-safety tension shows up in [client-side versus server-side health checking](/2026/01/12/health-checks-client-vs-server-side-lb.html): you are deciding how long to trust a worker before you assume it is dead.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">recompute lease · shared cache</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># Try to win the right to recompute. The TTL is the lease:</span>
<span style="color:#64748b;"># if we crash, it expires and someone else may retry.</span>
won = cache.set(<span style="color:#a3e635;">"lease:"</span> + key, token, nx=<span style="color:#f0abfc;">True</span>, ttl=<span style="color:#f0abfc;">5</span>)

<span style="color:#94a3b8;">if</span> won:
    val = origin.compute(key)
    cache.set(key, val, ttl=<span style="color:#f0abfc;">60</span>)
    cache.delete(<span style="color:#a3e635;">"lease:"</span> + key)    <span style="color:#64748b;"># release early on success</span>
    <span style="color:#94a3b8;">return</span> val

<span style="color:#64748b;"># Lost the race: wait briefly, then read the fresh value</span>
<span style="color:#64748b;"># (or serve stale if we have it).</span>
<span style="color:#94a3b8;">return</span> wait_for_fresh(key) <span style="color:#94a3b8;">or</span> stale</code></pre>
</div>

## Probabilistic Early Expiration: Stop Everyone From Missing at Once

Coalescing controls the blast radius after the miss. A complementary idea attacks the synchronization itself: do not let the whole herd miss at the same instant. **Probabilistic early expiration**, often called XFetch after the paper that formalized it, has each reader independently and randomly decide to refresh the value slightly *before* the TTL elapses. The closer the key is to expiry, and the more expensive it was to compute, the higher the chance any given reader volunteers to refresh it early.

Because the decision is randomized and per-request, one unlucky reader typically refreshes the key while everyone else is still happily hitting the cache, so the expensive recompute happens with no gap and no crowd. The value is replaced before it ever goes missing.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">probabilistic early expiration (XFetch)</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#94a3b8;">import</span> math, random, time

<span style="color:#94a3b8;">def</span> <span style="color:#7dd3fc;">should_refresh_early</span>(delta, expiry, beta=<span style="color:#f0abfc;">1.0</span>):
    <span style="color:#64748b;"># delta = how long the last recompute took.</span>
    <span style="color:#64748b;"># As "now" nears expiry, this crosses zero and we refresh.</span>
    now = time.time()
    jitter = delta * beta * -math.log(random.random())
    <span style="color:#94a3b8;">return</span> now + jitter &gt;= expiry

<span style="color:#94a3b8;">if</span> val <span style="color:#94a3b8;">is</span> <span style="color:#f0abfc;">None</span> <span style="color:#94a3b8;">or</span> <span style="color:#7dd3fc;">should_refresh_early</span>(delta, expiry):
    val = origin.compute(key)      <span style="color:#64748b;"># a lone early volunteer, not a herd</span>
    cache.set(key, val, ttl=<span style="color:#f0abfc;">60</span>)</code></pre>
</div>

XFetch composes well with coalescing: early expiration spreads out *when* refreshes happen, and single-flight ensures that even if two volunteers fire close together, only one recompute reaches the origin.

## Stale-While-Revalidate: Never Block a Reader on a Recompute

There is a third strategy that changes the deal entirely. Instead of making readers wait for a fresh value, you let them keep using a slightly old one while a background refresh runs. This is **stale-while-revalidate**, familiar from HTTP's `Cache-Control` directive and built into most CDNs.

The cache keeps two clocks per entry: a *fresh until* time and a longer *serve-stale until* time. While the value is fresh, you serve it. Once it passes fresh-until but is still inside serve-stale, you return the stale value immediately and kick off an asynchronous refresh, usually coalesced so only one refresh runs.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">stale-while-revalidate</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">entry = cache.get(key)         <span style="color:#64748b;"># {value, fresh_until, stale_until}</span>

<span style="color:#94a3b8;">if</span> entry <span style="color:#94a3b8;">and</span> now &lt; entry.fresh_until:
    <span style="color:#94a3b8;">return</span> entry.value                <span style="color:#64748b;"># fresh: serve it</span>

<span style="color:#94a3b8;">if</span> entry <span style="color:#94a3b8;">and</span> now &lt; entry.stale_until:
    refresh_in_background(key)         <span style="color:#64748b;"># coalesced; no reader waits</span>
    <span style="color:#94a3b8;">return</span> entry.value                <span style="color:#64748b;"># serve stale right now</span>

<span style="color:#94a3b8;">return</span> compute_and_wait(key)        <span style="color:#64748b;"># only a true cold miss blocks</span></code></pre>
</div>

The cost is honesty: you are choosing to serve data that may be a few seconds out of date in exchange for never exposing a reader to origin latency, and never letting an expiry become a stampede. For a feed, a counter, or a product listing, that trade is almost always correct. For a balance or an inventory count at checkout, it may not be, and you reach for coalescing plus a tight TTL instead.

## Don't Forget Negative Caching and Jittered TTLs

Two smaller habits prevent stampedes that the big strategies miss.

The first is **negative caching**. If a key does not exist in the origin, and you only cache successful answers, then every request for that missing key is a guaranteed miss that goes straight to the origin. A bot probing for nonexistent product IDs becomes a stampede by definition. Cache the "not found" result too, with a short TTL, so a miss for a missing key still shields the origin.

The second is **jittered TTLs**. If you warm or write a large batch of keys at once, with identical TTLs, they will all expire at the same instant and stampede together later, a synchronized herd you created yourself. Adding a small random jitter to each TTL desynchronizes their expiry so the misses spread out over time rather than landing together. This is the same anti-synchronization instinct that good load balancers apply when they spread health checks and retries, which I touched on in [load balancing algorithms](/2026/03/02/load-balancing-algorithms.html): correlated timing is the enemy, and a little randomness is a cheap, powerful defense.

## Putting It Together

The strategies are not competitors, they are layers. Jittered TTLs and negative caching keep expiries from synchronizing in the first place. Probabilistic early expiration refreshes hot keys before they ever go missing. Request coalescing with a leased lock guarantees that even in the worst case, exactly one recompute reaches the origin per key. Stale-while-revalidate makes sure that while all of that happens, no reader is ever blocked waiting on the origin. A serious cache layer in front of a precious origin runs most of these at once.

The deeper lesson is the one the naive mental model hides: a cache miss on a hot key is not a private, cheap event. It is a coordination problem in disguise, and the whole craft of caching at scale is making sure that when a popular value disappears, your system answers the question "who recomputes this?" with "exactly one of us," instead of "all of us, right now, all at once."

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">A cache does not protect your origin because it holds the answer. It protects your origin because of what it does in the brief, dangerous moment when it does not.</p>

---

*This pairs with my earlier writing on [how reverse proxies handle concurrent connections](/2026/03/09/concurrent-requests-reverse-proxy.html), [load balancing algorithms](/2026/03/02/load-balancing-algorithms.html), and [health checking in client vs server-side load balancing](/2026/01/12/health-checks-client-vs-server-side-lb.html).*

*Fighting a stampede in production, or designing a cache layer in front of a fragile origin? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
