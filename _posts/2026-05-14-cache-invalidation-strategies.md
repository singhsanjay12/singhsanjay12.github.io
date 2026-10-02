---
title: "Cache Invalidation: The Hard Problem, Made Concrete"
description: "Every cache is a bet that stale data is acceptable for some window. Here is how TTL, event-driven purges, and write strategies trade correctness against hit rate, and where distributed invalidation quietly goes wrong."
date: 2026-05-14 12:00:00 +0000
categories: [Distributed Systems, Caching]
tags: [caching, cache-invalidation, ttl, consistency, distributed-systems, performance]
image:
  path: /assets/img/posts/cache-invalidation/hero.svg
  alt: "A write path updating the source of truth while cache nodes serve stale data inside the staleness window, with TTL expiry and event-driven purge as two ways to close it"
---

There is an old joke that the two hard problems in computer science are cache invalidation, naming things, and off-by-one errors. The reason invalidation keeps its spot on that list is not that the code is hard to write. A delete is one line. The hard part is that **every cache is a bet that stale data is acceptable for some window**, and invalidation is the machinery that decides how long that window lasts and how reliably it closes.

Once you frame it that way, the whole topic becomes a single tradeoff stated in different shapes: correctness versus hit rate. A cache that never serves anything stale is just a slow read of the source of truth. A cache that serves stale data forever is fast and wrong. Everything interesting lives in between, and the strategies below are different ways of choosing where in between you want to sit.

## The Staleness Window Is the Real Unit

Before picking a strategy, name the thing you are actually managing: the **staleness window**, the interval between when the truth changes and when every cache reflects it. You are never eliminating it. You are sizing it, and deciding what happens to a read that lands inside it.

A cache is worth having only because reads dominate writes and the cost of a miss is high. The instant you cache, you accept that some reader will see an old value during the window. The engineering question is not "how do I avoid staleness" but "how small does the window need to be for this data, and how much load and complexity am I willing to pay to shrink it." A user's display name can be stale for minutes. A permission check usually cannot be stale at all. Those are not different caches; they are the same cache tuned to different window sizes.

This is the same instinct I keep returning to with DNS, where a record's [TTL is a deliberate staleness budget](/2026/02/18/dns-the-silent-killer-of-distributed-systems.html). A cache TTL is the same idea wearing different clothes.

## TTL Expiry: Simple, Bounded, and Wasteful on Purpose

The simplest invalidation strategy is to not invalidate at all. You attach a time-to-live to each entry and let it expire. After the TTL elapses, the next read misses, fetches fresh data, and repopulates.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">cache-aside with TTL · Redis</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#94a3b8;">def</span> <span style="color:#7dd3fc;">get_profile</span>(user_id):
    key = <span style="color:#a3e635;">f"profile:{user_id}"</span>
    cached = redis.get(key)
    <span style="color:#94a3b8;">if</span> cached <span style="color:#94a3b8;">is not</span> <span style="color:#f0abfc;">None</span>:
        <span style="color:#94a3b8;">return</span> cached            <span style="color:#64748b;"># hit: may be up to TTL seconds stale</span>

    fresh = db.load_profile(user_id)  <span style="color:#64748b;"># miss: read source of truth</span>
    redis.set(key, fresh, ex=<span style="color:#f0abfc;">300</span>)  <span style="color:#64748b;"># bounded staleness: at most 300s</span>
    <span style="color:#94a3b8;">return</span> fresh</code></pre>
</div>

What is attractive here is that **staleness is bounded and the system is self-healing**. You never have to find every cache that holds a copy of a value, because each copy expires on its own. There is no invalidation path to keep reliable, no message to deliver. If your purge infrastructure is broken, TTL still eventually converges. That property, convergence without coordination, is worth more than it looks.

The cost is the tradeoff between freshness and load, and it pulls in both directions. A short TTL means fresher data but more misses, which means more load on the source of truth: at the extreme, a one-second TTL on a hot key is barely a cache at all. A long TTL means a cheap origin but a wide staleness window. You are tuning a single knob that trades the thing you built the cache to protect (the origin) against the thing the cache promised (correctness).

