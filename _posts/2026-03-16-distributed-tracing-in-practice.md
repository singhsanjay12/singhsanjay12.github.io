---
title: "Distributed Tracing in Practice: Context Propagation, Sampling, and Its Cost"
description: "Logs say a service is slow; metrics say how slow. Tracing says where, in a fan-out across services, the time actually went. Here is how context propagation, head vs tail sampling, and OpenTelemetry fit together, and what each one costs."
date: 2026-03-16 12:00:00 +0000
categories: [Distributed Systems, Observability]
tags: [observability, distributed-tracing, opentelemetry, sampling, distributed-systems, performance]
image:
  path: /assets/img/posts/distributed-tracing/hero.svg
  alt: "A single trace drawn as a waterfall of parent and child spans across api-gateway, orders, inventory, payments, and a slow ledger service, with one W3C traceparent header propagated from hop to hop"
---

A user reports that checkout is slow. Your dashboard agrees: the p99 of `POST /checkout` jumped from 120ms to 1.4s. Logs confirm it too, with a few hundred lines per request scattered across six services. None of that tells you the one thing you need: **of those 1.4 seconds, which hop ate them?** That is the question logs and metrics structurally cannot answer, and the question distributed tracing exists to answer.

The reason is simple. Logs and metrics are per-service. They tell you that a service is slow, in isolation. But a single user request is not served by one service; it fans out into a tree of calls, and the latency you care about is the sum over a path through that tree. To attribute time, you need a record that spans all of them and stays stitched together. That record is a trace.

## A Trace Is a Tree of Spans Tied by an ID

A **span** is one unit of work: a single operation in a single service, with a start time, a duration, a name, and some attributes. A **trace** is a tree of spans that all share one **trace ID**, linked by parent and child span IDs. The root span is the request at the edge. Every downstream call it triggers becomes a child span, and their children become grandchildren, and so on through the fan-out.

That structure is exactly what lets you draw the waterfall in the header image of this post: each span is a bar, positioned by when it started and how long it ran, nested under its parent. The moment you see it laid out, the slow hop is obvious in a way it never is in a wall of logs.

The data model is small enough to hold in your head:

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">one trace, flattened</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">trace_id=4bf92f35...e4736
  span A  api-gateway  POST /checkout       1402ms   parent=none
   span B  orders       place_order          1360ms   parent=A
    span C  inventory    reserve                42ms   parent=B
    span D  payments     charge                118ms   parent=B
     span E  ledger       write_entry         <span style="color:#a3e635;">1190ms</span>   parent=D  <span style="color:#64748b;"># the culprit</span></code></pre>
</div>

Span E is the answer. The gateway looked slow, but it was waiting on `orders`, which was waiting on `payments`, which was waiting on a ledger write that took 1.19 seconds. No single service's metrics would have pointed there; only the trace, by tying the spans together, lets you walk the critical path to its source.

## Context Propagation: The Part That Actually Breaks

Spans are easy. The hard part, the part that quietly fails in real systems, is making every service agree on which trace they belong to. That is **context propagation**: threading the trace ID and the current span ID through every hop, so the next service can attach its span as a child rather than starting a brand new orphan trace.

On HTTP, the standard carrier is the W3C `traceparent` header (older systems use B3 from Zipkin). It is a compact string: version, trace ID, the parent span ID, and a flags byte that carries the sampling decision.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">W3C traceparent header</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
              <span style="color:#64748b;">|  |                                |                |</span>
              <span style="color:#64748b;">version  trace_id (16 bytes)       parent_span_id   flags (01 = sampled)</span></code></pre>
</div>

The rule is unforgiving: **every hop must read the incoming context, create its span as a child of it, and inject the updated context outbound.** Miss one hop and the trace splits in two. The half upstream of the break has no idea the downstream work happened; the half downstream looks like a fresh request with no parent. Your waterfall develops a hole exactly where you most wanted to look.

