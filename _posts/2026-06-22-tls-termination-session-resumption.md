---
title: "TLS Termination and Session Resumption at Scale: The Shared-Secret Problem"
description: "TLS handshakes cost round trips and CPU, and session resumption is supposed to skip them. But across a load-balanced fleet, resumption silently breaks unless every node shares and rotates the same ticket key. Here is why, and how to do it right."
date: 2026-06-22 12:00:00 +0000
categories: [Distributed Systems, Reverse Proxy]
tags: [tls, reverse-proxy, performance, session-resumption, security, networking]
image:
  path: /assets/img/posts/tls-termination/hero.svg
  alt: "A fleet of TLS-terminating reverse proxies sharing a rotating session-ticket key so resumption works across every node"
---

Most TLS performance work focuses on the wrong number. People tune cipher suites, argue about elliptic curves, and benchmark requests per second on a single warm connection. Meanwhile the actual cost that shows up in production latency graphs is the handshake itself: the round trips before any application data flows, and the asymmetric crypto the server burns to prove its identity.

The handshake is the tax you pay to open a connection. Session resumption is supposed to be the discount that lets returning clients skip most of it. But that discount has a hidden assumption baked in: that the server which resumes the session is the same server (or shares state with the server) that established it. Put a load balancer in front of a fleet, and that assumption quietly stops holding. Resumption appears to work, your config looks correct, and yet a large fraction of clients silently fall back to full handshakes. The graphs do not error. They just get slower.

## What a Handshake Actually Costs

A full TLS 1.2 handshake costs two round trips before the client can send its request: ClientHello, ServerHello with certificate, key exchange, Finished. On a connection with 80 ms of round-trip latency, that is 160 ms of pure waiting added to the first request, before your application does a single thing.

TLS 1.3 cut the full handshake to one round trip (1-RTT). That is a real improvement, but it does not make the handshake free. The other half of the cost is CPU: the server performs an asymmetric signature on every full handshake to prove it owns the certificate's private key. Asymmetric operations (RSA signing, ECDSA signing) are orders of magnitude more expensive than the symmetric crypto that protects the rest of the connection. At a few hundred handshakes per second per core, signing is the bottleneck, not throughput.

So the handshake hurts twice: latency from round trips, CPU from signatures. Resumption attacks both, by letting a returning client reuse a previously negotiated secret instead of running the full exchange again.

## Where You Terminate Changes Everything

Before resumption, decide where TLS ends. There are three common choices, and they are not interchangeable.

**Edge termination.** The proxy decrypts TLS, inspects and routes plaintext, then talks to backends over plain HTTP inside a trusted network. This is the cheapest model: backends do no crypto, the proxy is the single place certificates live, and L7 features (header routing, rate limiting, [connection management](/2026/03/09/concurrent-requests-reverse-proxy.html)) all work because the proxy can read the request.

**Passthrough.** The proxy forwards the encrypted bytes without decrypting, terminating TLS at the backend. The proxy cannot read or route on the request contents, only on the TCP connection and the SNI field in the ClientHello. You give up L7 routing entirely, but the proxy never holds the certificate's private key.

**Re-encrypt.** The proxy terminates the client's TLS, inspects the request, then opens a second TLS connection to the backend. You get L7 routing and encryption on the wire all the way to the backend. The cost is a second handshake per hop, which is exactly the cost this whole post is about, now doubled.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">nginx.conf · re-encrypt to backend</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">server {
    listen <span style="color:#f0abfc;">443</span> ssl;
    ssl_certificate     /etc/ssl/edge.crt;   <span style="color:#64748b;"># client-facing cert lives here</span>
    ssl_certificate_key /etc/ssl/edge.key;

    location / {
        proxy_pass https://backend_pool;     <span style="color:#64748b;"># second TLS hop to the backend</span>
        proxy_ssl_verify       on;            <span style="color:#64748b;"># validate the backend cert, do not trust blindly</span>
        proxy_ssl_trusted_certificate /etc/ssl/backend_ca.crt;
    }
}</code></pre>
</div>

