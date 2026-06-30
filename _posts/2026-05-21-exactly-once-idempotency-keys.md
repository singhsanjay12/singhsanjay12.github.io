---
title: "The Myth of Exactly-Once: Idempotency Keys and Effectively-Once"
description: "Exactly-once delivery is impossible over an unreliable network. What you actually want is exactly-once effect, and the practical way to get it is at-least-once delivery plus idempotent processing built around an idempotency key and an atomic dedupe store."
date: 2026-05-21 12:00:00 +0000
categories: [Distributed Systems, Reliability]
tags: [idempotency, exactly-once, messaging, reliability, distributed-systems, delivery-semantics]
image:
  path: /assets/img/posts/exactly-once/hero.svg
  alt: "A retried request arriving twice at a server, where an idempotency key and a dedupe store collapse the duplicates into a single committed effect"
---

Every few months someone asks me for **exactly-once delivery**, and every few months I have to give the same uncomfortable answer: it does not exist, and you do not actually want it. What you want is for a charge to happen once, an email to send once, an order to be placed once, no matter how many times the message carrying that intent shows up. That is a different thing, and the gap between the two is where most reliability bugs live.

The phrase people reach for is exactly-once, but the property they need is **exactly-once effect**, often called effectively-once. The distinction is not pedantry. Believing you have exactly-once delivery leads you to skip the one mechanism that actually saves you: making your processing idempotent. This post is about why the impossible thing is impossible, what to build instead, and the sharp edges that turn a confident design into a 3am double-charge.

## Why Exactly-Once Delivery Cannot Exist

The clean argument is the **Two Generals problem**. Two parties communicating over a channel that can lose messages can never become certain that the other has received a given message, because the acknowledgement can itself be lost, and the acknowledgement of the acknowledgement, and so on forever. There is no finite exchange that ends in mutual certainty.

Translate that to a sender and a receiver. The sender transmits a message and waits for an ack. The ack does not arrive. The sender now faces a genuine dilemma it cannot resolve from where it stands: was the message lost before the receiver saw it, or did the receiver process it and the ack got lost on the way back? Those two worlds are indistinguishable to the sender, and they demand opposite actions. If the message was lost, the sender must resend. If only the ack was lost, resending causes a duplicate.

You cannot escape this. Any system that wants no lost messages must allow retries, and any system that allows retries must tolerate duplicates. This is the same uncertainty I keep running into elsewhere: a [failed health check tells you about a probe, not a server](/2026/01/12/health-checks-client-vs-server-side-lb.html), and a [DNS answer is a snapshot that may already be stale](/2026/02/18/dns-the-silent-killer-of-distributed-systems.html). The network never lets you observe the other side's state directly. You only ever see your own.

## At-Most-Once vs At-Least-Once

Since perfect delivery is off the table, you get to pick which failure mode you prefer.

**At-most-once** means the sender transmits and never retries. If the message is lost, it is gone. You will never get a duplicate, but you will sometimes lose work. This is fine for a metrics sample or a cache warm, and catastrophic for a payment.

**At-least-once** means the sender retries until it gets an ack. You will never lose a message, but you will sometimes deliver it more than once. Almost every durable queue, broker, and RPC-with-retries defaults to this, because losing work is usually worse than doing it twice, *as long as doing it twice is safe.*

That last clause is the whole game. At-least-once is only acceptable if the receiver can absorb duplicates without producing duplicate effects. So the practical recipe for effectively-once is not a magic transport. It is:

**at-least-once delivery, plus idempotent processing.** The transport guarantees the message arrives. The processing guarantees that arriving twice is the same as arriving once.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">retry loop on the sender</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#94a3b8;">def</span> <span style="color:#7dd3fc;">send_with_retries</span>(msg, key):
    <span style="color:#94a3b8;">for</span> attempt <span style="color:#94a3b8;">in</span> range(<span style="color:#f0abfc;">5</span>):
        ack = transport.send(msg, idempotency_key=key)
        <span style="color:#94a3b8;">if</span> ack.ok:
            <span style="color:#94a3b8;">return</span> ack
        sleep(backoff(attempt))   <span style="color:#64748b;"># ack may have been lost, not the message</span>
    <span style="color:#94a3b8;">raise</span> DeliveryFailed(key)

