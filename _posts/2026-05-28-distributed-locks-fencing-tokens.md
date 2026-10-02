---
title: "Distributed Locks Are Harder Than They Look: Fencing Tokens and the Redlock Debate"
description: "A distributed lock is not a mutex. A holder can pause past its lease while another client acquires the same lock, so two writers think they are alone. Here is why fencing tokens, not timeouts, are what actually make a distributed lock safe for correctness."
date: 2026-05-28 12:00:00 +0000
categories: [Distributed Systems, Reliability]
tags: [distributed-locks, fencing-tokens, consensus, concurrency, reliability, distributed-systems]
image:
  path: /assets/img/posts/distributed-locks/hero.svg
  alt: "A client holding a lock pauses on GC while a second client acquires it, and a fencing token at the resource rejects the stale writer's late request"
---

Every distributed lock tutorial starts the same way: acquire the lock, do the work, release the lock. It reads exactly like the mutex you use inside a single process, and that is the trap. The hidden assumption is that the thing holding the lock is alive and running for the whole duration it believes it holds it. Inside one process, that assumption is basically free. Across a network, with leases and timeouts and processes that can freeze without warning, it is the assumption that quietly breaks and takes your data with it.

I keep coming back to one uncomfortable fact: **a distributed lock cannot prevent two clients from believing they hold it at the same time.** It can make that situation rare. It cannot make it impossible. Once you accept that, the design problem changes completely, and the answer turns out not to be a better lock. It is a fencing token at the resource.

## A Lock Is Not a Mutex

A process-local mutex is enforced by the kernel and the CPU. If you hold it, no other thread holds it, full stop, because the same hardware arbitrates both threads. A distributed lock has none of that. It is a record in some external service (Redis, etcd, ZooKeeper, a database row) that says "client A holds lock L until time T." The lock service and the client that holds the lock are two different machines connected by a network that can delay, drop, or reorder anything.

To stay available, that record almost always carries a **lease**: a time-to-live, after which the lock service assumes the holder is dead and lets someone else acquire it. Without a lease, one crashed client holding a lock would block the resource forever. With a lease, the lock service is making a bet: that if it has not heard from you by time T, you are gone.

That bet is wrong precisely when it matters most. Consider the classic sequence.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">the unsafe pattern</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># client A</span>
lock = acquire("orders", ttl=10s)   <span style="color:#64748b;"># A holds it until T+10</span>
<span style="color:#94a3b8;">...</span>                                 <span style="color:#64748b;"># A pauses here: GC, page fault, CPU steal</span>
write_to_db(order)                  <span style="color:#ef4444;"># resumes at T+13, lease long gone</span>

<span style="color:#64748b;"># client B, meanwhile</span>
lock = acquire("orders", ttl=10s)   <span style="color:#64748b;"># lease expired at T+10, B gets it cleanly</span>
write_to_db(order)                  <span style="color:#a3e635;"># B is the rightful holder now</span></code></pre>
</div>

Nothing here is a bug in the lock service. The lease expired, the service handed the lock to B exactly as designed, and B did everything right. The problem is A. A was paused inside a stop-the-world garbage collection pause, or descheduled by a busy hypervisor, or stuck in a long disk fault, for longer than its lease. When it woke up, it had no idea any time had passed. It still held a `lock` object that said "you own this," so it went ahead and wrote. Now two clients have written under the same lock, and the lock did exactly nothing to stop the second write.

## The Silent Failure Mode: A Pause You Cannot See

The reason this is so dangerous is that the paused client gets no signal. A network call fails loudly: you get an error, a timeout, a closed connection. A garbage collection pause is silent. The thread simply stops, and then continues, with the same local state it had before. There is no exception to catch, no return code to check. The code after the pause runs as if no time has passed at all.

You cannot engineer this away by making pauses shorter. You can make them rarer with a better collector or smaller heaps, but a multi-second pause is always possible: a full GC, a VM live-migration, a hypervisor scheduling a noisy neighbor, the OS swapping you out, even a laptop lid closing. Any lease short enough to give you fast failover is short enough to be outlived by one of these. Any lease long enough to never be outlived makes failover uselessly slow. There is no TTL that escapes the dilemma, because **the dilemma is not about the number, it is about the holder being unable to observe its own pause.**

