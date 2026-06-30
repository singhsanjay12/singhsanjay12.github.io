---
title: "Consistent Hashing and Bounded Loads: Routing That Survives a Resize"
description: "Hashing a key to a server with mod N is fine until N changes, at which point almost every key moves and your cache empties. Here is how consistent hashing, virtual nodes, rendezvous hashing, and bounded loads fix the resize problem without creating a hot-shard one."
date: 2026-04-20 12:00:00 +0000
categories: [Distributed Systems, Load Balancing]
tags: [consistent-hashing, load-balancing, sharding, caching, distributed-systems]
image:
  path: /assets/img/posts/consistent-hashing/hero.svg
  alt: "A hash ring with server nodes and keys placed on a circle, each key routed clockwise to the next node, with virtual nodes spreading each server across the ring"
---

Most routing schemes work right up until the size of the fleet changes. You hash a request key to one of N servers, traffic balances evenly, the dashboards look great. Then you add a server, or one dies, and the routing layer reshuffles **almost every key at once.** For a stateless service that is a non-event. For a cache or a sharded store, where each key was supposed to live on a specific node, it is a stampede: cold caches, a thundering herd at the origin, and replicas suddenly serving the wrong slice of the keyspace.

The fix is a family of techniques that share one goal: **when the membership changes, move as few keys as possible.** This post walks through consistent hashing, the virtual-node trick that makes it usable, rendezvous hashing as a simpler cousin, and the bounded-load variant that keeps a popular key from melting a single node. It is the assignment-side companion to my earlier writing on [load balancing algorithms](/2026/03/02/load-balancing-algorithms.html), where the question was which healthy backend to pick; here the question is which backend *owns* a given key, and how to keep that answer stable.

## The Resize Catastrophe: Why `hash(key) % N` Betrays You

The obvious way to map a key to one of N servers is modulo arithmetic. Hash the key to an integer, take it mod N, and you have a server index. It is one line, it is uniform, and it is a trap.

The problem is that N is in the denominator. Change N and you change the result for nearly every key, not just the keys that "should" move to the new server.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">mod N resize, Python</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#94a3b8;">def</span> <span style="color:#7dd3fc;">server_for</span>(key, n):
    <span style="color:#94a3b8;">return</span> hash(key) % n

keys = [<span style="color:#a3e635;">f"user:{i}"</span> <span style="color:#94a3b8;">for</span> i <span style="color:#94a3b8;">in</span> range(<span style="color:#f0abfc;">100000</span>)]

before = {k: <span style="color:#7dd3fc;">server_for</span>(k, <span style="color:#f0abfc;">8</span>)  <span style="color:#94a3b8;">for</span> k <span style="color:#94a3b8;">in</span> keys}   <span style="color:#64748b;"># 8 servers</span>
after  = {k: <span style="color:#7dd3fc;">server_for</span>(k, <span style="color:#f0abfc;">9</span>)  <span style="color:#94a3b8;">for</span> k <span style="color:#94a3b8;">in</span> keys}   <span style="color:#64748b;"># add one, now 9</span>

moved = sum(<span style="color:#f0abfc;">1</span> <span style="color:#94a3b8;">for</span> k <span style="color:#94a3b8;">in</span> keys <span style="color:#94a3b8;">if</span> before[k] != after[k])
print(moved / len(keys))   <span style="color:#64748b;"># ~0.89: about 89% of keys changed server</span></code></pre>
</div>

Adding one server to a pool of eight should, ideally, move about one ninth of the keys (the share the new server takes over). Mod N moves close to **nine tenths** of them. Every cache that keyed on the old mapping is now a miss. Every shard that owned a range now answers for a different range, so reads land on the wrong node until everything reshuffles and refills. The math does not care that you only nudged the cluster by one machine: it is a global reassignment, and at scale it reads as an outage.

## The Ring: Place Keys and Nodes on a Circle