The choice is a security and performance tradeoff, not a default. Edge termination is fastest and simplest but leaves the internal hop in plaintext. Passthrough keeps keys off the proxy but forfeits L7. Re-encrypt buys end-to-end encryption at the price of a second handshake. Whichever you pick, resumption is what keeps the handshake cost from dominating.

## Resumption: Session IDs and Session Tickets

There are two mechanisms to resume a prior session, and the difference between them is the entire point of this post.

**Session IDs** are server-side state. On a full handshake the server generates a session ID, caches the negotiated secret keyed by that ID, and hands the ID to the client. When the client returns, it presents the ID, the server looks up the cached secret, and both sides skip the expensive parts. The catch: the secret lives on the server. The server that established the session is the only one that can resume it, unless the cache is shared.

**Session tickets** invert this. Instead of the server holding the state, the server encrypts the session secret into an opaque blob (the ticket) using a key only the server knows, and hands the blob to the client. The client stores it. On return, the client presents the ticket, the server decrypts it with its ticket key, recovers the secret, and resumes. The server holds no per-session state at all. This is stateless resumption, and it is the model that scales, with one sharp condition attached.

## The Shared-Secret Problem Behind a Load Balancer

Here is where the silent failure mode lives.

With session IDs, resumption works only if the node that handles the resumption request has the cached secret. Behind a load balancer that spreads connections across many nodes (and most [balancing algorithms](/2026/03/02/load-balancing-algorithms.html) deliberately do), a returning client almost always lands on a different node than the one that established the session. That node has never seen the session ID. It cannot resume. It does a full handshake instead. Your session cache hit rate collapses as the fleet grows, and nobody notices because nothing errors.

Session tickets look like they fix this, because the state moves to the client. But they introduce a subtler version of the same trap: the ticket is encrypted with a key, and **every node in the fleet must hold the same ticket key.** If node A encrypted the ticket and the client's next request lands on node B with a different key, node B cannot decrypt the ticket. It silently falls back to a full handshake.

By default, many TLS servers generate a random ticket key at startup. That is the trap. Each node boots, invents its own key, and now resumption only works when a client happens to return to the same node it started on. The configuration is "correct" on every node in isolation. The fleet as a whole has near-zero resumption.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">nginx.conf · shared ticket key across the fleet</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">http {
    <span style="color:#64748b;"># every node loads the SAME key files, fetched from a shared secret store</span>
    <span style="color:#64748b;"># newest key first encrypts; older keys still decrypt in-flight tickets</span>
    ssl_session_ticket_key /etc/ssl/ticket/key.current;
    ssl_session_ticket_key /etc/ssl/ticket/key.prev;
    ssl_session_ticket_key /etc/ssl/ticket/key.prev2;

    ssl_session_tickets on;
    ssl_session_timeout  10m;   <span style="color:#64748b;"># resumption validity window</span>
}</code></pre>
</div>

The fix is to take the ticket key out of each node's hands. Generate it centrally, distribute it to every node, and load it from a shared location rather than letting each process invent its own. Now any node can decrypt any node's ticket, and resumption works no matter where the load balancer sends the client.

## Rotation Is Not Optional

A shared ticket key sounds like the end of the story. It is not, because a long-lived ticket key is a long-lived shared secret, and that is a problem on its own.

The ticket key protects forward secrecy for resumed sessions. If an attacker ever obtains the current ticket key, they can decrypt the session secrets inside any ticket encrypted with it. A key that never rotates means one compromise exposes a wide window of traffic. So the key has to rotate, frequently (hours, not months), and rotation across a fleet is its own coordination problem.