Synchronous HTTP and gRPC are the easy case, because the headers ride along with the call. The places propagation silently dies are the boundaries where there is no obvious header to attach to:

- **Message queues and event streams.** When a service publishes to Kafka and a consumer picks it up later, there is no live request to carry the context. You have to inject `traceparent` into the message headers on produce and extract it on consume, by hand or with an instrumented client. Forget it, and every async consumer starts its own disconnected trace.
- **Thread pools and async runtimes.** Trace context usually lives in thread-local or task-local storage. Hand work to another thread or `await` across an executor boundary, and the context does not follow unless the runtime (or your instrumentation) explicitly copies it.
- **A service that strips unknown headers.** A proxy or framework that allowlists request headers will quietly drop `traceparent`, breaking propagation for everything behind it.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">propagating across a Kafka boundary</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># producer: inject context into message headers</span>
ctx = current_context()
headers = []
propagator.inject(headers, context=ctx)   <span style="color:#64748b;"># writes traceparent into headers</span>
producer.send(topic, value=payload, headers=headers)

<span style="color:#64748b;"># consumer: extract it back out, then start a child span</span>
ctx = propagator.extract(message.headers)
<span style="color:#94a3b8;">with</span> tracer.start_as_current_span(<span style="color:#a3e635;">"handle_order"</span>, context=ctx):
    handle(message)                       <span style="color:#64748b;"># span links to the original trace</span></code></pre>
</div>

This is why I treat propagation, not span creation, as the real engineering work in tracing. The architecture of your traffic, the proxies and queues and pools I have written about in the [proxy concurrency post](/2026/03/09/concurrent-requests-reverse-proxy.html), is exactly the set of boundaries where context has to survive. One service that drops the header, and a whole subtree goes dark.

## Sampling: You Cannot Keep Everything

Tracing is expensive at full fidelity. A high-traffic service handling 100k requests per second, each generating a dozen spans, produces over a million spans per second to serialize, ship, store, and index. Keeping all of it is rarely worth the cost, so you sample. The interesting question is not whether to sample but **when you decide**, because that choice trades cost against coverage.

**Head-based sampling** decides at the very start of the trace, at ingress, usually with a fixed probability like "keep 1%." The decision is encoded in the `traceparent` flags byte and propagated, so every service on the path honors the same call: either the whole trace is recorded or none of it is. This is cheap, stateless, and easy to reason about. Its fatal weakness is that the decision is made *before you know what happens*. The slow trace, the one that errored, the rare p99 outlier: head sampling keeps it only by luck, at the same 1% rate as the boring fast ones. The traces you most want to see are exactly the ones it most likely threw away.

**Tail-based sampling** flips the timing. Every service records its spans and ships them to a collector, which **buffers all the spans of a trace until the trace completes**, then decides whether to keep it based on what actually happened: keep it if any span errored, if total duration crossed a threshold, if a particular route is involved. Now you keep the interesting traces on purpose. The cost is real, though: the collector must hold every in-flight trace in memory long enough to assemble it, which means buffering, memory pressure, and the complication that all spans of one trace must reach the same collector instance (so you route by trace ID). You pay to transport and buffer everything, and only then drop the uninteresting majority.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">tail_sampling in the OTel collector</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">processors:
  tail_sampling:
    decision_wait: <span style="color:#f0abfc;">10s</span>          <span style="color:#64748b;"># buffer spans this long, then decide</span>
    policies:
      - name: errors
        type: status_code
        status_code: { status_codes: [ERROR] }   <span style="color:#64748b;"># keep every failed trace</span>
      - name: slow
        type: latency
        latency: { threshold_ms: <span style="color:#f0abfc;">500</span> }    <span style="color:#64748b;"># keep anything over 500ms</span>
      - name: baseline
        type: probabilistic
        probabilistic: { sampling_percentage: <span style="color:#f0abfc;">1</span> }  <span style="color:#64748b;"># 1% of the rest, for context</span></code></pre>
