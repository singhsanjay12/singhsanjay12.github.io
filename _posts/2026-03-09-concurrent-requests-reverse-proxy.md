---
title: "How Reverse Proxies Handle Concurrent Connections at Scale: ATS, HAProxy, and Envoy"
description: "The bottleneck is not throughput — it is managing tens of thousands of simultaneous connections without blocking, without ballooning memory, and without dropping a request. Here is how ATS, HAProxy, and Envoy each solve that problem, and the tradeoffs each approach carries."
date: 2026-03-09 12:00:00 +0000
categories: [Distributed Systems, Reverse Proxy]
tags: [reverse-proxy, load-balancing, distributed-systems, haproxy, envoy, ats, concurrency]
image:
  path: /assets/img/posts/proxy-concurrency/hero.svg
  alt: "A reverse proxy managing thousands of simultaneous client connections, some active and some idle keepalive, forwarding to backends"
---

The first instinct when measuring proxy performance is throughput: requests per second, gigabits per second. That is the wrong place to start.

The real constraint at scale is **concurrent connection count**. A proxy in front of your entire service fleet holds thousands of open connections simultaneously — clients waiting for upstream data, upstream connections waiting for backends, keepalive connections sitting idle, WebSocket streams that have been open for hours. How the proxy manages all of that bookkeeping, without running out of memory, file descriptors, or CPU, determines whether requests at the tail of the latency distribution are served in milliseconds or seconds.

## The Thin Layer Constraint

A reverse proxy has a narrow job: receive bytes on one socket, enforce policy, forward bytes on another socket. "Enforce policy" covers a lot — TLS termination, header rewriting, authentication, rate limiting — but the core is moving bytes efficiently.

This creates what I call the thin layer constraint: **the proxy must consume the minimum resources necessary per connection, because it holds thousands of them simultaneously.** Every unnecessary byte allocated per connection, every lock acquired on the hot path, every avoidable system call — it multiplies by the connection count.

At 10,000 concurrent connections:

- 1 KB per-connection overhead = 10 MB total
- 10 KB per-connection overhead = 100 MB total
- 100 KB per-connection overhead = 1 GB total

A proxy that allocates generously because it is convenient survives normal traffic and falls apart during load spikes. Memory pressure starts evicting pages, the kernel starts swapping, latency climbs at the 99th percentile. The degradation looks like a capacity problem when it is an architecture problem.

## Thread-per-Connection: The Obvious Model That Does Not Scale

The simplest way to handle concurrent connections is a thread (or process) per connection. Apache HTTPd used this (prefork MPM), it is straightforward to reason about, and each connection gets isolated execution with no shared state to worry about. A blocking read waiting for a slow client just blocks that thread. Other connections continue on their own threads.

The problem is that threads are expensive.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">thread-per-connection — Python</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#94a3b8;">import</span> socket, threading

<span style="color:#94a3b8;">def</span> <span style="color:#7dd3fc;">handle</span>(conn):
    data = conn.recv(<span style="color:#f0abfc;">4096</span>)   <span style="color:#64748b;"># blocks here — thread is stuck until client sends</span>
    conn.sendall(data.upper())
    conn.close()

server = socket.socket()
server.bind((<span style="color:#a3e635;">'0.0.0.0'</span>, <span style="color:#f0abfc;">8080</span>))
server.listen()

<span style="color:#94a3b8;">while</span> <span style="color:#f0abfc;">True</span>:
    conn, _ = server.accept()
    threading.Thread(target=<span style="color:#7dd3fc;">handle</span>, args=(conn,)).start()
    <span style="color:#64748b;"># a new OS thread for every connection — 10,000 clients = 10,000 threads</span></code></pre>
</div>

A thread on Linux consumes roughly 8 MB of virtual memory for its default stack. Even with a tuned 512 KB stack, 10,000 connections requires 5 GB of stack space before any application work is done. The OS scheduler now manages 10,000 threads. Context switching between them — saving and restoring registers, TLB pressure, cache eviction — adds up. At high connection counts the scheduler overhead appears directly in latency measurements.

The C10K problem (serving 10,000 concurrent connections efficiently) was a real practical limit for this model in the late 1990s. The solution was not faster hardware. It was a different concurrency model.

