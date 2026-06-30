---
title: "HTTP/2 and HTTP/3 at the Proxy: Multiplexing, Head-of-Line, and QUIC"
description: "HTTP/2 multiplexes many streams over one TCP connection, but a single lost packet stalls all of them. HTTP/3 moves to QUIC over UDP to fix that, and in doing so it quietly rewrites how a reverse proxy manages connections, translates protocols, and load balances long-lived multiplexed traffic."
date: 2026-06-15 12:00:00 +0000
categories: [Distributed Systems, Reverse Proxy]
tags: [http2, http3, quic, reverse-proxy, performance, networking]
image:
  path: /assets/img/posts/http2-http3-proxy/hero.svg
  alt: "One TCP connection multiplexing HTTP/2 streams that all stall behind a lost packet, next to independent QUIC streams where only the affected stream waits"
---

Every major HTTP version exists to fix the head-of-line blocking that the previous version left behind. That is the thread running through HTTP/1.1, HTTP/2, and HTTP/3, and if you hold onto it, the whole evolution stops looking like a list of features and starts looking like one problem being chased down the stack: from the request layer, into the connection, and finally into the transport itself.

A reverse proxy sits exactly where this matters most. It terminates client connections, opens upstream connections, and translates between whatever the client speaks and whatever the backend speaks. Each new protocol version changes what "a connection" even means, and that quietly rewrites the proxy's job. Here is the progression, and what each step costs and saves at the proxy.

## HTTP/1.1: One Request per Connection, in Order

HTTP/1.1 is strictly serial on a single connection. You send a request, you wait for the full response, then you send the next. Keepalive lets you reuse the socket, but it does not let you overlap requests on it. The connection processes one request at a time, in order.

The protocol did define pipelining, where a client sends several requests without waiting for each response. In practice it was unusable: responses still had to come back in request order, so one slow response blocked every response queued behind it. This is **request-level head-of-line blocking**, and it is the original sin the next two versions are reacting to.

Browsers worked around it the only way they could: open more connections. Six parallel TCP connections per origin became the de facto standard, each one with its own congestion control ramp-up and its own TLS handshake. For a proxy, that meant six times the connection bookkeeping per client, and a thundering herd of short connections that never stayed warm long enough to be efficient. The waste was structural, not incidental.

## HTTP/2: Many Streams, One Connection, One Transport

HTTP/2 collapses those six connections back into one. Over a single TCP connection it multiplexes many independent **streams**, each carrying one request and response. The protocol frames everything: a request is a `HEADERS` frame plus `DATA` frames, each tagged with a stream ID, and frames from different streams are interleaved on the wire.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">HTTP/2 frames interleaved on one connection</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># a single TCP byte stream carrying three requests at once</span>
HEADERS  <span style="color:#a3e635;">stream 1</span>  GET /catalog
HEADERS  <span style="color:#a3e635;">stream 3</span>  GET /cart
DATA     <span style="color:#a3e635;">stream 1</span>  ...response bytes...
HEADERS  <span style="color:#a3e635;">stream 5</span>  GET /user
DATA     <span style="color:#a3e635;">stream 3</span>  ...response bytes...
DATA     <span style="color:#a3e635;">stream 1</span>  ...response bytes...   <span style="color:#64748b;"># streams interleave freely</span></code></pre>
</div>

This kills request-level head-of-line blocking. A slow response on stream 1 no longer blocks stream 3, because the framing layer lets the server send stream 3's bytes whenever they are ready. HTTP/2 adds header compression (HPACK), server push (since deprecated in practice), and stream priorities on top. For a proxy, the connection count drops dramatically: one client now needs one connection, not six, which is a large win for memory and file descriptors, the exact resources I argued matter most in [how reverse proxies handle concurrent connections at scale](/2026/03/09/concurrent-requests-reverse-proxy.html).

But HTTP/2 solved head-of-line blocking at the wrong layer, and the limitation it left behind is the whole reason HTTP/3 exists.

## The Hidden Assumption: TCP Delivers an Ordered Byte Stream

Here is the assumption baked into HTTP/2: it runs on TCP, and TCP guarantees a single, in-order byte stream. The kernel will not hand your application byte N+1 until it has delivered byte N. That guarantee is exactly what makes HTTP/2's multiplexing leaky.