There is also a failure mode TTL introduces on its own: synchronized expiry. If you populate ten thousand keys at the same instant with the same TTL, they all expire at the same instant, and the next moment is a stampede of misses hammering the origin together. The fix is **jittered TTLs**: add a small random spread so expirations smear across time instead of detonating at once.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="4" y1="21" x2="4" y2="14"/><line x1="4" y1="10" x2="4" y2="3"/><line x1="12" y1="21" x2="12" y2="12"/><line x1="12" y1="8" x2="12" y2="3"/><line x1="20" y1="21" x2="20" y2="16"/><line x1="20" y1="12" x2="20" y2="3"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">jittered TTL to avoid synchronized expiry</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#94a3b8;">import</span> random

base = <span style="color:#f0abfc;">300</span>
jitter = random.randint(<span style="color:#f0abfc;">0</span>, <span style="color:#f0abfc;">60</span>)   <span style="color:#64748b;"># spread expiry across a 60s band</span>
redis.set(key, fresh, ex=base + jitter)

<span style="color:#64748b;"># 10k keys now expire over a minute, not all in one tick,</span>
<span style="color:#64748b;"># so the origin sees a trickle of misses, not a thundering herd</span></code></pre>
</div>

## Event-Driven Invalidation: Fresh, but You Own the Path

The other end of the spectrum is to invalidate the moment the truth changes. On a write, you actively remove or update the cached copy. Done right, the staleness window shrinks to the latency of the invalidation, often milliseconds, and you keep a high hit rate because entries live as long as they stay valid instead of expiring on a timer.

The catch is in the words "active" and "path." TTL needs nothing to be delivered. Event-driven invalidation needs a message to travel from the writer to every cache holding a copy, and **that path is now a part of your system you have to keep reliable**. If the purge is lost, dropped, or reordered, the entry stays stale with no timer to save you. Freshness has been traded for a dependency on delivery.

This is exactly the kind of silent failure mode I described in [why DNS load balancing is not enough](/2026/02/24/when-dns-load-balancing-is-not-enough.html): the happy path looks instant, and the gap only shows up when the invalidation that was supposed to fire quietly did not.

In practice nobody picks one end. The pattern that survives production is **short TTL plus purge as a backstop**: event-driven invalidation for fast convergence on the common case, and a modest TTL underneath so that any missed purge self-corrects within a bounded window. The purge gives you freshness; the TTL gives you a floor under your worst case when the purge fails.

## Write Strategies Decide Who Sees Stale Data

Where the cache sits relative to the write determines the staleness story before any invalidation logic runs. The four classic strategies are not interchangeable; each one moves the window to a different place.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2v20M2 12h20"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">four write strategies, in pseudocode</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># write-through: cache and db updated together, in band</span>
cache.set(key, value)
db.write(key, value)              <span style="color:#64748b;"># cache never trails the db</span>

<span style="color:#64748b;"># write-back: cache first, db flushed later (fast, risky)</span>
cache.set(key, value)
queue.enqueue_flush(key)          <span style="color:#64748b;"># db is stale until the flush lands</span>

<span style="color:#64748b;"># write-around: db only, cache left untouched on write</span>
db.write(key, value)             <span style="color:#64748b;"># cached copy is now stale until evicted</span>

<span style="color:#64748b;"># cache-aside: app reads through cache, writes invalidate it</span>
db.write(key, value)
cache.delete(key)                <span style="color:#64748b;"># next read repopulates from the db</span></code></pre>
</div>

**Write-through** keeps the cache and source of truth in lockstep on every write, so the cache never trails the database. The cost is write latency, you pay for two writes, and you cache data that may never be read again. **Write-back** writes the cache first and flushes to the database asynchronously: writes are fast, but now the *database* is the stale copy, and a crash before the flush loses data outright. **Write-around** skips the cache on writes and goes straight to the database, which is great for write-heavy data that is rarely re-read, but it leaves any existing cached copy stale until it expires or is evicted. **Cache-aside** is the workhorse: the application reads through the cache and, on a write, deletes the entry so the next read repopulates it. It is simple and robust, but it has a sharp edge in the distributed case that the next section is entirely about.

The point is that "what does a reader see during a write" has a different answer for each of these before you have invalidated anything. Choosing a write strategy is choosing where you are willing to let staleness live.

## Where It Breaks: The Distributed Problems

A single-process cache with a lock makes invalidation look easy. Distribute it and three problems appear that no amount of careful single-node reasoning prepares you for.