This is the same shape of problem I wrote about in [health checking, client side versus server side](/2026/01/12/health-checks-client-vs-server-side-lb.html): a component that looks healthy from the outside can be unable to do its job, and any timeout you pick is simultaneously too long for liveness and too short for safety. A lease is just a health check the lock service runs against its holder, and it inherits all of that ambiguity.

## The Fix Is Not a Better Lock: It Is a Fencing Token

Here is the move that actually solves it, and it is the part most tutorials skip. **Stop trying to make the lock perfect. Make the resource reject stale writers.**

When the lock service grants a lock, it also returns a **fencing token**: a number that strictly increases every time the lock is granted. The first holder gets 33, the next gets 34, the next 35, and so on, monotonically, forever. The client must attach its token to every write it sends to the protected resource. The resource remembers the highest token it has ever accepted, and **rejects any write carrying a token less than or equal to that high-water mark.**

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">fencing at the resource</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># the lock returns a strictly increasing token with the grant</span>
token = acquire("orders")           <span style="color:#64748b;"># A gets token 33</span>
write(order, fence=token)           <span style="color:#64748b;"># A pauses before this line lands</span>

token = acquire("orders")           <span style="color:#64748b;"># B gets token 34 after A's lease expires</span>
write(order, fence=token)           <span style="color:#a3e635;"># resource accepts 34, high-water = 34</span>

<span style="color:#64748b;"># A finally wakes up and its delayed write arrives:</span>
write(order, fence=<span style="color:#f0abfc;">33</span>)             <span style="color:#ef4444;"># REJECTED: 33 &lt;= 34, stale writer fenced</span></code></pre>
</div>

Notice what this buys you. Client A still wakes up confused. It still sends its write. But the write arrives carrying token 33, and the resource has already accepted 34, so the write is refused. **Safety no longer depends on A noticing its pause, on clocks being accurate, or on the lock service being perfect.** It depends only on a number going up and the resource enforcing monotonicity, which is something the resource can check locally and deterministically. The timing problem has been converted into an ordering problem, and ordering is something we can actually guarantee.

The resource side is simple, and that simplicity is the point.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">storage.write (server side)</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">def write(key, value, fence):
    if fence &lt;= high_water[key]:        <span style="color:#64748b;"># a newer holder already wrote</span>
        return REJECT                  <span style="color:#ef4444;"># fence out the stale writer</span>
    high_water[key] = fence            <span style="color:#64748b;"># advance the high-water mark</span>
    store(key, value)
    return OK</code></pre>
</div>

The catch, and the reason this is not free, is that **the resource has to participate.** It must understand fencing tokens and enforce them. If you are writing to a system that has no concept of a token (a plain blob store with no conditional writes, a legacy service that just accepts bytes), you cannot fence it, and no amount of cleverness in the lock client recovers the guarantee. The good news is that many storage systems already give you the primitive under another name: object versions with conditional puts, compare-and-set, `If-Match` ETags, fenced append-only logs. A fencing token is just a generation number you thread through that primitive.

## The Redlock Debate, and Why It Still Matters

This is the heart of the famous exchange between Martin Kleppmann and Salvatore Sanfilippo (antirez) about Redlock, the algorithm for distributed locking across multiple independent Redis nodes. Redlock tries to make the lock itself safer by requiring a client to acquire the lock on a majority of N Redis nodes within a time bound, on the theory that a majority is hard to fool.

Kleppmann's objection is the one this whole post has been building toward: **it does not matter how many nodes you ask, because the failure is on the client side, after acquisition.** A client can win the majority cleanly, then pause for a GC cycle, then have its lease expire on all the nodes, then wake up and write. Redlock cannot see that pause any more than a single-node lock can. And Redlock additionally leans on bounded clock drift and bounded message delay across the cluster to reason about its time bounds, which are assumptions a real network violates the moment a clock steps or a packet is delayed. Without a fencing token, a lock built on timeouts across N nodes is not safe for correctness, and adding nodes does not change that.

