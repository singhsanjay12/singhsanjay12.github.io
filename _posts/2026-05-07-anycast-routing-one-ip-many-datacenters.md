---
title: "Anycast Routing: One IP, Many Datacenters, and the Catch"
description: "Anycast advertises the same IP from many locations and lets the internet route each client to the nearest one. It is the magic behind DNS roots, CDNs, and DDoS absorption, but BGP routes by topology, not latency or load, and a route change can move a client mid-connection."
date: 2026-05-07 12:00:00 +0000
categories: [Distributed Systems, Networking]
tags: [anycast, networking, load-balancing, dns, ddos, distributed-systems]
image:
  path: /assets/img/posts/anycast-routing/hero.svg
  alt: "One IP prefix advertised from several PoPs over BGP, with each client routed to the topologically nearest site and a dashed path showing a re-converged route moving a client"
---

There is a trick that feels like cheating the first time you understand it. You take a single IP address, announce it from datacenters on three continents at once, and the global routing system quietly delivers each user to whichever one is closest, with no DNS games, no client logic, and no central decision. That trick is **anycast**, and it is the reason `8.8.8.8` answers fast whether you are in Frankfurt or Sao Paulo, and the reason a CDN can present one address to the whole planet.

It looks like load balancing for free. It is not free. The bill comes due in a specific, easy-to-miss way: the network is deciding "nearest" using rules that have nothing to do with latency or load, and it can change its mind in the middle of your connection. This post is about how anycast actually works, the places where it is genuinely the right answer, and the catch that decides what you should and should not put behind an anycast IP.

## What Anycast Actually Is

Start with the names. **Unicast** is the default: one IP belongs to one machine, and packets sent to it go to that machine. **Anycast** breaks the one-to-one assumption. The same IP prefix is advertised into the global routing table from many separate locations, and the routing system treats them as equally valid destinations. A packet sent to that IP lands at whichever location the network considers closest, and **closest is decided by BGP**, the Border Gateway Protocol that stitches the internet's autonomous systems together.

The mechanism is almost anticlimactic. Each Point of Presence (PoP) runs a router that announces the same prefix over BGP. Every other network on the path picks the best route to that prefix using BGP's path selection, which mostly comes down to the shortest AS path and local routing policy. Different clients sit in different parts of the topology, so they get steered to different PoPs. Nobody coordinated this. The routing table did the load distribution as a side effect of doing its normal job.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">same prefix announced from three PoPs</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># PoP A (Frankfurt), PoP B (Singapore), PoP C (Virginia)</span>
<span style="color:#64748b;"># each router runs roughly this BGP announcement:</span>

router bgp <span style="color:#f0abfc;">64512</span>
  network <span style="color:#a3e635;">203.0.113.0/24</span>      <span style="color:#64748b;"># the SAME prefix, from every site</span>

<span style="color:#64748b;"># A client in Europe sees the shortest AS path to PoP A.</span>
<span style="color:#64748b;"># A client in the US sees the shortest AS path to PoP C.</span>
<span style="color:#64748b;"># No DNS lookup chose this. BGP did.</span></code></pre>
</div>

That last comment is the whole point. Anycast does its steering at the routing layer, below DNS, below your application, below anything you control at request time.

## Where Anycast Earns Its Keep

Anycast is not a niche trick. The most load-bearing pieces of the internet run on it, and they share a profile.

**DNS, especially the roots and big resolvers.** The 13 root server "identities" are each anycast to hundreds of physical sites. A DNS query is a single UDP packet with a single response: stateless, tiny, and over before any route could change. This is anycast's perfect workload. The client never needs the same server twice in a row, so it never matters that the next packet might land somewhere else.

**CDN edges and low-latency entry points.** A CDN wants every user to hit a nearby edge node, and it wants to add or remove edges without renumbering anything. Anycast gives both: one address, and the network handles proximity. I touched on the proximity problem from the DNS side in [DNS the silent killer of distributed systems](/2026/02/18/dns-the-silent-killer-of-distributed-systems.html); anycast is the layer that solves it without asking the client to resolve a per-region name.