![Thread-per-connection: each connection owns one thread, memory scales with N; event loop: one thread manages thousands via kernel I/O readiness notifications](/assets/img/posts/proxy-concurrency/thread-models.svg)

## The Event Loop: Separating Holding from Working

Most of the time, a connection is not doing anything. It is waiting — for the client to send the next byte, for the backend to respond, for a slow upstream to unblock. A thread blocked on a slow client is wasted capacity.

The event loop separates the concepts of holding a connection and doing work on it.

An event loop uses the OS's I/O readiness notification interface — `epoll` on Linux, `kqueue` on macOS and BSD — to monitor many file descriptors simultaneously with a single thread. The OS watches thousands of sockets. When one becomes readable (client sent data) or writable (backend acknowledged data), it notifies the event loop. The loop wakes up, does exactly the work that is ready, and returns to waiting.

No threads blocked on slow connections. No context switches between thousands of threads. One thread, one event loop, as many file descriptors as the OS allows. The `ulimit -n` setting, commonly raised to 65,535 or higher in production, is now the practical limit rather than thread memory.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">event loop — Python asyncio</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#94a3b8;">import</span> asyncio

<span style="color:#94a3b8;">async def</span> <span style="color:#7dd3fc;">handle</span>(reader, writer):
    data = <span style="color:#94a3b8;">await</span> reader.read(<span style="color:#f0abfc;">4096</span>)  <span style="color:#64748b;"># yields — other connections run while we wait</span>
    writer.write(data.upper())
    <span style="color:#94a3b8;">await</span> writer.drain()             <span style="color:#64748b;"># yields again while the kernel flushes the write</span>
    writer.close()

<span style="color:#94a3b8;">async def</span> <span style="color:#7dd3fc;">main</span>():
    server = <span style="color:#94a3b8;">await</span> asyncio.start_server(<span style="color:#7dd3fc;">handle</span>, <span style="color:#a3e635;">'0.0.0.0'</span>, <span style="color:#f0abfc;">8080</span>)
    <span style="color:#94a3b8;">async with</span> server:
        <span style="color:#94a3b8;">await</span> server.serve_forever()  <span style="color:#64748b;"># one thread, handles thousands of connections</span>

asyncio.run(<span style="color:#7dd3fc;">main</span>())</code></pre>
</div>

The tradeoff is programming model complexity. A blocking operation inside the event loop blocks the entire loop — every connection on that thread stalls. Everything must be written as non-blocking callbacks or coroutines. This is harder to write correctly and harder to debug than sequential threaded code.

Each proxy covered here takes this base model and makes different tradeoffs around it.

## Apache Traffic Server: Event Threads and the Continuation System

ATS does not use a single event loop. It uses a pool of event threads — one per CPU core by default, configured via `proxy.config.exec.thread.limit` — each running its own independent event loop.

When a new connection arrives, it lands at a dedicated accept thread and is dispatched round-robin to one of the ET_NET (event thread network) threads. That thread owns the connection for its lifetime. Connections do not migrate between threads.

![ATS accept thread dispatching connections round-robin to ET_NET event thread pool; each thread has its own event loop and continuation queue; blocking in a plugin stalls all connections on that thread](/assets/img/posts/proxy-concurrency/ats-arch.svg)

The programming model inside ATS is the **continuation system**. A continuation is a callback object with associated state: it says "when event X occurs, call this handler." Processing a request is a chain of continuations scheduled on the event thread. I/O completes, a continuation runs, schedules the next I/O operation, and the continuation is rescheduled when that I/O completes. The thread never waits; it always moves to the next ready event.

The consequence for plugin authors is significant. ATS plugins hook into the request pipeline by registering continuations. If a plugin's handler makes a blocking system call — a synchronous DNS lookup, a blocking HTTP request to an external service, a filesystem read — it blocks the entire ET_NET thread. Every connection on that thread stops making progress until the blocking call returns. This is not a theoretical concern; it is the most common cause of latency spikes in production ATS deployments.

**Where ATS is strong:** CDN-scale HTTP caching and forward proxying. The continuation model is purpose-built for cache hit/miss processing. The cache integration is deep — content storage, freshness evaluation, and origin fetching are all built into the continuation chain. Organizations running CDN edge nodes at billions of requests per day have done so on ATS for years. The TSAPI plugin interface lets you customize behavior at every stage of request processing.

