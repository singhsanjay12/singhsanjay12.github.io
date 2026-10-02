---
title: "Connection Draining and the Myth of the Zero-Downtime Deploy"
description: "A rolling deploy is not zero-downtime by default. Without draining, every pod you terminate drops in-flight requests and races endpoint propagation. Here is the SIGTERM contract, the preStop hook, the readiness-before-exit ordering, and how proxies drain long-lived connections."
date: 2026-04-27 12:00:00 +0000
categories: [Distributed Systems, Reverse Proxy]
tags: [deployments, connection-draining, graceful-shutdown, kubernetes, reliability, reverse-proxy]
image:
  path: /assets/img/posts/connection-draining/hero.svg
  alt: "A pod going NotReady leaves the EndpointSlice and stops receiving new traffic while its in-flight requests drain to completion before the process exits"
---

Every team I have worked with believes their rolling deploy is zero-downtime. Most of them are wrong, and the dashboards agree with them only because the error budget is large enough to hide it. The truth is uncomfortable: **a rolling deploy is not zero-downtime by default. It is zero-downtime only if you drain, and draining is a contract with several parties who all have to keep their side of it.** When one party moves early, requests die in the gap.

This is the operational counterpart to two things I have written about before: how a reverse proxy [holds thousands of concurrent connections](/2026/03/09/concurrent-requests-reverse-proxy.html) without dropping them, and how [Kubernetes keeps a live registry of healthy endpoints](/2026/06/30/service-discovery-in-kubernetes.html) behind a stable name. Draining is what happens at the seam between those two systems during a deploy, and it is where the silent failures live.

## The Silent Failure Mode of a Rolling Deploy

A rolling deploy replaces pods a few at a time. The deployment controller picks a pod, tells it to stop, and starts a fresh one. Simple. The hidden assumption is that "tells it to stop" and "stops receiving traffic" happen in the right order. They usually do not.

Picture the sequence the naive way. The controller decides to terminate pod A. At more or less the same instant, two independent things start: the kubelet sends the process a signal to shut down, and the control plane begins removing pod A from the **EndpointSlice** so load balancers stop routing to it. These two events are not synchronized. If the process reacts to the signal and closes its listener before the load balancer has noticed the endpoint is gone, every request the load balancer sends in that window hits a closed socket. The client sees a connection refused or a reset.

The failure is proportional and quiet. If you remove 1 of 10 pods without draining, you drop roughly the requests in flight to that pod during the gap: a small fraction, easily lost in noise. Run that across a 200-pod deployment, ten pods at a time, several times a day, and you are shipping a steady drip of 502s that looks like "the network is flaky" rather than "our deploy drops requests on purpose."

## The SIGTERM Contract

Kubernetes terminates a pod by sending the main process a `SIGTERM`, then waiting `terminationGracePeriodSeconds` (default 30) before escalating to `SIGKILL`. That window is the entire budget you have to shut down cleanly. The contract is simple to state and easy to break: **on SIGTERM, stop accepting new work, finish the work you already accepted, then exit.** Most server frameworks do not do this out of the box; they either ignore SIGTERM (and get killed mid-request 30 seconds later) or exit immediately (and drop everything in flight).

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">graceful shutdown on SIGTERM · Go</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">srv := <span style="color:#7dd3fc;">http.Server</span>{Addr: <span style="color:#a3e635;">":8080"</span>}

<span style="color:#94a3b8;">go</span> srv.ListenAndServe()

sig := <span style="color:#7dd3fc;">make</span>(<span style="color:#94a3b8;">chan</span> os.Signal, <span style="color:#f0abfc;">1</span>)
signal.Notify(sig, syscall.SIGTERM)
<span style="color:#94a3b8;">&lt;-</span>sig                                  <span style="color:#64748b;"># block until Kubernetes asks us to stop</span>