**DDoS absorption.** This is the property people underrate. With unicast, an attack flood converges on one machine. With anycast, the attack traffic is geographically distributed for free: a botnet in Asia hits the Singapore PoP, a botnet in North America hits the Virginia PoP, and no single site absorbs the whole storm. The same routing that spreads legitimate users spreads attackers, which turns a global PoP footprint into a global scrubbing surface. You are no longer defending one front door, you are defending the nearest door to each attacker.

The thread connecting all three: **short, ideally stateless interactions where each request stands alone.** That is exactly where the catch does not bite.

## The Catch: BGP Does Not Care About Latency or Load

Here is the hidden assumption that burns people. We say anycast routes users to the "nearest" PoP, and we picture nearest as lowest latency. **BGP does not measure latency, and it does not measure load.** It measures topology: AS path length and routing policy. Those correlate with latency only loosely.

So you get failures that feel impossible. A user in one city is routed across an ocean because that is the shorter AS path through their transit provider, even though a closer PoP exists in network-distance terms but not in policy terms. Or one PoP is at 90 percent capacity while a sibling sits idle, and anycast keeps shoveling new connections at the busy one because, topologically, nothing changed. Anycast distributes by geography of the network graph, not by how loaded each site is. It is load distribution that is blind to load.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">what BGP sees vs what you wanted</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># You wanted:   route by latency and by current load</span>
<span style="color:#64748b;"># BGP gives:    route by AS_PATH length and routing policy</span>

client -&gt; transit X -&gt; transit Y -&gt; PoP C   <span style="color:#64748b;"># AS_PATH len 3, chosen</span>
client -&gt; transit X -&gt; PoP A                 <span style="color:#64748b;"># nearer in ms, NOT chosen</span>

<span style="color:#64748b;"># Result: a closer, idle PoP can be ignored in favor of a</span>
<span style="color:#64748b;"># farther, busier one, purely on path length.</span></code></pre>
</div>

But the sharper version of the catch is not about which PoP you land on. It is about staying there.

## Re-convergence: When the Network Moves You Mid-Connection

BGP is not static. Links flap, a PoP drains, an operator changes policy, a transit provider re-routes. When the routing table re-converges, the best path to your anycast prefix can change. For a stateless DNS packet, that is a non-event: the next packet just goes somewhere else and gets the same answer. For anything with state, it is a quiet disaster.

Consider a long TCP connection: a large download, a streaming response, a websocket, a TLS session resumed across requests. The connection's state (sequence numbers, the TLS session, your application's notion of "this user is logged in") lives **only on the PoP you originally landed on**. If re-convergence moves your packets to a different PoP mid-flight, that new PoP has never heard of your connection. It has no matching socket, no TLS state, no session. It sends a reset, and your connection dies. Nothing was overloaded, nothing crashed: the network simply pointed you at a stranger.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="22" y1="2" x2="11" y2="13"/><polygon points="22 2 15 22 11 13 2 9 22 2"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">a long-lived connection meets a route change</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">t0  client -&gt; PoP C   SYN, TLS handshake, GET /big-file   <span style="color:#64748b;"># state lives on C</span>
t1  client -&gt; PoP C   streaming bytes 0..40MB           <span style="color:#64748b;"># fine</span>

    <span style="color:#a3e635;">[ BGP re-converges: best path now points at PoP A ]</span>

t2  client -&gt; PoP A   ACK for byte 40MB
t3  PoP A   -&gt; client RST    <span style="color:#64748b;"># A has no socket for this flow, connection dies</span></code></pre>
</div>

This is why anycast and long-lived state are an uneasy pair. The protocol that makes anycast magical for DNS is the same protocol that can yank a download out from under you. In practice these events are rare on stable backbones, but "rare" is not "never," and at scale rare events happen to someone constantly.

## Mitigations: Use Anycast for What It Is Good At

The fix is not to abandon anycast. It is to put the right things behind it and route the rest elsewhere.