**Where ATS struggles:** The continuation model has a steep learning curve, and the plugin isolation story is weak. A misbehaving plugin degrades the thread it runs on. Configuration is dense, and performance tuning requires understanding internal thread and event queue sizing. For general-purpose reverse proxy use cases outside of caching workloads, the operational complexity is hard to justify.

## HAProxy: Single-Process Discipline, Then Careful Parallelism

HAProxy's original design was a single-process, single-thread event loop. One process, one epoll loop, all connections. Everything the proxy did was handled in sequence within that event loop.

This sounds limiting, but it produced a proxy with extraordinary predictability. No shared state, no locks, no concurrent access problems to reason about. A single core running a tight epoll loop handles tens of thousands of connections with sub-millisecond median latency. The memory footprint was negligible: HAProxy's per-connection overhead has historically been in the low hundreds of bytes.

HAProxy added multi-threading in version 1.8 via the `nbthread` directive. The design stayed single-process. Multiple threads run inside that process, each with its own epoll loop.

![HAProxy: single process with shared accept socket via SO_REUSEPORT; nbthread workers each run an independent epoll loop; shared state protected by spinlocks](/assets/img/posts/proxy-concurrency/haproxy-arch.svg)

New connections are distributed using `SO_REUSEPORT` — a socket option that lets multiple threads call `accept()` on the same port, with the kernel distributing connections across them. This removes the accept bottleneck without a shared queue or mutex. Each thread then manages its connections independently.

Shared state — stick-tables, global request counters, server health information — is protected by per-object spinlocks rather than a global lock. The shared surface is small by design; HAProxy's data model has always minimized it.

Configuration is explicit:

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">haproxy.cfg</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">global
    nbthread auto          <span style="color:#64748b;"># one thread per available CPU core</span>

frontend http-in
    bind :80 thread all    <span style="color:#64748b;"># all threads accept on this frontend</span>
    bind :443 ssl crt /etc/ssl/certs/ thread 1-2  <span style="color:#64748b;"># pin TLS to threads 1-2</span></code></pre>
</div>

The `thread` directive on `bind` lines lets you pin frontends to specific thread subsets, giving traffic isolation between workloads on a single HAProxy instance without running separate processes.

Hot reload works through process replacement: `haproxy -sf $(cat /var/run/haproxy.pid)` starts a new process that takes over the listening sockets, while the old process drains its in-flight connections. No dropped requests, no configuration gap.

**Where HAProxy is strong:** Pure efficiency and predictable latency in L4 and L7 load balancing scenarios. For environments where memory budget is constrained (appliances, shared infrastructure), where configuration must be auditable and straightforward, or where the stick-table and ACL system's power is needed without external dependencies, HAProxy is the standard choice. Its runtime API (socket commands) supports dynamic configuration of server weights, server state, and ACLs without a reload.

**Where HAProxy struggles:** The threading model was added to a single-process design; at very high thread counts, spinlock contention on shared state can surface. Lua (the extension scripting language) runs on the event loop thread, so complex Lua logic adds latency to other connections on that thread. HAProxy is not designed for deep L7 programmability — complex request transformation logic that would be straightforward in Envoy's filter chain is awkward to express in HAProxy's ACL/action model.

## Envoy: Thread-per-Core with Complete Isolation

Envoy was designed for service mesh: a proxy running as a sidecar alongside every service instance in the fleet. That use case required properties none of the existing proxies optimized for — deep L7 programmability, dynamic reconfiguration without restarts, and a concurrency model that would not allow a bug in one connection's processing to affect any other connection.

The architecture is thread-per-core with a strict constraint: **worker threads share nothing by design.**

A listener thread accepts incoming connections and dispatches each to a worker thread via a consistent hash. From that moment, the connection belongs entirely to that worker: its TLS session, its upstream connection pool, the entire L7 filter chain executing its request. Workers do not communicate with each other for connection processing.

Each worker runs its own libevent-based event loop and holds its own copy of the proxy configuration — delivered as a snapshot via the xDS protocol. When the control plane pushes a configuration update (a new backend, a changed route, a rotated certificate), each worker receives and applies it independently. No coordination between workers, no global pause, no lock.

![Envoy listener thread dispatching to worker threads; each worker is completely isolated with its own event loop, connection pool, filter chain, and xDS config snapshot; no shared state between workers](/assets/img/posts/proxy-concurrency/envoy-arch.svg)

