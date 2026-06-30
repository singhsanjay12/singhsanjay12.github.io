---
title: "Retries, Timeouts, and the Thundering Herd: How One Retry Becomes an Outage"
description: "A retry is a load multiplier that fires exactly when a system is least able to absorb it. Here is how naive retries cause retry storms and metastable failures, and the backoff, jitter, budgets, deadlines, and idempotency that keep retries from taking you down."
date: 2026-04-13 12:00:00 +0000
categories: [Distributed Systems, Reliability]
tags: [reliability, retries, timeouts, backoff, resilience, distributed-systems]
image:
  path: /assets/img/posts/retries-thundering-herd/hero.svg
  alt: "A single failing backend triggering a multiplying wave of client retries that doubles load and keeps the system down"
---

Every retry is an optimistic bet: that the failure you just hit was transient, and that trying again will work. Most of the time the bet pays off. A packet dropped, a connection reset, a backend that was rolling a pod. Try again, and the second attempt succeeds. This is why retries are everywhere, baked into clients, libraries, and sidecars, often with nobody quite remembering they are on.

The hidden assumption is that the failure you are retrying past is **independent and transient**. That assumption holds for a single dropped packet. It breaks completely when the backend is failing because it is overloaded, because then your retry is not routing around the failure: **it is the failure.** A naive retry doubles the load on a system at the exact moment that system has the least capacity to absorb it. This is the silent failure mode that turns a brief blip into an outage that outlives its own cause.

## A Retry Is a Load Multiplier

Start with the arithmetic, because it is the whole story. Imagine a service handling 10,000 requests per second against a backend that has just lost a third of its capacity. Latency climbs, some requests start timing out, and a client configured to "retry twice on failure" does exactly what it was told.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="20" x2="12" y2="10"/><line x1="18" y1="20" x2="18" y2="4"/><line x1="6" y1="20" x2="6" y2="16"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">the retry math</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">offered load        = 10,000 rps
backend capacity    = was 12,000 rps, now 8,000 rps   <span style="color:#64748b;"># lost a third</span>

<span style="color:#64748b;"># requests that fail now get retried up to 2x</span>
failing fraction    = 20%
effective load      = 10,000 + (0.20 * 10,000 * 2)
                    = 14,000 rps                       <span style="color:#ef4444;"># offered MORE than before</span>

<span style="color:#64748b;"># the backend is at 8,000 capacity facing 14,000 rps</span>
<span style="color:#64748b;"># the failing fraction grows, which generates MORE retries...</span></code></pre>
</div>

Notice the feedback loop in the last comment. A higher failure rate generates more retries, which raises the offered load, which raises the failure rate. The retry policy turns a partial degradation into a runaway. The backend never gets a chance to recover, because every time it claws back a little capacity, the retry queue immediately spends it. This is a **thundering herd**: a synchronized stampede of clients all hammering a resource that cannot serve them.

## Retry Storms and Metastable Failure

The genuinely dangerous property here is not that the system slows down. It is that the system can stay down **after the original trigger is gone.** This is a metastable failure, and it is one of the most counterintuitive failure modes in distributed systems.

Picture the timeline. A backend hiccups for two seconds (a garbage collection pause, a brief network partition). Clients time out and retry. The retries pile onto the recovering backend, push it back over its capacity, and cause more timeouts, which cause more retries. The original two-second hiccup is long over, but the system has entered a self-sustaining loop where retry load alone is enough to keep it saturated. You have built a system with two stable states: healthy, and a high-load equilibrium that it will not leave on its own.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 3v18h18"/><path d="M18 9l-5 5-3-3-4 4"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">metastable failure timeline</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">t=0s    trigger: 2s GC pause on backend        <span style="color:#64748b;"># the original cause</span>
t=2s    trigger gone, backend healthy again
t=2s    but clients have queued retries...      <span style="color:#ef4444;"># load spike hits now</span>
t=3s    retry load alone &gt; capacity
t=4s    timeouts -&gt; more retries -&gt; more load    <span style="color:#ef4444;"># self-sustaining</span>
        ...
t=600s  STILL DOWN, cause long forgotten        <span style="color:#ef4444;"># metastable state</span>

<span style="color:#a3e635;"># recovery requires EXTERNAL action: shed load, drop retries,</span>
<span style="color:#a3e635;"># or add capacity. the system will not heal itself.</span></code></pre>
</div>

The operational tell is brutal: the dashboards show a backend that looks healthy in isolation (low per-request latency when it does serve) drowning under an offered load that has no business existing. Escaping a metastable state almost always requires breaking the loop from outside: shedding load at the front door, flushing retry queues, or temporarily turning retries off entirely. You cannot scale your way out, because the retry amplification scales with you.

## Backoff Needs Jitter, Because Synchronized Retries Are Their Own Herd

