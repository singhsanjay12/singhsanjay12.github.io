---
title: "Why Your Autoscaler Is Always Late: HPA, KEDA, and Metric Lag"
description: "Autoscaling is a feedback control loop, and every loop has delay: scrape interval, sync period, averaging window, scheduling, image pull, and readiness. By the time you add capacity, the spike may be over. Here is where the lag hides and how to scale on a leading signal instead."
date: 2026-06-18 12:00:00 +0000
categories: [Distributed Systems, Kubernetes]
tags: [kubernetes, autoscaling, hpa, keda, scaling, distributed-systems]
image:
  path: /assets/img/posts/autoscaler-lag/hero.svg
  alt: "A traffic spike hitting a service while the autoscaling chain (metric scrape, HPA decision, pod schedule, readiness) lags behind, leaving a gap where requests are dropped before new capacity is ready"
---

There is a comforting story we tell about autoscaling: traffic goes up, the autoscaler notices, more pods appear, the system absorbs the load. It is a good story. It is also, at the moment that matters most, a lie. **The autoscaler is a feedback control loop, and every feedback loop has delay.** By the time your Horizontal Pod Autoscaler has observed the spike, decided to act, scheduled new pods, pulled images, and waited for readiness probes to pass, the burst that triggered it may already be over. You paid for the capacity, your users ate the latency, and the graph looks like the system "handled it" only because you are reading it after the fact.

This is the autoscaling version of a theme I keep returning to: the failure is not in the component, it is in the **time gap between observing reality and reacting to it**. The same gap shows up in [health checking](/2026/01/12/health-checks-client-vs-server-side-lb.html), where a backend is dead for several check intervals before anyone routes around it. Here it shows up as capacity that always arrives a little too late.

## Autoscaling Is a Control Loop, and Control Loops Lag

Start with the mental model that the HPA documentation buries: this is a closed control loop running on a timer. It does not react to events. It wakes up periodically, reads a metric, compares it to a target, and adjusts. Every stage between "load changed" and "new pod serving traffic" adds latency.

Walk the chain end to end:

- **Scrape interval.** The metrics pipeline (typically the metrics-server or a Prometheus adapter) samples pod metrics on an interval, often 15 to 60 seconds. Your spike is invisible until the next scrape.
- **HPA sync period.** The controller reconciles on its own loop, `--horizontal-pod-autoscaler-sync-period`, 15 seconds by default. It can only act on what the last scrape told it.
- **The averaging window.** Utilization is averaged across all ready pods, so a sharp spike on a few pods is diluted by the calm majority.
- **Scheduling time.** Once the HPA raises the replica count, the scheduler has to find a node with room.
- **Image pull and start.** A cold image on a fresh node can take tens of seconds to pull and start.
- **Readiness.** The pod does not receive traffic until its readiness probe passes, which by design includes a warm-up delay.

Add those up and "instant autoscaling" is routinely 60 to 120 seconds from spike to served traffic, on a good day. For a burst that lasts 30 seconds, the capacity shows up after the worst is over.

## HPA Basics and Why CPU Lags

The HPA computes a desired replica count from a strikingly simple formula. For a target utilization, it scales the current replicas by the ratio of current metric to target.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">the HPA scaling formula</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># desired replicas, rounded up</span>
desired = ceil( current * ( currentMetric / targetMetric ) )

<span style="color:#64748b;"># example: 4 pods at 90% CPU, target is 50%</span>
desired = ceil( <span style="color:#f0abfc;">4</span> * ( <span style="color:#f0abfc;">90</span> / <span style="color:#f0abfc;">50</span> ) ) = ceil(<span style="color:#f0abfc;">7.2</span>) = <span style="color:#a3e635;">8</span></code></pre>
</div>

The math is fine. The problem is the **choice of metric**. CPU utilization is a lagging signal: CPU only climbs after the work has already arrived and started competing for the core. For a bursty or IO-bound workload, this is doubly bad. A service that spends most of its time waiting on a database or a downstream call can be completely saturated on concurrency while its CPU sits at 30 percent, so a CPU-targeted HPA never scales it at all. You are measuring the wrong thing, late.