<span style="color:#64748b;"># The SAME key is reused on every attempt. That is what lets</span>
<span style="color:#64748b;"># the receiver recognize a retry as a duplicate, not new work.</span></code></pre>
</div>

## Idempotency Keys: a Client-Supplied Name for an Intent

An **idempotency key** is a unique identifier the *client* attaches to an operation, the same value across every retry of that one logical request. It is the thing that lets the server tell "the user wants to do this again" apart from "the network made me say this twice."

The server keeps a **dedupe store**: a record, keyed by that idempotency key, of operations it has already performed. On each request it checks the store. If the key is new, it performs the work and records the result under the key. If the key is already present, it skips the work and returns the stored result. Two retries with the same key produce one effect and two identical responses.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">naive check-then-act (BROKEN under concurrency)</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#94a3b8;">def</span> <span style="color:#7dd3fc;">charge</span>(key, amount):
    <span style="color:#94a3b8;">if</span> store.get(key):              <span style="color:#64748b;"># 1. seen this key before?</span>
        <span style="color:#94a3b8;">return</span> store.get(key).result
    result = payment_gateway.charge(amount)   <span style="color:#64748b;"># 2. side effect</span>
    store.put(key, result)         <span style="color:#64748b;"># 3. remember it</span>
    <span style="color:#94a3b8;">return</span> result

<span style="color:#64748b;"># Two retries land between step 1 and step 3 on different workers.</span>
<span style="color:#64748b;"># Both see no key, both call the gateway. Double charge.</span></code></pre>
</div>

That code looks correct and is wrong, which is exactly why this topic deserves care.

## The Atomicity of Check-and-Do

The single most important property, and the one most often missing, is this: **recording the key and performing the effect must commit together, atomically, or not at all.** If they can commit separately, you have two ways to fail.

If the effect commits but the key does not, a retry sees no key and does the effect again: a **double charge**. If the key commits but the effect does not, a retry sees the key, assumes the work is done, and returns success for something that never happened: **lost work**. There is no safe ordering of two independent commits. The only safe design makes them one commit.

When the effect is a database write, this is easy: write the business row and the idempotency record in the **same transaction**.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">atomic check-and-do, one transaction</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#94a3b8;">BEGIN</span>;
  <span style="color:#64748b;">-- unique constraint on idempotency_key makes the insert the gate</span>
  <span style="color:#94a3b8;">INSERT INTO</span> idempotency (key, status)
  <span style="color:#94a3b8;">VALUES</span> (<span style="color:#a3e635;">'ik_8a1f...'</span>, <span style="color:#a3e635;">'done'</span>);     <span style="color:#64748b;">-- fails if key already exists</span>

  <span style="color:#94a3b8;">INSERT INTO</span> orders (id, user_id, total)
  <span style="color:#94a3b8;">VALUES</span> (<span style="color:#a3e635;">'ord_42'</span>, <span style="color:#a3e635;">'u_9'</span>, <span style="color:#f0abfc;">2500</span>);
<span style="color:#94a3b8;">COMMIT</span>;

<span style="color:#64748b;">-- A duplicate retry hits the unique-constraint violation on the</span>
<span style="color:#64748b;">-- first insert, the whole transaction rolls back, no second order.</span></code></pre>
</div>

The unique constraint on the key is doing the heavy lifting: it turns "check then do" into a single indivisible operation that the database arbitrates for you. When the effect lives in an external system you cannot enlist in your transaction (a payment gateway, an email provider), you push the atomicity to them: pass your idempotency key on the downstream call so the gateway dedupes too, and record state transitions (`pending`, then `done`) so a crash mid-flight is recoverable rather than ambiguous.

## Retry-Safe Is Not the Same as Idempotent

Two words get used interchangeably and should not be. **Idempotent** means applying the operation twice has the same result as applying it once. **Retry-safe** is a weaker, fuzzier claim that retrying "probably will not hurt." An operation can be retry-safe in the happy path and still corrupt state under a partial failure. Idempotency is a property you can reason about; retry-safety is often a hope.