The first instinct is exponential backoff: wait longer between each attempt so you stop hammering a struggling backend. Wait 100ms, then 200ms, then 400ms. This is necessary, and it is not sufficient, because of a subtle trap.

If every client uses the **same** backoff schedule, and they all started failing at roughly the same instant (which is exactly what happens during a shared outage), then they all retry at the same instant too. Your carefully spaced backoff has simply moved the thundering herd a few hundred milliseconds into the future, perfectly synchronized. The cure for the herd is **jitter**: randomizing each client's wait so the retries spread out across time instead of arriving as a wall.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">backoff with full jitter</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#94a3b8;">import</span> random, time

<span style="color:#94a3b8;">def</span> <span style="color:#7dd3fc;">backoff_delay</span>(attempt, base=<span style="color:#f0abfc;">0.1</span>, cap=<span style="color:#f0abfc;">5.0</span>):
    exp = min(cap, base * <span style="color:#f0abfc;">2</span> ** attempt)  <span style="color:#64748b;"># 0.1, 0.2, 0.4, 0.8 ...</span>
    <span style="color:#94a3b8;">return</span> random.uniform(<span style="color:#f0abfc;">0</span>, exp)         <span style="color:#a3e635;"># full jitter: pick anywhere in [0, exp]</span>

<span style="color:#64748b;"># WITHOUT jitter: 1,000 clients all wait 0.4s, all retry at t+0.4</span>
<span style="color:#64748b"># WITH    jitter: those retries smear evenly across a 0.4s window</span>
<span style="color:#ef4444;"># fixed backoff is a delayed herd, not a smaller one</span></code></pre>
</div>

"Full jitter" (pick a wait uniformly between zero and the exponential ceiling) flattens the spike most aggressively. The point is not the exact formula. The point is that **determinism is the enemy** when many clients share a failure: any schedule they all agree on becomes a synchronization mechanism for the herd. This is the same lesson that shows up in [load balancing algorithms](/2026/03/02/load-balancing-algorithms.html), where uniform client behavior can defeat an otherwise sensible distribution and pile load onto one unlucky target.

## Retry Budgets: Cap the Blast Radius

Backoff and jitter shape *when* retries happen. A retry budget caps *how many* can happen at all. The idea is simple and powerful: allow retries to consume only a small percentage of your overall request volume, say 10%. Once retries exceed that fraction in a rolling window, you stop retrying and fail fast instead.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2v4"/><path d="M12 18v4"/><path d="M4.93 4.93l2.83 2.83"/><circle cx="12" cy="12" r="4"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">retry budget (token-style)</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># allow retries up to 10% of the request rate, in a rolling window</span>
budget_ratio   = <span style="color:#f0abfc;">0.10</span>

<span style="color:#94a3b8;">def</span> <span style="color:#7dd3fc;">may_retry</span>(requests_in_window, retries_in_window):
    allowed = requests_in_window * budget_ratio
    <span style="color:#94a3b8;">return</span> retries_in_window &lt; allowed

<span style="color:#64748b;"># healthy: failures are rare, retries stay under budget, all served</span>
<span style="color:#64748b;"># outage: failures spike, retries hit the cap, extra ones FAIL FAST</span>
<span style="color:#a3e635;"># effect: worst case load is 1.10x, never 2x or 3x</span></code></pre>
</div>

The beauty of a budget is that it preserves retries when they are useful (a rare, isolated failure costs almost nothing against the budget) and disables them precisely when they are dangerous (a correlated outage that would otherwise generate a flood). It converts an unbounded multiplier into a bounded one. This is the single most effective guardrail against retry storms, and it is far too often missing, because each client library believes its own retries are reasonable in isolation. They always are. It is their *sum* that ends you.

## Deadlines and Timeout Propagation

There is a quieter failure mode hiding inside retries, and it is about wasted work. Consider a request that fans out across several hops: a gateway calls service A, which calls service B, which calls a database. If each hop sets its own independent timeout, you get pathological behavior. The user gave up two seconds ago, but service B is still dutifully working on a request whose answer nobody will ever read.

The fix is to propagate a **deadline**, not a per-hop timeout. The caller computes an absolute moment in time by which the answer is worthless, and passes that deadline down the call chain. Each hop checks the remaining budget before doing work, and refuses to start anything it cannot finish in time.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">deadline propagation across hops</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># BAD: each hop has its own fixed timeout, unaware of the others</span>
gateway timeout = 2s   service A = 2s   service B = 2s   db = 2s
<span style="color:#ef4444;"># worst case = 8s of work for a request abandoned at 2s</span>

<span style="color:#64748b;"># GOOD: pass an absolute deadline down the chain</span>
deadline = now() + <span style="color:#f0abfc;">2.0</span>s                  <span style="color:#64748b;"># set once at the edge</span>