Consistent hashing breaks the dependence on N by giving every key a *fixed* position that does not move when the fleet changes. Imagine a circle of hash values, say 0 to 2^32 minus 1, wrapping around at the top. You hash each server to a point on that circle, and you hash each key to a point too. A key is owned by the **first server you reach going clockwise** from the key's position.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">consistent hash ring, Python</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#94a3b8;">import</span> bisect, hashlib

<span style="color:#94a3b8;">def</span> <span style="color:#7dd3fc;">h</span>(s):
    <span style="color:#94a3b8;">return</span> int(hashlib.md5(s.encode()).hexdigest(), <span style="color:#f0abfc;">16</span>)

ring, owner = [], {}                  <span style="color:#64748b;"># sorted positions, position -&gt; server</span>
<span style="color:#94a3b8;">for</span> srv <span style="color:#94a3b8;">in</span> [<span style="color:#a3e635;">"s0"</span>, <span style="color:#a3e635;">"s1"</span>, <span style="color:#a3e635;">"s2"</span>]:
    p = <span style="color:#7dd3fc;">h</span>(srv)
    bisect.insort(ring, p); owner[p] = srv

<span style="color:#94a3b8;">def</span> <span style="color:#7dd3fc;">lookup</span>(key):
    p = <span style="color:#7dd3fc;">h</span>(key)
    i = bisect.bisect(ring, p) % len(ring)   <span style="color:#64748b;"># next node clockwise, wrap at top</span>
    <span style="color:#94a3b8;">return</span> owner[ring[i]]</code></pre>
</div>

Now look at what happens on a resize. When a server is removed, only the keys that used to land on it slide forward to the *next* server clockwise. Every other key keeps its owner, because its position did not move and the node in front of it is still there. When a server is added, it inserts itself at one point on the ring and steals only the arc between itself and the previous node. The expected fraction of keys that move is **roughly 1 over N**, which is the theoretical minimum. That single property is why consistent hashing underpins so much distributed infrastructure: a resize stops being a global event and becomes a local one.

## Virtual Nodes: Smoothing a Lumpy Circle

The basic ring has a quiet flaw. With only a handful of servers hashed to random points, the arcs between them are uneven by chance. One server might own a tiny sliver of the circle while its neighbor owns a third of it. Hashing is uniform in expectation, not in any single small sample, so a three-node or five-node ring is frequently lopsided, and the lopsidedness shows up directly as load imbalance.

The fix is **virtual nodes** (also called vnodes or replicas). Instead of placing each server once, you place it many times, by hashing `server#0`, `server#1`, and so on up to a few hundred points each. Each physical server now owns many small arcs scattered around the circle rather than one large contiguous one.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">virtual nodes on the ring, Python</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">VNODES = <span style="color:#f0abfc;">200</span>                     <span style="color:#64748b;"># each server appears 200 times</span>

<span style="color:#94a3b8;">def</span> <span style="color:#7dd3fc;">add_server</span>(srv):
    <span style="color:#94a3b8;">for</span> i <span style="color:#94a3b8;">in</span> range(VNODES):
        p = <span style="color:#7dd3fc;">h</span>(<span style="color:#a3e635;">f"{srv}#{i}"</span>)    <span style="color:#64748b;"># 200 points scattered around the ring</span>
        bisect.insort(ring, p); owner[p] = srv

<span style="color:#64748b;"># More points per server =&gt; arcs average out =&gt; load variance shrinks.</span>
<span style="color:#64748b;"># Tradeoff: more points =&gt; larger ring =&gt; slightly slower lookup + more memory.</span></code></pre>
</div>

The law-of-large-numbers effect is the whole point: with two hundred slices per server, the per-server load lands within a few percent of even, and removing a server spreads its arcs across *all* the others rather than dumping its entire share onto a single unlucky neighbor. Virtual nodes also give you a clean knob for heterogeneous hardware: a machine with twice the capacity simply gets twice as many points on the ring, so it draws twice the keys. The cost is bookkeeping. More points mean a larger sorted structure, a slightly slower binary search per lookup, and more memory, so production systems tune the vnode count rather than maxing it out.