When a packet is lost, TCP holds back every byte that arrives after the gap, on every stream, until the missing packet is retransmitted and fills the hole. The application sees nothing until the gap is closed. So even though stream 3's data has physically arrived in the receiver's buffer, the kernel will not release it, because it sits behind a missing segment that happened to belong to stream 1.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">TCP head-of-line blocking under loss</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># wire order of TCP segments (each carries frames for some stream)</span>
seg 10  stream 1  <span style="color:#22c55e;">delivered</span>
seg 11  stream 1  <span style="color:#ef4444;">LOST</span>
seg 12  stream 3  arrived in buffer ... but <span style="color:#ef4444;">held back</span>
seg 13  stream 3  arrived in buffer ... but <span style="color:#ef4444;">held back</span>

<span style="color:#64748b;"># TCP refuses to deliver seg 12+ until seg 11 is retransmitted,</span>
<span style="color:#64748b;"># even though stream 3 has nothing to do with the lost packet.</span></code></pre>
</div>

This is the cruel irony of HTTP/2: it removed head-of-line blocking at the HTTP layer and pushed it down into the transport, where the application cannot do anything about it. On a clean network you never notice. On a lossy mobile link, or any path with even 1 to 2 percent loss, a single connection multiplexing dozens of streams can stall all of them on one dropped packet. The more you multiplex, the more streams a single loss can freeze. You cannot fix this inside HTTP/2, because the ordering guarantee lives in the kernel's TCP stack, not in your protocol.

## HTTP/3 over QUIC: Move the Streams Below the Ordering Guarantee

HTTP/3's answer is to stop using TCP. It runs over **QUIC**, a transport built on UDP, where streams are a first-class transport concept rather than a framing trick layered on top of one ordered byte stream.

QUIC gives each stream its own independent delivery and ordering. The transport tracks loss and retransmission per stream, so a lost packet carrying stream 1's data only stalls stream 1. Stream 3's data is delivered to the application the moment it arrives, because QUIC knows it does not depend on the missing bytes. The head-of-line blocking that HTTP/2 pushed into TCP simply has nowhere to hide anymore: there is no single ordered byte stream to block.

QUIC bundles a few other things into the same protocol, and they matter at the proxy:

- **Encryption is built in.** QUIC integrates TLS 1.3 into the transport handshake. There is no separate TLS layer; the transport and crypto handshakes are combined, which is part of how it shaves round trips.
- **0-RTT resumption.** A client that has talked to the server before can send request data in the very first packet, using cached crypto state, instead of paying a full handshake round trip. This is a real latency win, with a real caveat: 0-RTT data is replayable, so it must only carry idempotent requests.
- **Connection migration.** A QUIC connection is identified by a connection ID, not by the four-tuple of source IP, source port, destination IP, destination port. So when a phone moves from Wi-Fi to cellular and its IP changes, the connection survives. With TCP, that IP change kills the connection and forces a fresh handshake.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">connection survives a network change</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># TCP: identity is the 4-tuple, so a new IP is a new connection</span>
wifi:    src 10.0.0.5:51000  -&gt;  proxy:443   <span style="color:#ef4444;">connection dies on IP change</span>

<span style="color:#64748b;"># QUIC: identity is the connection ID, so the IP can change underneath it</span>
wifi:    cid 0x8f3a... over 10.0.0.5    <span style="color:#22c55e;">same connection</span>
cellular:cid 0x8f3a... over 172.16.4.9 <span style="color:#22c55e;">same connection, no rehandshake</span></code></pre>
</div>

## What This Costs a Proxy: Connection Management and Protocol Translation

A reverse proxy rarely speaks one protocol end to end. The realistic deployment is HTTP/3 to the client at the edge and HTTP/2 or even HTTP/1.1 to the backends, because internal networks are clean and low-loss, and many backend stacks never adopted QUIC. So the proxy becomes a **protocol translator**: it terminates QUIC from the client, reassembles the HTTP semantics (method, headers, body), and re-emits them over a different transport upstream.

That translation is mostly clean because HTTP/2 and HTTP/3 share the same semantic model: streams, header fields, request and response. The proxy maps an inbound QUIC stream to an outbound HTTP/2 stream and shuttles bytes between them. The mismatch is in the failure modes, not the data model. A client stream reset over QUIC has to become a stream reset upstream; flow control windows on both sides have to be reconciled; and the trailers and pseudo-headers have to be translated faithfully. None of this is conceptually hard, but it is a lot of stateful bookkeeping that the proxy must hold per stream, on top of the per-connection state.

## The Hard Part: Load Balancing One Long-Lived Multiplexed Connection

Here is the load balancing problem that HTTP/2 and HTTP/3 quietly created, and it is the one most teams trip over.