antirez's reply is also fair, and the disagreement is mostly about what the lock is for. **A lock for efficiency and a lock for correctness are different tools held to different standards.** If you are using a lock to avoid two workers redundantly recomputing the same expensive cache entry, an occasional double-run is a wasted CPU cycle, not a corruption. Redlock, or even a single Redis `SET NX PX`, is completely fine for that. The cost of being wrong is small and self-correcting.

The trouble starts when people quietly promote an efficiency lock into a correctness guarantee, holding the same lock across an irreversible write and assuming it makes the operation exclusive. It does not. The discipline is to know which kind you are using, and **the test is brutally simple: if two clients ran the protected section at the same time, would you lose or corrupt data? If yes, you need a correctness lock, and a correctness lock needs fencing at the resource.**

## Consensus Systems Give You a Sequencer, Not a Free Pass

"Fine," the natural response goes, "I will use a real consensus system: etcd or ZooKeeper, not Redis." These are genuinely stronger. They use consensus protocols (Raft, Zab) so the lock state is linearizable and survives node failures, and they will not hand the lock to two clients due to a split brain the way a loose multi-node scheme can. ZooKeeper's ephemeral sequential znodes and etcd's lease plus revision are exactly the monotonically increasing sequencer you need for fencing: ZooKeeper's `zxid` and etcd's `mod_revision` increase with every change and make perfect fencing tokens.

But notice what they fixed and what they did not. They fixed the lock service. **They did not fix the holder.** etcd and ZooKeeper still grant the lock with a lease, and a leaseholder can still pause past its lease, exactly as before. The consensus system is a correct, highly available sequencer. It is not a guarantee that the client holding the lease is currently alive and acting. So you still attach the sequencer's number to your writes, and you still make the resource reject stale ones. Consensus gives you a trustworthy token. It does not let you skip the fence.

This is the same lesson that runs through how Kubernetes does discovery in [service discovery in Kubernetes](/2026/06/30/service-discovery-in-kubernetes.html): a strongly consistent control plane gives you an authoritative source of truth, but the data plane still has to enforce the current state at the point of action, because the gap between "the control plane knows" and "the actor behaves" is where stale state slips through. The lock service knowing who is the rightful holder does nothing unless the resource refuses everyone else.

## Practical Guidance

Strip away the theory and the working rules are short.

**Use locks to reduce duplicate work, not to guarantee correctness.** Most real uses of distributed locks are efficiency locks: do not run this cron twice, do not let two workers warm the same cache, serialize a noisy operation to be polite. For those, a single Redis lock is fine, and you should not lose sleep over the edge cases, because the edge case costs you a duplicated effort, not a corruption.

**For correctness, fence at the resource.** If two concurrent holders would corrupt or lose data, the lock alone is never enough. Get a monotonically increasing token from the lock (etcd revision, ZooKeeper zxid, a database sequence), pass it on every write, and make the resource reject stale tokens using whatever conditional-write primitive it offers. The lock becomes an optimization that keeps contention low, and the fence becomes the thing that is actually load-bearing for safety.

**Be honest about the resource.** If the resource cannot enforce a token, you do not have a correctness lock, no matter what lock service sits in front of it. Either give the resource a fencing primitive or redesign so the write is idempotent and ordering does not matter. There is no third option where the client side alone saves you.

The same asymmetry shows up everywhere I have written about coordination, including how a [reverse proxy handles concurrent requests](/2026/03/09/concurrent-requests-reverse-proxy.html): you cannot make a distributed actor behave just by telling it the rules, because it can be paused or partitioned the instant after you tell it. You enforce at the point where the irreversible thing happens. For locks, that point is the resource, and the enforcement is a number that only goes up.

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">A distributed lock cannot stop two clients from thinking they hold it. It can only make that rare. Safety has to live somewhere that does not depend on timing, and that somewhere is a fencing token the resource refuses to ignore.</p>

---

*This connects to my earlier writing on [health checking in client vs server-side load balancing](/2026/01/12/health-checks-client-vs-server-side-lb.html), [service discovery in Kubernetes](/2026/06/30/service-discovery-in-kubernetes.html), and how a [reverse proxy handles concurrent requests](/2026/03/09/concurrent-requests-reverse-proxy.html).*

*Wrestling with locks, leases, or fencing in a real system? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