## Rendezvous Hashing: A Ring Without the Ring

Consistent hashing's ring is a data structure you have to build, sort, and keep in sync. **Rendezvous hashing** (also called highest-random-weight, or HRW) reaches the same goals with no ring at all. For a given key, you compute a score by hashing the key together with each server, and you pick the server with the highest score. That is the whole algorithm.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">rendezvous (HRW) hashing, Python</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#94a3b8;">def</span> <span style="color:#7dd3fc;">pick</span>(key, servers):
    <span style="color:#94a3b8;">return</span> max(servers, key=<span style="color:#94a3b8;">lambda</span> s: <span style="color:#7dd3fc;">h</span>(<span style="color:#a3e635;">f"{key}:{s}"</span>))

<span style="color:#64748b;"># Remove a server: only the keys whose top choice WAS that server</span>
<span style="color:#64748b;"># move; each re-picks its now-highest among the rest. Same minimal</span>
<span style="color:#64748b;"># churn as the ring, with zero ring to maintain.</span>
<span style="color:#94a3b8;">def</span> <span style="color:#7dd3fc;">pick_n</span>(key, servers, n):       <span style="color:#64748b;"># top-N for replicas: just take the n highest</span>
    <span style="color:#94a3b8;">return</span> sorted(servers, key=<span style="color:#94a3b8;">lambda</span> s: <span style="color:#7dd3fc;">h</span>(<span style="color:#a3e635;">f"{key}:{s}"</span>), reverse=<span style="color:#f0abfc;">True</span>)[:n]</code></pre>
</div>

Rendezvous gives you the same minimal-churn guarantee: when a server leaves, only the keys that ranked it first need a new home, and they each fall to their second choice, which is already well distributed. It is uniform without needing virtual nodes, because every key independently ranks every server. It also makes replica placement trivial: the top-N servers by score are your N replicas, with no extra structure. The tradeoff is lookup cost. A naive HRW lookup is O(N) in the number of servers, since you score them all, whereas a ring lookup is O(log V). For small to medium fleets that linear scan is cheap and often worth it for the simpler code and the free top-N; for very large fleets the ring's logarithmic lookup wins.

## The Hot-Key Problem Consistent Hashing Does Not Solve

Here is the assumption hiding inside everything above: that load is spread across *many* keys. Consistent hashing balances the **keyspace**, not the **traffic**. If one key is requested a thousand times more often than the rest (a celebrity's profile, a viral video's metadata, a single hot shard at the front of a feed), then whichever node owns that key absorbs all of its traffic, and no amount of virtual nodes helps. Vnodes smooth out how many *arcs* each server owns; they do nothing about one arc being incredibly popular.

This is the silent failure mode. Your ring looks perfectly balanced by key count, every server owns its fair slice, and yet one node is pinned at 100% CPU while its peers idle, because a handful of keys carry most of the requests. The same skew shows up in sticky-session routing when one client is far chattier than the others, and in sharded stores when one tenant is an order of magnitude bigger than the rest. Pure placement hashing has no concept of how busy a key is, so it cannot route around the imbalance it cannot see.

## Consistent Hashing with Bounded Loads