<span style="color:#64748b;"># Stop accepting new connections, let in-flight requests finish.</span>
ctx, cancel := context.WithTimeout(context.Background(), <span style="color:#f0abfc;">25</span>*time.Second)
<span style="color:#94a3b8;">defer</span> cancel()
srv.Shutdown(ctx)                       <span style="color:#64748b;"># drains, then returns when idle or ctx expires</span></code></pre>
</div>

Notice the 25-second drain budget sits comfortably inside the 30-second grace period. That margin is deliberate: if your drain timer equals or exceeds the grace period, `SIGKILL` arrives mid-drain and you are back to dropping requests. The grace period must always be larger than the longest request you are willing to wait for, plus the time it takes the rest of the system to stop routing to you.

## Readiness Must Flip Before the Process Exits

Here is the ordering that actually matters, and the part people get backwards. The process exiting is the **last** thing that should happen, not the first. Before a single connection is closed, the pod must leave the load balancer's view. In Kubernetes terms, the pod's readiness has to flip to `NotReady` so the control plane pulls it from the EndpointSlice, and that removal has to propagate to every component that routes traffic: kube-proxy on every node, every ingress controller, every Envoy sidecar holding an xDS snapshot.

This is the same readiness gate I described in [client-side vs server-side health checking](/2026/01/12/health-checks-client-vs-server-side-lb.html): a pod is only in the pool while its readiness probe passes, and it is pulled the moment that probe fails. A graceful shutdown weaponizes that gate on purpose. The correct order is:

1. Receive the shutdown intent.
2. Fail readiness so the control plane removes you from the EndpointSlice.
3. Wait long enough for that removal to propagate to all routers.
4. Only now stop accepting new connections and drain the in-flight ones.
5. Exit.

The problem is that Kubernetes does not give you step 2 and step 4 in that order for free. When a pod is marked for deletion, the endpoint removal and the SIGTERM are dispatched concurrently. If your process treats SIGTERM as "close the listener now," you have skipped straight to step 4 before step 3 finished. You need to insert a deliberate pause, and that is what the preStop hook is for.

## The preStop Hook: Buying Time for Propagation

A `preStop` hook runs **before** the kubelet sends SIGTERM. The grace-period clock starts when termination begins, and the hook runs inside that budget, but the key property is sequencing: the container does not receive SIGTERM until the hook completes. So a preStop hook that simply sleeps gives the EndpointSlice removal time to fan out across the cluster before your process is ever asked to stop.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">deployment.yaml (lifecycle)</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">spec:
  terminationGracePeriodSeconds: <span style="color:#f0abfc;">45</span>   <span style="color:#64748b;"># preStop + drain must fit inside this</span>
  containers:
    - name: api
      image: api:2.4.0
      lifecycle:
        preStop:
          exec:
            command: [<span style="color:#a3e635;">"/bin/sh"</span>, <span style="color:#a3e635;">"-c"</span>, <span style="color:#a3e635;">"sleep 10"</span>]
            <span style="color:#64748b;"># Pod is already leaving the EndpointSlice during this sleep.</span>
            <span style="color:#64748b;"># Routers stop sending NEW traffic before the app sees SIGTERM.</span>
      readinessProbe:
        httpGet: { path: /healthz, port: 8080 }
        periodSeconds: <span style="color:#f0abfc;">2</span></code></pre>
</div>

The sleep is crude but correct, and a fixed 5 to 15 seconds covers most clusters. The grace period (45 here) must hold the preStop sleep **plus** the application's own drain budget, or the math does not close. A common mistake is setting a generous preStop sleep and forgetting to widen `terminationGracePeriodSeconds`, which silently truncates the drain. If you want the precise mechanics of why the name in front stays stable while the endpoints churn underneath, that is the [EndpointSlice and kube-proxy story](/2026/06/30/service-discovery-in-kubernetes.html) the deploy is leaning on.

## The Race You Cannot Fully Eliminate

Even with a perfect preStop hook, you have narrowed the race rather than abolished it. Endpoint propagation is eventually consistent. The control plane writes the EndpointSlice update, kube-proxy on each node reprograms its rules, ingress controllers re-read the endpoints, sidecars get an xDS push. Each of these is fast but not instantaneous, and there is no global barrier that says "every router has now stopped sending you traffic." Your preStop sleep is a bet that propagation finishes within N seconds, not a guarantee.