<span style="color:#94a3b8;">def</span> <span style="color:#7dd3fc;">call</span>(next_hop, deadline):
    remaining = deadline - now()
    <span style="color:#94a3b8;">if</span> remaining &lt;= <span style="color:#f0abfc;">0</span>:
        <span style="color:#94a3b8;">raise</span> DeadlineExceeded     <span style="color:#a3e635;"># do not even start: it is already too late</span>
    <span style="color:#94a3b8;">return</span> next_hop.invoke(timeout=remaining, deadline=deadline)</code></pre>
</div>

A timeout that is not propagated is wasted capacity, and wasted capacity during an incident is exactly the capacity you cannot spare. Worse, it interacts badly with retries: a hop that keeps grinding on a doomed request is holding a connection and a thread that could be serving a live one. The same connection-budget reasoning I wrote about in [how reverse proxies handle concurrent connections](/2026/03/09/concurrent-requests-reverse-proxy.html) applies here. Deadlines also make retries honest: there is no point retrying if the deadline has already passed, so the deadline naturally caps your retry depth without any separate configuration.

## Idempotency Is the Precondition for Retrying At All

Everything above assumes retrying is *safe*. It is only safe if the operation is idempotent: running it twice produces the same result as running it once. Reads are naturally idempotent. A "charge this card" or "send this email" is emphatically not. If a write times out, you genuinely do not know whether it succeeded and the acknowledgment was lost, or whether it never happened. Blindly retrying a non-idempotent write is how a single timeout becomes a double charge.

The standard fix is an idempotency key: the client attaches a unique identifier to the operation, and the server deduplicates by it, so a retried request with the same key is recognized and the original result is replayed rather than the side effect repeated.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">idempotency key dedupes safe retries</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># client generates a stable key ONCE, reuses it on every retry</span>
key = uuid4()

<span style="color:#94a3b8;">def</span> <span style="color:#7dd3fc;">charge</span>(key, amount):
    <span style="color:#94a3b8;">if</span> store.seen(key):
        <span style="color:#94a3b8;">return</span> store.result(key)   <span style="color:#a3e635;"># replay the first answer, no second charge</span>
    result = do_charge(amount)
    store.save(key, result)
    <span style="color:#94a3b8;">return</span> result

<span style="color:#ef4444;"># NO key: retry after a lost ack -&gt; charged twice</span>
<span style="color:#a3e635;"># WITH key: retry is a safe no-op that returns the original result</span></code></pre>
</div>

The rule of thumb: do not enable retries on a path until you can answer "what happens if this runs twice?" If the answer is bad, you need an idempotency key, or you need to not retry. This is not a side detail. It is the precondition that makes the entire retry machinery sound, and skipping it trades a reliability win for a correctness bug.

## Where Retries Meet Circuit Breaking and Hedging

Retries do not live alone. They sit alongside two other patterns, and the interactions matter. A **circuit breaker** watches a downstream dependency and, after enough failures, trips open: it stops sending requests entirely for a cooldown, failing fast instead. This is the perfect complement to retries, because the circuit breaker is what stops the retry loop from re-arming a backend that is already on the floor. When the breaker is open, there is nothing to retry, which is exactly the behavior you want during a metastable episode.

**Load shedding** is the same idea from the server's side: a backend protecting itself by rejecting work it cannot complete, so it serves a healthy fraction quickly rather than failing all of it slowly. A server that sheds load is one a client should *not* retry against, which is why a well-designed system signals "I am shedding, do not retry" distinctly from "I failed, retrying might help." Health-aware routing matters here too, because the cleanest retry is the one that goes to a *different*, healthy instance, the case I made in [client-side versus server-side health checking](/2026/01/12/health-checks-client-vs-server-side-lb.html).

Finally, **hedged requests** flip the retry timing. Instead of waiting for a failure, you send a second request to a different replica once the first crosses a latency threshold (say the 95th percentile), and take whichever returns first. Hedging is excellent for tail latency, but it is a retry by another name, and it carries the same cost: every hedge is extra load. Bound it with a budget, just like ordinary retries, or you will hedge your way into the very storm you were trying to outrun.

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">A retry is a small, sensible act of optimism. A million of them, synchronized, with no budget and no deadline, is an outage you built yourself. The discipline is not in deciding to retry. It is in deciding, ahead of time, how you will stop.</p>

---

*This pairs with my earlier writing on [load balancing algorithms](/2026/03/02/load-balancing-algorithms.html), [how reverse proxies handle concurrent connections](/2026/03/09/concurrent-requests-reverse-proxy.html), and [health checking in client vs server-side load balancing](/2026/01/12/health-checks-client-vs-server-side-lb.html).*

*Untangling a retry storm or designing backoff and budgets for a fan-out service? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