In the HTTP/1.1 world, load balancing was easy because a connection carried one request. The proxy could route each request independently and spread load evenly across backends, which is the premise behind most of the [load balancing algorithms](/2026/03/02/load-balancing-algorithms.html) we reach for. With HTTP/2 and HTTP/3, one connection carries many requests for its entire long life. If the proxy pins that whole connection to a single backend, then every request on it goes to one backend, and your carefully chosen algorithm degenerates into balancing connections, not requests.

This is **h2 affinity**, and it shows up as lopsided backend load. A few large clients open a few long-lived connections, each pinned to one backend, and those backends run hot while others sit idle. The fix is to load balance at the **request** level, not the connection level: the proxy terminates the client's multiplexed connection, and for each inbound stream it picks a backend independently, fanning the streams from one client connection out across the whole pool.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">per-stream balancing, not per-connection</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#ef4444;"># WRONG: pin the whole connection (h2 affinity, lopsided load)</span>
client conn  ==&gt;  backend A   <span style="color:#64748b;"># every stream on this conn lands on A</span>

<span style="color:#22c55e;"># RIGHT: terminate, then route each stream on its own merits</span>
client conn  stream 1  -&gt;  backend A
             stream 3  -&gt;  backend C
             stream 5  -&gt;  backend B   <span style="color:#64748b;"># streams fanned across the pool</span></code></pre>
</div>

The catch is that per-stream routing means the proxy must fully terminate the client connection to see individual streams, which rules out cheap L4 pass-through. It also means the proxy maintains its own pool of upstream connections and decides, per stream, which warm upstream connection to reuse. The proxy stops being a connection relay and becomes a stream scheduler, and that is more work and more state than an L4 balancer ever carried.

## The QUIC Tax: CPU and UDP Are Not Free

QUIC is not a pure win at the proxy, and pretending otherwise leads to capacity surprises. TCP and TLS have decades of kernel and NIC optimization behind them: segmentation offload, checksum offload, and a receive path that hands the proxy a clean byte stream. QUIC lives in user space, on top of UDP, and it pays for that.

Every QUIC packet is processed in user space, including loss detection, acknowledgement, congestion control, and per-stream reassembly: work the TCP stack does in the kernel for free. Encryption is per packet rather than per TLS record, and UDP historically lacked the offload paths that TCP enjoys (though `UDP_SEGMENT` / generic segmentation offload have closed part of the gap). The practical result is that a proxy terminating QUIC commonly burns noticeably more CPU per byte than the same proxy terminating TCP plus TLS. At fleet scale that is a real capacity line item, not a rounding error.

There is also a deployment friction point: UDP. Plenty of middleboxes, firewalls, and older load balancer tiers treat UDP as suspicious or simply do not handle it well, and some networks rate-limit or block UDP/443 outright. A robust HTTP/3 edge therefore advertises HTTP/3 via the `Alt-Svc` header but keeps a TCP-based HTTP/2 path as a fallback, so clients on hostile networks degrade gracefully instead of failing. You do not get to drop TCP; you get to add QUIC alongside it.

## Choosing What to Terminate Where

The decision is not "which protocol is best." It is where each protocol earns its cost.

**Speak HTTP/3 at the edge**, facing real clients on real networks, where loss and connection migration actually happen. Mobile users on lossy links are exactly the population that suffers from TCP head-of-line blocking and benefits from QUIC's per-stream independence, 0-RTT, and survival across a Wi-Fi-to-cellular handoff. The CPU cost is worth it where the network is hostile.

**Speak HTTP/2 to your backends**, on the clean low-loss internal network where TCP head-of-line blocking is rare and the QUIC CPU tax buys you almost nothing. Let the proxy translate, terminate QUIC at the edge, and carry semantics inward over a transport your backends already speak well.

And whatever you terminate, **balance at the stream, not the connection**, or the multiplexing that made HTTP/2 and HTTP/3 efficient will quietly concentrate your load on a handful of unlucky backends. The protocol moved head-of-line blocking out of your way; do not let your load balancer put a new bottleneck back in.

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">Each HTTP version chased head-of-line blocking one layer deeper: out of the request queue, out of the connection, and finally out of the transport. HTTP/3 won that chase, but it handed the proxy a new job: terminate QUIC, translate it inward, and schedule streams instead of relaying connections.</p>

---

*This builds on my earlier writing on [how reverse proxies handle concurrent connections at scale](/2026/03/09/concurrent-requests-reverse-proxy.html) and [load balancing algorithms](/2026/03/02/load-balancing-algorithms.html), where the per-stream-versus-per-connection question first comes up.*

*Working through HTTP/3 rollout or QUIC capacity at the edge? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