A typical CPU-based HPA looks innocent enough.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">hpa-cpu.yaml</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: { name: checkout, namespace: shop }
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: checkout }
  minReplicas: <span style="color:#f0abfc;">4</span>
  maxReplicas: <span style="color:#f0abfc;">40</span>
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: { type: Utilization, averageUtilization: <span style="color:#f0abfc;">50</span> }
<span style="color:#64748b;"># CPU is lagging and averaged: a 5s burst is diluted and arrives late</span></code></pre>
</div>

## KEDA and Scaling on the Queue, Not the Symptom

The fix for a lagging signal is to scale on a **leading** one: something that rises before your pods feel pain. For most asynchronous and event-driven systems, that signal is queue depth. If the backlog in Kafka or a message queue is growing, you need more consumers, full stop, and you knew it the instant the producer outran the consumer, long before CPU moved.

[KEDA](https://keda.sh/) (Kubernetes Event-Driven Autoscaling) exists for exactly this. It is an operator that drives an HPA from external event sources: queue length, stream lag, the rate of HTTP requests, a Prometheus query, dozens of scalers. You point it at the backlog and it scales on the cause rather than the symptom.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">keda-scaledobject.yaml</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: { name: order-worker, namespace: shop }
spec:
  scaleTargetRef: { name: order-worker }
  minReplicaCount: <span style="color:#f0abfc;">0</span>      <span style="color:#64748b;"># scale to zero when the queue is empty</span>
  maxReplicaCount: <span style="color:#f0abfc;">100</span>
  triggers:
    - type: kafka
      metadata:
        topic: orders
        consumerGroup: order-workers
        lagThreshold: <span style="color:#a3e635;">"50"</span>   <span style="color:#64748b;"># one pod per 50 messages of lag</span></code></pre>
</div>

KEDA's other headline feature is **scale to zero**: when the queue is empty, it removes every replica and you pay nothing. The catch is the mirror image of the lag problem. The first message after an idle period hits an empty deployment, and now the full cold-start chain (schedule, pull, start, ready) sits directly in that request's latency. **Scale to zero trades steady-state cost for tail latency on the first request.** It is excellent for batch and background work, and a trap for anything latency-sensitive without a warm pool kept aside.

## VPA, the Cluster Autoscaler, and Layered Lag

So far the lag has been one layer deep: scale pods on an existing node. Two other autoscalers change the picture, and one of them makes the lag dramatically worse.

**The Vertical Pod Autoscaler** adjusts the CPU and memory *requests* of a pod rather than the replica count. It is the right tool for a singleton that cannot be sharded, but note that, in its common mode, changing requests means recreating the pod, which is itself a disruption. VPA and HPA on the same CPU metric also fight each other, so they are not a free combination.

**The Cluster Autoscaler** is the one that hurts. When the HPA asks for more pods and no node has room, the new pods sit `Pending` until the cluster autoscaler notices, requests a node from the cloud provider, waits for it to boot and join, and only then can the scheduler place the pods. You have now stacked a second control loop on top of the first.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">the layered lag, worst case</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">spike            t+0s
metric scraped   t+0..15s    <span style="color:#64748b;"># wait for next sample</span>
hpa decides      t+15..30s   <span style="color:#64748b;"># wait for sync period</span>
pods Pending     t+30s       <span style="color:#64748b;"># no room on existing nodes</span>
node requested   t+30..60s   <span style="color:#64748b;"># cluster autoscaler reacts</span>
node Ready       t+60..150s  <span style="color:#64748b;"># cloud provisions and joins</span>
pods scheduled   t+150s      <span style="color:#64748b;"># scheduler places them</span>
image pulled     t+150..180s
pod Ready        t+180..210s <span style="color:#64748b;"># readiness probe passes -&gt; serving</span></code></pre>
</div>

Three minutes from spike to served traffic when you have to add nodes is not an exotic worst case. It is the ordinary case for a cluster running near capacity. Anyone who has lived through [the silent failure modes of distributed systems](/2026/02/18/dns-the-silent-killer-of-distributed-systems.html) will recognize the shape: each layer is individually reasonable, and stacked together they produce a window where the system simply cannot keep up.

## Tactics for the Gap

You cannot remove the lag entirely, because the physics of scheduling and readiness are real. What you can do is shrink it, scale on better signals, and have a plan for the window that remains.

**Scale on a leading signal.** Prefer queue depth, in-flight requests, or RPS over CPU. These rise with the cause, not after the symptom. For request-driven services this means a custom or external metric (RPS per pod via the Prometheus adapter, or KEDA's HTTP and Prometheus scalers) rather than the default CPU target.

**Tune the stabilization windows deliberately.** The HPA's behavior block lets you scale up fast and scale down slow. A short scale-up window reacts to bursts; a long scale-down window prevents flapping when the burst passes.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">hpa behavior: up fast, down slow</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">  behavior:
    scaleUp:
      stabilizationWindowSeconds: <span style="color:#f0abfc;">0</span>     <span style="color:#64748b;"># react immediately to bursts</span>
      policies:
        - { type: Percent, value: <span style="color:#f0abfc;">100</span>, periodSeconds: <span style="color:#f0abfc;">15</span> }  <span style="color:#64748b;"># double per 15s</span>
    scaleDown:
      stabilizationWindowSeconds: <span style="color:#f0abfc;">300</span>   <span style="color:#64748b;"># wait 5m before shrinking</span></code></pre>
</div>

**Keep headroom and over-provision.** The cheapest way to beat node-provisioning lag is to never hit the node-provisioning path. Run low-priority "pause" pods that hold spare capacity and get evicted the instant a real pod needs the room, so the scheduler always has a warm node waiting. You are buying back the worst slice of that three-minute chain.

**Pre-scale for known patterns.** Most spikes are not surprises. A daily traffic curve, a marketing email, a scheduled batch job: scale on a cron or a calendar ahead of the event, not on the metric during it. The autoscaler is for the unexpected; the predictable load should already have capacity in place.

**Pair autoscaling with load shedding.** This is the one most teams skip, and it is the only thing that protects you *during* the gap. No matter how well tuned, there is a window where demand exceeds capacity and new pods are not ready yet. In that window you must shed: return a fast 429, drop the lowest-priority requests, and protect the requests you can actually serve. Autoscaling closes the gap over the next minute; load shedding keeps the service alive in the meantime. The two are partners, not alternatives. Which requests you shed and how you balance the survivors connects directly to the [load balancing algorithm](/2026/03/02/load-balancing-algorithms.html) sitting in front of them, and to the [health-aware routing](/2026/01/12/health-checks-client-vs-server-side-lb.html) that should already be steering traffic away from the pods still warming up.

It is worth remembering where those new pods even become reachable. A freshly scheduled replica is invisible until readiness gates it into the [service's live endpoint registry](/2026/06/30/service-discovery-in-kubernetes.html), which is the same readiness delay that sits at the tail of every lag calculation above. Capacity is not capacity until discovery and load balancing agree it can take traffic.

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">An autoscaler does not prevent overload. It recovers from one, on a delay you do not control. Design for the delay: scale on the cause, keep a node warm, and shed what you cannot yet serve.</p>

---

*This continues my writing on the time gaps inside distributed systems, alongside [health checking in client vs server-side load balancing](/2026/01/12/health-checks-client-vs-server-side-lb.html), [load balancing algorithms](/2026/03/02/load-balancing-algorithms.html), and [service discovery in Kubernetes](/2026/06/30/service-discovery-in-kubernetes.html).*

*Tuning autoscaling against real traffic and tired of capacity that arrives a minute late? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