Some operations are **naturally idempotent**: setting a value to a constant (`status = 'shipped'`), a PUT that replaces a whole resource, deleting by id. Run them twice and the end state is identical. Others are not: incrementing a counter, appending to a list, charging a card. For those you need **enforced idempotency**, which is exactly the idempotency-key-plus-dedupe-store machinery above.

HTTP encodes this in its method semantics. GET, PUT, and DELETE are defined as idempotent: a client or proxy may safely retry them. POST is not, which is why payment and order-creation APIs ask you to send an `Idempotency-Key` header on POST: it manually grants POST the property the method does not have by default.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">granting POST idempotency by header</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">POST /v1/charges HTTP/1.1
Idempotency-Key: ik_8a1f3c9e2b      <span style="color:#64748b;"># same on every retry</span>
Content-Type: application/json

{ <span style="color:#a3e635;">"amount"</span>: <span style="color:#f0abfc;">2500</span>, <span style="color:#a3e635;">"currency"</span>: <span style="color:#a3e635;">"usd"</span> }

<span style="color:#64748b;"># First request: charges the card, stores result under the key.</span>
<span style="color:#64748b;"># Retry with same key: returns the stored result, no second charge.</span></code></pre>
</div>

## The Edges That Bite

A correct core design still has sharp edges, and they are where I have watched real outages start.

**Dedupe window and TTL.** A dedupe store cannot remember every key forever, so it expires them after some window. That window is a correctness boundary, not just a storage knob. If a retry arrives after its key has been evicted, the server treats it as new work and produces a duplicate effect. The window must comfortably exceed the maximum possible retry horizon of your slowest client and queue, including a message that sat in a dead-letter queue for hours before being replayed.

**Concurrent duplicates racing.** The nastiest case is not a retry arriving an hour later, it is two copies of the same request arriving at nearly the same instant on two different workers, the classic race I dug into in [how reverse proxies handle concurrent requests](/2026/03/09/concurrent-requests-reverse-proxy.html). Both read the dedupe store, both see no key, both proceed. A naive check-then-act loses here every time. The fix is to make the *write* of the key the gate: a unique-constraint insert, a conditional `PUTIfAbsent`, or a row lock, so that exactly one of the racers wins the insert and the others fail fast and return the winner's result.

**Effectively-once in stream processors.** When Kafka or Flink advertise "exactly-once," they mean exactly-once effect inside the boundary of their own state, and they achieve it the same way you do: not by perfect delivery, but by making the consume-process-produce cycle atomic. A consumer reads a message, updates state, produces output, and commits its **offset** all within one transaction. If it crashes, the transaction aborts, the offset is not advanced, and the work replays from the last committed point with no visible duplicate. The offset commit is just an idempotency key with a fancier name: it is the record of "I have already processed up to here." The instant output leaves that transactional boundary, say to an external HTTP call, you are back to at-least-once and need your own dedupe again.

## The Honest Summary

There is no transport that delivers a message exactly once, because the network will not tell you whether your last message got through. Accept that, choose at-least-once so you never lose work, and put the correctness where it belongs: in idempotent processing. Give every operation a stable client-supplied key, commit the key and the effect in a single atomic step, size your dedupe window to outlast your slowest retry, and make the key-write win the race. Do that and your system behaves, from the outside, as if each intent happened exactly once, which was the only thing anyone actually wanted.

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">Exactly-once is not a property of the wire. It is a property you build at the receiver: an idempotency key, an atomic check-and-do, and the humility to assume every message will arrive at least twice.</p>

---

*This pairs with my earlier writing on [how reverse proxies handle concurrent requests](/2026/03/09/concurrent-requests-reverse-proxy.html), [health checking in client vs server-side load balancing](/2026/01/12/health-checks-client-vs-server-side-lb.html), and [DNS, the silent killer of distributed systems](/2026/02/18/dns-the-silent-killer-of-distributed-systems.html).*

*Designing idempotent APIs or untangling a double-effect bug? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