</div>

The honest framing is a cost-versus-coverage curve. Head sampling minimizes cost and accepts that you will miss rare events. Tail sampling maximizes coverage of the events that matter and accepts the collector's memory and routing cost. Many teams run a hybrid: a low head-sample baseline for "what does normal look like," plus tail rules that guarantee you keep every error and every slow trace. That hybrid is usually the right default.

## OpenTelemetry: The Vendor-Neutral Plumbing

For years, tracing meant picking a vendor and adopting their proprietary SDK, agent, and wire format. Switching vendors meant reinstrumenting everything. **OpenTelemetry (OTel)** ended that by standardizing the parts that should never have been proprietary: the data model, the SDKs in every major language, the propagation format (it speaks W3C `traceparent` natively), and **OTLP**, the wire protocol for shipping telemetry.

The piece that makes it operationally clean is the **collector**: a standalone process your services export to, which receives spans over OTLP, runs processors (batching, attribute scrubbing, and tail sampling, as above), and exports to one or more backends. Your application code talks only to the collector in a stable format. Swapping the storage backend, or adding a second one, becomes a collector config change rather than a fleet-wide reinstrumentation.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">telemetry flow</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">services  --(OTLP)--&gt;  collector  --&gt;  [ batch | scrub | tail_sample ]  --&gt;  backend(s)
   |                       |                                                    |
 SDK creates spans      buffers, decides what to keep                  store + query + waterfall UI</code></pre>
</div>

Instrumentation cost is the honest caveat. A lot of it is automatic: OTel ships instrumentation libraries for popular HTTP servers, gRPC, database drivers, and queue clients that create spans and propagate context with no code changes. But automatic instrumentation only sees the boundaries it knows about. The spans that explain *your* business logic (the expensive loop, the cache miss path, the third-party call) are manual: you start and end them, name them well, and attach the attributes you will later filter on. Tracing that has not been thought about produces a generic skeleton; tracing that pays off has had a human decide what is worth a span.

## Where Tracing Earns Its Keep: The Tail-Latency Hunt

This is where it all connects back to the problem that started the post. Tail latency is a fan-out problem: a request's p99 is dominated by the slowest hop on its critical path, and that slow hop is often invisible in aggregate metrics because it only shows up under a specific condition (a cold cache, a particular shard, a backend whose own health check just flapped, the kind of failure I dug into in [client vs server-side health checking](/2026/01/12/health-checks-client-vs-server-side-lb.html)).

Metrics tell you the p99 moved. They cannot tell you why, because by the time you aggregate, the per-request structure is gone. A trace keeps that structure. With tail sampling configured to retain slow traces, you pull up an actual 1.4s `/checkout` request, read down its critical path, and land on span E: a 1.19s ledger write. Now you have a hypothesis grounded in one real request, not a guess from a percentile.

That is the whole argument for tracing in one sentence. Metrics and logs tell you a service is slow; tracing is how you find, in a real fan-out, **the exact hop that made it slow**, which is the only place a fix can start. It is also why the discovery and routing layers matter so much: a request that gets routed to an unhealthy or distant backend, as in [service discovery in Kubernetes](/2026/06/30/service-discovery-in-kubernetes.html), shows up in a trace as a single span gone long, and the trace is what turns that vague "sometimes slow" into a specific, fixable cause.

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">Metrics tell you something is slow. Logs tell you what each service was doing. Only a trace tells you where, across the whole fan-out, the time actually went, and that is the only place a fix can begin.</p>

---

*This connects to my earlier writing on [how reverse proxies handle concurrent connections](/2026/03/09/concurrent-requests-reverse-proxy.html), [service discovery in Kubernetes](/2026/06/30/service-discovery-in-kubernetes.html), and [client vs server-side health checking](/2026/01/12/health-checks-client-vs-server-side-lb.html).*

*Chasing a p99 culprit across a fan-out, or wiring up propagation through a queue? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