This is why a robust app does not rely on draining alone. Even after it fails readiness and sleeps, it should keep its listener open and keep accepting connections during the drain window, serving any stragglers that slipped through before propagation completed. **Refusing connections during the drain window is the bug; accepting and completing them is the drain.** The listener closes only at the very end, when both the propagation budget and the in-flight requests are done. That overlap, accepting late arrivals while finishing existing work, is the difference between a deploy that is clean on paper and one that is clean on the graphs.

## Long-Lived Connections and How Proxies Drain Them

Everything so far assumes short requests that finish inside the drain window. Keepalive and long-lived connections break that assumption. An HTTP/1.1 keepalive connection, an HTTP/2 multiplexed connection, a gRPC stream, or a WebSocket can stay open for minutes or hours. You cannot wait them all out inside a 45-second grace period, and you should not try.

The technique is to stop reusing the connection rather than to wait for it to close. For HTTP/1.1, the draining server sends `Connection: close` on its next response so the client opens a fresh connection (to a healthy pod) for the request after this one. For HTTP/2, the server sends a `GOAWAY` frame, which tells the client to stop opening new streams on this connection and migrate to a new one, while existing streams finish.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">draining a keepalive connection</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># HTTP/1.1: tell the client not to reuse this connection</span>
HTTP/1.1 200 OK
Connection: close

<span style="color:#64748b;"># HTTP/2: GOAWAY caps the highest stream the server will serve,</span>
<span style="color:#64748b;"># the client re-opens new streams elsewhere, open ones finish</span>
GOAWAY  last-stream-id=<span style="color:#f0abfc;">1287</span>  error-code=NO_ERROR</code></pre>
</div>

The proxies I covered in the [concurrency post](/2026/03/09/concurrent-requests-reverse-proxy.html) make this a first-class operation. HAProxy reloads through process replacement: `haproxy -sf $(cat /run/haproxy.pid)` hands the listening sockets to a new process while the old one stops accepting new connections and drains its existing ones to completion. Envoy does the equivalent with its hot-restart protocol: the new process takes over the sockets, and a **drain timer** governs how long the old process keeps serving in-flight requests, sending `GOAWAY` and `Connection: close` to nudge clients onto the new instance before it finally exits. Both follow the same shape your application should: new process takes the port, old process finishes its work, nobody refuses a request that was already in flight.

The general rule across all of it: **draining is biased toward letting existing work finish and toward refusing only new work, and the refusal happens at the routing layer, not the connection layer.** You stop being chosen as a destination; you do not slam the door on conversations already underway.

## Putting the Contract Back Together

A zero-downtime deploy is not a feature you turn on. It is a sequence every layer has to honor in order: the pod fails readiness, the control plane pulls it from the EndpointSlice, the preStop hook holds the line while that removal propagates, the application stops accepting new connections only after, in-flight requests complete inside a grace period sized to hold all of it, and long-lived connections are migrated with `GOAWAY` rather than severed. Skip any one step and you get the same symptom: a thin, deniable stream of errors that shows up every time you deploy and that nobody can quite reproduce.

The myth is that the orchestrator handles this for you. It hands you the primitives (SIGTERM, the grace period, the preStop hook, the readiness gate) and leaves the ordering to you. Getting the ordering right is the whole job.

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">A deploy does not drop requests because the platform is broken. It drops them because something stopped accepting traffic a few seconds before the rest of the system agreed to stop sending it. Draining is just making everyone agree on the order.</p>

---

*This builds on my earlier pieces on [how reverse proxies handle concurrent connections](/2026/03/09/concurrent-requests-reverse-proxy.html), [service discovery in Kubernetes](/2026/06/30/service-discovery-in-kubernetes.html), and [health checking in client vs server-side load balancing](/2026/01/12/health-checks-client-vs-server-side-lb.html).*

*Chasing a phantom stream of 502s on every deploy? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