The filter chain model is the other defining feature. Every request passes through a configured sequence of L4 and L7 filters. Each filter can read and modify the request: JWT validation, header manipulation, rate limit checking, gRPC transcoding, circuit breaking. Filters are composable and independently configurable. The per-worker isolation means a filter's state is always thread-local — no locking required within the filter chain.

The xDS API is the interface between Envoy and its control plane (Istio, custom implementations, or static config with dynamic overrides). Adding a backend endpoint, changing a route's timeout, draining an instance before it is decommissioned — all are xDS updates pushed to each worker independently. This is the operational model that makes zero-downtime deployments at fleet scale tractable.

**Where Envoy is strong:** Complex L7 processing, service mesh sidecars, API gateways where routing rules change frequently, and environments with control-plane infrastructure. The filter chain model handles workloads that would require custom code in HAProxy or ATS. The xDS integration is the right tool when the proxy's configuration is driven programmatically rather than by static files.

**Where Envoy struggles:** Memory footprint is higher than HAProxy, primarily from per-worker state duplication — each worker holds its own upstream connection pool and config snapshot. The operational surface is larger: debugging a misconfigured filter chain is harder than reading a HAProxy ACL. Custom filters require C++ or WASM, a higher bar than Lua scripting. For straightforward L4/L7 load balancing without complex routing logic, Envoy's weight is harder to justify than HAProxy's.

## Robustness Under the Thin Layer

Being thin does not mean being fragile. Each model comes with specific mechanisms for maintaining service through failures.

**Graceful restart** is how all three proxies handle configuration updates and version upgrades without dropping connections. HAProxy's `-sf` flag passes file descriptors to the new process, which takes the listening sockets while the old process drains. ATS's traffic_manager handles restart sequencing. Envoy's hot-restart protocol passes sockets between old and new processes; the drain timer controls how long the old process waits for in-flight requests to complete. The common pattern — new process takes the port, old process finishes its work — is non-negotiable for a proxy in a live path.

**Circuit breaking** prevents backend failure from cascading into proxy resource exhaustion. When a backend is slow or failing, the proxy must stop sending it new connections before queues grow unbounded. Envoy's circuit breaker is per-cluster with configurable thresholds: maximum pending requests, active requests, retries, and connections. HAProxy uses `maxconn` per server with queue management and health-check-driven server state transitions. ATS manages this through origin server connection limiting and retry configuration. The implementation differs; the requirement is the same: a proxy that blindly queues connections to a failing backend eventually exhausts memory and takes itself down.

**Connection draining on backend removal** ensures in-flight requests complete when a backend exits the pool. HAProxy's "drain" server state stops new connections while allowing existing ones to finish. Envoy's endpoint discovery transitions endpoints through a draining state before removal. This is operationally critical for deployments — a rolling deployment that removes backends without draining will drop a predictable fraction of requests proportional to the ratio of removed capacity to total capacity.

## Choosing the Right Model

The three architectures are not interchangeable. Each is optimized for a specific problem space.

**Use ATS** when the workload is HTTP caching and forward proxying at CDN scale. If cache hit rates are high and the fast path (cache hit, no origin fetch) is the common case, ATS's continuation system is extremely efficient for it. The cache integration is the primary differentiator; if you need it, ATS is the right tool.

**Use HAProxy** when you need the lowest possible overhead and the most predictable latency for L4 or L7 load balancing. When configuration is managed as static files, when the stick-table ACL system covers your session affinity and rate limiting needs, or when you are operating on constrained hardware, HAProxy's single-process model is the right fit.

**Use Envoy** when the proxy needs to be programmatically configurable, when routing logic is complex and changing frequently, or when the proxy is operating as a sidecar in a service mesh. The xDS model and filter chain are purpose-built for control-plane-driven infrastructure. If the operational question is "how do I push a new routing rule without restarting anything?" the answer is Envoy.

The concurrency model is not incidental to these choices. ATS's continuation system is inseparable from its cache architecture. HAProxy's single-process model is what makes its ACL evaluation so cheap and its memory footprint so small. Envoy's worker isolation is what makes its filter chain safely extensible without inter-connection interference. The proxy you choose is a choice about which of these properties matters most for your traffic pattern.

---

*Working through proxy architecture decisions at scale? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