**Invalidation messages get lost or reordered.** Your purge travels over a network, often a pub/sub channel fanning out to many cache nodes. Networks drop and reorder. If a purge is lost, that node stays stale until its TTL backstop fires (you do have one, right). Worse, if two writes to the same key produce two purges that arrive out of order on a system that updates rather than deletes, a node can end up holding the older value. This is why **purge-by-delete is safer than purge-by-update** in a distributed cache: a delete is idempotent and order-insensitive, while an out-of-order update can resurrect stale data.

**Multi-region coherence.** Replicate caches across regions and the invalidation now has to cross a WAN with real latency and partition risk. A write in one region and a read in another are separated by the inter-region propagation delay, which is your staleness window whether you wanted one or not. You are usually forced to choose between paying cross-region invalidation latency on every write or accepting a per-region staleness window. There is no configuration that gives you both global freshness and cheap local reads.

**The race between a write and a concurrent cache fill.** This is the subtle one, and it bites cache-aside specifically. Consider the interleaving:

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#ef4444" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">stale set after delete (the cache-aside race)</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># Reader R (a miss) and Writer W race on the same key:</span>

R: cache miss, reads OLD value from db          <span style="color:#64748b;"># t0</span>
W: writes NEW value to db                        <span style="color:#64748b;"># t1</span>
W: cache.delete(key)                             <span style="color:#64748b;"># t2  cache is empty</span>
R: cache.set(key, OLD)                            <span style="color:#64748b;"># t3  stale set wins</span>

<span style="color:#64748b;"># Cache now holds OLD with no pending invalidation.</span>
<span style="color:#64748b;"># It stays wrong until the TTL backstop expires it.</span></code></pre>
</div>

The reader loaded the old value before the write, then wrote it into the cache *after* the writer's delete. The cache is now confidently serving stale data with nothing queued to fix it. This is not a hypothetical; it is a real and well-documented hazard of cache-aside under concurrency. Mitigations include short TTLs so the wrong value cannot persist, per-key versioning so a stale fill can be detected and rejected, or a brief delete-after-delay so a late fill gets wiped. None of them are free, which is the recurring theme of this whole topic. The same write-versus-concurrent-read hazard shows up in [how reverse proxies handle concurrent requests](/2026/03/09/concurrent-requests-reverse-proxy.html): the moment two operations on the same state interleave, ordering stops being a detail and becomes the design.

## The Pattern That Survives Production

After enough incidents, the strategy that holds up is rarely the clever one. It is a small stack of unglamorous defaults.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#22c55e" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">versioned keys: invalidate by changing the key</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># Embed a version in the key. A write bumps the version,</span>
<span style="color:#64748b;"># so old and new live under different keys and never collide.</span>

ver = redis.incr(<span style="color:#a3e635;">f"ver:profile:{user_id}"</span>)   <span style="color:#64748b;"># bump on write</span>
key = <span style="color:#a3e635;">f"profile:{user_id}:v{ver}"</span>

<span style="color:#64748b;"># Readers compute the same key from the current version.</span>
<span style="color:#64748b;"># A stale fill lands on an old key nobody reads -&gt; no race.</span>
<span style="color:#64748b;"># Old versions simply age out by TTL. No purge fan-out needed.</span></code></pre>
</div>

The durable recipe combines a few of these. Use **versioned keys** where you can, because changing the key sidesteps the stale-set race entirely: an old fill lands on a key no one will read again, and it ages out quietly. Use **short TTL plus purge as a backstop** so that fast convergence and self-healing both hold, and a lost invalidation costs you a bounded window rather than permanent wrongness. Use **jittered TTLs** so expiry never synchronizes into a stampede. And size every window deliberately, because, just like a [DNS TTL](/2026/02/18/dns-the-silent-killer-of-distributed-systems.html), it is a promise about how stale your readers may be, not an implementation detail.

None of this makes invalidation easy. It makes it honest. You stop pretending the cache is always correct and start stating, explicitly, how wrong it is allowed to be and for how long. That is the whole job.

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">A cache does not give you correctness for free. It lets you trade a precise, bounded amount of staleness for speed. Invalidation is just the part of the system where you write that trade down and make it true.</p>

---

*This builds on my earlier pieces on [It's Always DNS](/2026/02/18/dns-the-silent-killer-of-distributed-systems.html), [when DNS load balancing is not enough](/2026/02/24/when-dns-load-balancing-is-not-enough.html), and [how reverse proxies handle concurrent requests](/2026/03/09/concurrent-requests-reverse-proxy.html).*

*Tuning staleness windows or chasing a stale-cache bug across regions? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