**Keep anycast for stateless or short interactions.** DNS, a TLS handshake, an HTTP redirect, a health probe, the first hop that hands you off: anything that completes inside one or a few packets is safe, because a route change between requests costs you nothing. This is the single most important rule, and it is why the canonical anycast workloads are the ones they are.

**Use anycast to find a unicast node, then pin there.** A common and robust pattern: the anycast IP serves only the entry point, and its job is to hand the client a unicast address (or a region-specific hostname) to use for the actual stateful session. The long download or websocket then runs over unicast, immune to re-convergence, while anycast did the proximity selection up front. You get anycast's "find the nearest door" without anycast holding your long-lived connection.

**Drain PoPs gracefully.** Most re-convergence you cause yourself, during deploys and maintenance. Instead of yanking a prefix announcement (which moves every in-flight connection at once), stop attracting new traffic first and let existing connections finish. You do this by making the PoP's route less attractive, commonly by prepending your own AS to the announcement so the path looks longer, then withdrawing only after connections drain.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">draining a PoP without snapping connections</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># Step 1: make this PoP less preferred (longer path), do NOT withdraw yet</span>
route-map DRAIN permit <span style="color:#f0abfc;">10</span>
  set as-path prepend <span style="color:#f0abfc;">64512 64512 64512</span>   <span style="color:#64748b;"># now a longer AS_PATH than siblings</span>

<span style="color:#64748b;"># Step 2: new clients shift to other PoPs; existing flows keep running here</span>
<span style="color:#64748b;"># Step 3: once in-flight connections finish, withdraw the prefix</span></code></pre>
</div>

**Add stickiness where state must live behind anycast.** If you truly must keep stateful sessions on anycast, you lean on the relative stability of the backbone and on session affinity inside each PoP, but you accept that a topology change is an unhandled edge. The honest engineering answer is usually the unicast-handoff pattern above, not heroics to make TCP survive a route change.

## How Anycast Composes With the Rest of Your Load Balancing

The mistake is to see anycast as a replacement for your other load balancing. It is not. It is a layer, and a coarse one.

Anycast picks a **PoP**. It does not pick a server inside that PoP, it does not know which backend is healthy, and it cannot do weighted, latency-aware, or least-connections decisions. All of that still happens after the packet arrives. Inside the PoP you run the real load balancer: a reverse proxy doing the connection management and per-request algorithms I covered in [how reverse proxies handle concurrent connections](/2026/03/09/concurrent-requests-reverse-proxy.html), choosing backends with the strategies from [load balancing algorithms](/2026/03/02/load-balancing-algorithms.html). Anycast got the user to the building; the proxy finds the right room.

It also composes with DNS rather than competing with it. DNS-based load balancing steers by handing out different addresses per query, with all the staleness and TTL problems that come with caching resolvers. Anycast steers by routing a single address. Many large systems use both: DNS to pick a service or a coarse region, anycast within that to reach the nearest PoP, and a proxy inside the PoP for the fine-grained choice. The boundary where DNS alone stops being enough is exactly the one I drew in [when DNS load balancing is not enough](/2026/02/24/when-dns-load-balancing-is-not-enough.html), and anycast lives just past it: a routing-layer tool that solves proximity and attack-spreading, while leaving health, weight, and session affinity to the layers above and below it.

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">Anycast does not balance load. It distributes by the shape of the network graph, and hands you proximity and DDoS spreading as a gift. Put stateless requests behind it, keep stateful sessions on unicast, and never forget the network can change its mind mid-connection.</p>

---

*This pairs with my earlier writing on [when DNS load balancing is not enough](/2026/02/24/when-dns-load-balancing-is-not-enough.html), [DNS the silent killer of distributed systems](/2026/02/18/dns-the-silent-killer-of-distributed-systems.html), and [load balancing algorithms](/2026/03/02/load-balancing-algorithms.html).*

*Designing anycast and proximity routing at scale, or debugging a connection that died for no reason? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