The mechanism that makes rotation safe is overlap. A node should encrypt new tickets with the newest key, but keep accepting tickets encrypted with the previous key or two, so that tickets issued just before a rotation still resume cleanly. You rotate by pushing a new "current" key to every node, demoting the old current to "previous," and retiring the oldest. Done right, no client ever sees a resumption failure during a rotation. Done wrong (push the new key to half the fleet, lag on the other half), you get a window where tickets from one half cannot be decrypted by the other, and resumption drops for as long as the fleet is inconsistent.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">ticket-key rotation · pseudocode</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># runs centrally, every few hours; all nodes read the same store</span>
new_key = generate_random_key(<span style="color:#f0abfc;">80</span>)        <span style="color:#64748b;"># 80 bytes for AES-256 ticket keys</span>

store.set(<span style="color:#a3e635;">"key.prev2"</span>, store.get(<span style="color:#a3e635;">"key.prev"</span>))
store.set(<span style="color:#a3e635;">"key.prev"</span>,  store.get(<span style="color:#a3e635;">"key.current"</span>))
store.set(<span style="color:#a3e635;">"key.current"</span>, new_key)         <span style="color:#64748b;"># newest key encrypts new tickets</span>

<span style="color:#94a3b8;">for</span> node <span style="color:#94a3b8;">in</span> fleet:
    node.reload_ticket_keys()              <span style="color:#64748b;"># overlap: old keys still decrypt -&gt; no resumption gap</span></code></pre>
</div>

This is the same coordination shape that shows up everywhere in distributed systems: a piece of shared state that every node must agree on, kept consistent as it changes. It is why this problem rhymes with [service discovery and the source of truth for backends](/2026/06/23/dns-vs-service-registry.html). The ticket key is just another value the fleet has to share and refresh in lockstep.

## TLS 1.3 0-RTT and the Replay Trap

TLS 1.3 added a faster path on top of resumption: 0-RTT, also called early data. A returning client can send application data in its very first flight, alongside the resumption attempt, before the handshake completes. Zero round trips of waiting. For latency-sensitive traffic this is the most aggressive optimization TLS offers.

It also carries a sharp edge. Early data is not protected against replay. An attacker who captures a 0-RTT request can resend it, and the server, having no handshake context yet, may process it again. For an idempotent GET that is harmless. For a request that moves money, mutates state, or charges a card, replay is a real attack. The rule is simple and non-negotiable: only ever allow 0-RTT for idempotent, side-effect-free requests, and reject early data for anything that mutates state. Treat early data as untrusted until the handshake completes.

## Identity at the Edge: mTLS and Offload

Termination is also where identity gets established. When the proxy does mutual TLS, the client presents its own certificate during the handshake, and the proxy validates it against a trusted CA before the request reaches any backend. That makes the [termination point the natural enforcement point for Zero Trust](/2025/08/03/zero-trust-with-reverse-proxy.html): device identity is proven cryptographically at the same place TLS ends, and resumption has to preserve that identity binding, not just the session keys.

The CPU cost of all this asymmetric work is real, which is why high-volume terminators offload it. Dedicated crypto accelerators (or AES-NI and modern CPU crypto extensions) handle the signing and bulk encryption far faster than general-purpose code. Offload does not change the architecture: you still terminate at the proxy, still resume with shared tickets, still rotate the key across the fleet. It just makes the full handshakes you could not avoid cheaper to absorb.

The throughline is that none of these pieces stands alone. Termination decides where keys and identity live. Resumption decides whether returning clients pay the handshake tax again. The ticket key decides whether resumption survives a load balancer. And rotation decides whether that shared key is a convenience or a liability. Get the shared-secret problem wrong and everything upstream looks healthy while your latency quietly climbs.

<p style="border-left:4px solid #6366f1;padding:12px 20px;margin:2em 0;font-family:Georgia,'Times New Roman',serif;font-style:italic;font-size:17px;color:#334155;background:#f8fafc;">The handshake is the tax you pay to open a connection. Session resumption is the rebate, but only the fleet that shares and rotates one ticket key actually gets to claim it.</p>

---

*Working through TLS termination, resumption, or traffic security at scale? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