The fix is to add a feedback signal that the plain ring lacks: a **per-node load cap**. Consistent hashing with bounded loads (the scheme behind some of Google's and Vimeo's load balancers) keeps the ring exactly as before, but adds a rule at lookup time. Compute the cap as the average load times a small factor (say the mean times 1.25). When you route a key to its clockwise owner, check whether that node is already at its cap. If it is, **walk forward to the next node**, and the next, until you find one with room.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">bounded-load overflow, Python</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#94a3b8;">def</span> <span style="color:#7dd3fc;">route</span>(key, load, total_requests, n_servers):
    cap = (total_requests / n_servers) * <span style="color:#f0abfc;">1.25</span>   <span style="color:#64748b;"># mean load * factor</span>
    i = bisect.bisect(ring, <span style="color:#7dd3fc;">h</span>(key)) % len(ring)
    <span style="color:#94a3b8;">for</span> _ <span style="color:#94a3b8;">in</span> range(len(ring)):              <span style="color:#64748b;"># walk clockwise from the owner</span>
        srv = owner[ring[i]]
        <span style="color:#94a3b8;">if</span> load[srv] &lt; cap:                  <span style="color:#64748b;"># has headroom? take it</span>
            load[srv] += <span style="color:#f0abfc;">1</span>
            <span style="color:#94a3b8;">return</span> srv
        i = (i + <span style="color:#f0abfc;">1</span>) % len(ring)             <span style="color:#64748b;"># full: overflow to next node</span>
    <span style="color:#94a3b8;">raise</span> RuntimeError(<span style="color:#a3e635;">"all nodes at cap"</span>)        <span style="color:#64748b;"># cap too tight for current load</span></code></pre>
</div>

This buys you the best of both worlds. In the common case, every node sits under its cap and keys land exactly where the ring says, so you keep the minimal-churn and cache-affinity properties. Only when a node fills up does traffic spill to the next node, capping the damage a hot key (or a hot arc) can do to any single server. The factor is the dial: a value near 1.0 enforces near-perfect balance but spills aggressively and erodes cache locality, while a larger factor preserves locality and tolerates more imbalance. It is the same tension I keep returning to in [load balancing algorithms](/2026/03/02/load-balancing-algorithms.html): a static assignment is predictable but blind to real-time load, so the robust designs blend a stable mapping with a live signal that lets them react.

## Where This Shows Up in Production

Once you recognize the pattern, you see it everywhere there is state behind a name.

**Distributed caches.** Memcached client libraries and systems like Redis Cluster route keys with a consistent hash precisely so that adding or removing a cache node invalidates only its share of the keyspace, not the whole cache. The resize math from the top of this post is exactly the disaster they exist to avoid.

**Sharded data stores.** Dynamo-style systems (and their descendants like Cassandra) place both data and replicas on a hash ring, using vnodes to balance shards and rendezvous-style top-N selection to pick the replica set. A node joining or leaving streams only its neighboring ranges rather than reshuffling the cluster.

**Sticky session and connection routing.** When a proxy must send a given client to the same backend (for session affinity or local cache warmth), consistent hashing keeps that mapping stable across backend changes, and bounded loads keep one heavy client from overwhelming its assigned backend. This is the assignment layer underneath the discovery and health questions I covered in [service discovery in Kubernetes](/2026/06/30/service-discovery-in-kubernetes.html) and [DNS or a service registry](/2026/06/23/dns-vs-service-registry.html): once you know the healthy set of endpoints, consistent hashing decides which one owns each key, stably.

**Peer-to-peer and DHTs.** Chord, Kademlia, and other distributed hash tables are built directly on a hash ring (or its tree-shaped variants), routing keys to nodes by the same clockwise-successor logic, so a churning P2P network can locate data without a central directory.

The thread through all of these is the same hidden assumption made explicit: routing must survive a resize. A scheme that reshuffles everything when the fleet changes is fine for stateless work and quietly catastrophic for stateful work. Consistent hashing makes a resize local instead of global, virtual nodes and rendezvous make the local distribution even, and bounded loads keep a single popular key from undoing all of it. Pick the combination that matches your fleet size and your tolerance for imbalance, and a node coming or going stops being an incident.

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">Mod N spreads keys evenly until the day you change N, and then it moves all of them at once. Consistent hashing trades a little complexity for the one property that matters when state is on the line: a resize moves the few keys it must, and leaves the rest exactly where they were.</p>

---

*This pairs with my earlier writing on [load balancing algorithms](/2026/03/02/load-balancing-algorithms.html), [service discovery in Kubernetes](/2026/06/30/service-discovery-in-kubernetes.html), and [DNS or a service registry](/2026/06/23/dns-vs-service-registry.html).*

*Designing a sharding or caching layer that has to survive resizes and hot keys? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
