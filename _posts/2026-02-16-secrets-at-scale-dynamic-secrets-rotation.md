---
title: "Secrets at Scale: Dynamic Secrets and Rotation Without Downtime"
description: "Long-lived secrets in env vars are the soft underbelly of an otherwise locked-down system. Here is how dynamic, short-lived credentials, overlapping rotation windows, and workload identity shrink the blast radius to minutes."
date: 2026-02-16 12:00:00 +0000
categories: [Security, Zero Trust]
tags: [secrets, vault, rotation, security, zero-trust, identity]
image:
  path: /assets/img/posts/secrets-rotation/hero.svg
  alt: "A secrets manager issuing a short-lived dynamic credential to an attested workload and rotating it with two overlapping leases so nothing breaks"
---

You can spend a year building a Zero Trust architecture: mutual TLS everywhere, a [reverse proxy as the enforcement point](/2025/08/03/zero-trust-with-reverse-proxy.html), a [control plane that revokes access in seconds](/2025/10/20/zero-trust-control-plane-and-sessions.html). And then a service reads a database password out of an environment variable that was set in 2022, has never changed, and is sitting in plaintext in three CI logs, a Slack thread, and a `.env` file on someone's laptop.

That password is the soft underbelly. Everything in front of it is short-lived and attested. The secret itself is standing access with no expiry, and nobody is watching it. The hidden assumption in most systems is that a secret, once provisioned, is fine to leave in place. It is not. The silent failure mode is that the secret leaks long before anyone notices, and there is no clock running on the damage.

This post is about closing that gap: making secrets short-lived by default, rotating them without taking anything down, and delivering them to workloads in a way that does not just move the problem somewhere else.

## Why Static Secrets Are the Weak Point

A static, long-lived secret has three properties that make it dangerous, and they compound.

**It leaks.** Not dramatically, usually. It ends up in a build log because someone echoed the environment for debugging. It gets pasted into a ticket. It lands in a container image layer because the Dockerfile copied a config file in. Every one of these is a copy that lives forever, and you cannot un-leak a value that does not change.

**It sprawls.** The same database password is shared across twelve services because rotating it everywhere is painful, so nobody does. Now the blast radius of that one secret is twelve services, and you cannot tell which of them leaked it.

**Nobody rotates it.** Rotation is a project. It means coordinating a change across every consumer, hoping you found them all, and accepting a real chance of an outage if you missed one. So the secret sits there for years. The longer it sits, the more copies exist, and the larger the window in which a leaked copy is still valid: which is to say, forever.

The root problem is that the credential's lifetime is unbounded. A leaked secret that expires in five minutes is an incident you slept through. A leaked secret with no expiry is a breach waiting for a date.

## Dynamic Secrets: Generate, Lease, Revoke

The fix is to stop treating a secret as a value you store and start treating it as a credential you mint. A secrets manager such as Vault does not hand out a shared password. It holds privileged access to the backend (the database, the cloud API, the message broker) and generates a brand new, scoped credential on demand, with a lease attached.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">request a dynamic database credential</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">$ vault read database/creds/payments-ro

Key                Value
<span style="color:#64748b;">---                -----</span>
lease_id           database/creds/payments-ro/aH7kQ
lease_duration     <span style="color:#f0abfc;">5m</span>                       <span style="color:#64748b;"># dies on its own in 5 minutes</span>
lease_renewable    true
username           <span style="color:#a3e635;">v-payments-ro-aH7kQ-1739</span>  <span style="color:#64748b;"># unique per request</span>
password           <span style="color:#a3e635;">A1b2-C3d4-E5f6-G7h8</span></code></pre>
</div>

Three things changed, and all three matter.

The credential is **unique per request**. Two replicas of the same service get two different usernames. If one leaks, you know exactly which lease and which caller, because the username is traceable back to the request.

It is **scoped**. The `payments-ro` role is defined once, in the secrets manager, as the least privilege that consumer needs: read-only on two tables, nothing else. The consumer never sees the privileged credential that created it.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">the role definition (set once, by an admin)</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">role:     payments-ro
db:       payments
default_ttl: <span style="color:#f0abfc;">5m</span>
max_ttl:     <span style="color:#f0abfc;">30m</span>
creation_statements:
  - CREATE ROLE "{name}" LOGIN PASSWORD '{password}' VALID UNTIL '{expiration}';
  - GRANT SELECT ON orders, ledger TO "{name}";   <span style="color:#64748b;"># least privilege, read only</span></code></pre>
</div>

And it is **short-lived**. The lease is five minutes. When it expires, the secrets manager connects to the backend and deletes the credential it created. The blast radius of a leaked secret is no longer "until someone notices." It is the remaining lease duration, measured in minutes. This is the same shape as the [bounded sessions argument](/2025/10/20/zero-trust-control-plane-and-sessions.html) for connections: you cannot prevent every compromise, so you put a hard ceiling on how long any compromise stays useful.

The catch is that a five-minute credential expires every five minutes. If your application reads it once at startup and holds it forever, it breaks. Which brings us to the part everyone gets wrong.

## Rotation Without Downtime: Overlapping Validity

The naive rotation is a swap: revoke the old secret, issue the new one. There is always a window, however small, where consumers still holding the old secret are now holding a dead one. At scale, with many replicas renewing on slightly different schedules, that window is where your pager goes off.

The correct pattern is **overlapping validity**: the new secret is live before the old one dies, and there is a span of time where both are valid. Consumers move to the new one during the overlap, and only then is the old one revoked.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">two-key window during rotation</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"> key A  <span style="color:#a3e635;">|=================|</span>           <span style="color:#64748b;"># valid, being retired</span>
 key B          <span style="color:#a3e635;">|=================|</span>   <span style="color:#64748b;"># valid, taking over</span>
                <span style="color:#f0abfc;">^---- overlap ----^</span>
                both accepted here; consumers cut over,
                then key A is revoked with nothing left on it</code></pre>
</div>

If this feels familiar, it should. It is the same shared-secret-distribution problem as TLS ticket keys: a fleet of terminators must all accept tickets encrypted under a key that is being rotated, so the new key is distributed and accepted before the old key stops being honored. The mechanism is identical: keep two keys valid at once, with a window long enough for every consumer to learn about the new one before the old one is withdrawn.

Two design rules make this work in practice:

**Renew before expiry, not on expiry.** A consumer holding a five-minute lease should renew at the two-thirds mark, not when it has already expired. This leaves slack for clock skew, a slow network call, or a momentarily unavailable secrets manager. Renewing at the deadline is how you turn a transient blip into an outage.

**Size the overlap by your slowest consumer.** The overlap window must be at least as long as the slowest consumer's renewal interval plus its retry budget. A batch job that only checks its credentials every two minutes needs an overlap longer than two minutes, or it will reach for the old key after it is gone.

This is also why dynamic secrets and rotation are easier together than separately. Because every consumer is already on a renewal loop (the lease forces it), there is no special "rotation event" to coordinate. Rotation is just the normal renewal loop picking up a credential minted under the new backing key. The thing that made static secrets terrifying to rotate, the manual fan-out to every consumer, disappears when consumers renew continuously by design.

## Delivery: Injected at Runtime, Never Baked In

A short-lived, scoped credential is worthless if you deliver it by baking it into a container image or writing it into a config map that lives in version control. You have just recreated the static secret with extra steps. The credential must be **injected at runtime** and never persisted into an artifact.

The common pattern is a sidecar or an init agent that authenticates to the secrets manager, fetches the lease, and writes it to a memory-backed volume the application reads, then keeps renewing it in the background.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">runtime injection, not image-baked</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># the agent fetches and renews; the app just reads a file</span>
volume: secrets        type: memory     <span style="color:#64748b;"># tmpfs, never on disk</span>
mount:  /run/secrets   readonly: true

<span style="color:#64748b;"># app reads the current lease; the agent keeps it fresh</span>
$ cat /run/secrets/db
username=v-payments-ro-aH7kQ-1739
password=A1b2-C3d4-E5f6-G7h8     <span style="color:#64748b;"># replaced in place on each renewal</span></code></pre>
</div>

The secret lives only in memory, only for the life of the pod, and only as the current lease. There is nothing to leak in the image registry, nothing in git, nothing in a backup.

But this exposes the question that makes or breaks the whole design.

## Secret Zero: How Does the Workload Prove It Deserves Anything?

To fetch a scoped credential, the agent has to authenticate to the secrets manager. With what? If the answer is "another secret," you have an infinite regress: a secret to fetch the secret, and a secret to fetch that one. This is the **secret-zero problem**, also called bootstrapping trust. It is the question every secrets system has to answer, and the place where many of them quietly cheat by stuffing a long-lived token into the image, recreating exactly the problem we set out to solve.

The honest answer is **workload identity**: the workload proves what it is, not what it knows. Instead of presenting a shared secret, it presents an attested identity issued by the platform it runs on. A SPIFFE-style identity framework gives each workload a cryptographic identity document (an SVID) signed by an authority the secrets manager trusts. The platform attests to the workload's identity based on properties it can verify, the node it runs on, the service account, the signed image, none of which the workload can forge or copy elsewhere.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2 4 6v6c0 5 8 8 8 8s8-3 8-8V6z"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">attested identity instead of secret zero</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># the workload presents an attested SPIFFE ID, not a password</span>
spiffe id:  <span style="color:#a3e635;">spiffe://corp/ns/shop/sa/payments</span>
attested by: node + service account + signed image

<span style="color:#64748b;"># secrets manager maps that identity to a role and issues a lease</span>
identity  <span style="color:#f0abfc;">-&gt;</span>  role payments-ro  <span style="color:#f0abfc;">-&gt;</span>  5m credential
<span style="color:#64748b;"># no secret zero: nothing copyable was ever handed out</span></code></pre>
</div>

This is the same move that workload-aware platforms make for in-cluster discovery and routing, where identity comes from the platform rather than from a value the workload carries. If you have followed [how Kubernetes assigns stable identities and the platform attests to what a pod is](/2026/06/30/service-discovery-in-kubernetes.html), this is the security-side mirror of it: the cluster already knows what each workload is, so let that knowledge, not a copied token, be the thing that unlocks a credential.

With workload identity in place, there is no secret zero to leak, because there is no secret zero. The first link in the chain is an attestation the workload cannot exfiltrate and reuse from somewhere else.

## Why This Is the Core of Zero Trust

Step back and the through-line is the same one that runs through every Zero Trust mechanism: **replace standing access with short-lived, attested, auditable access.**

Standing access is a static password that works forever for anyone who holds it. Zero Trust access is a credential that is minted on proof of identity, scoped to exactly what is needed, valid for minutes, revoked automatically, and logged at issue time so you have an audit trail of exactly which identity got which credential when. A compromise of that credential is bounded in privilege, bounded in time, and attributable.

That is the whole game. The reverse proxy bounds connection-time trust. The control plane bounds session lifetime. Dynamic secrets bound credential lifetime. None of them prevents every compromise. All of them ensure that no single compromise turns into open-ended, untraceable access. The static secret in the environment variable is the one place that promise quietly broke, and dynamic secrets are how you fix it.

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">A secret that never expires is not a secret. It is a liability with a long fuse. The goal is not to keep secrets perfectly: it is to make sure that when one leaks, the clock was already running.</p>

---

*This continues my Zero Trust series, alongside [the reverse proxy as enforcement point](/2025/08/03/zero-trust-with-reverse-proxy.html) and [the control plane that revokes access in seconds](/2025/10/20/zero-trust-control-plane-and-sessions.html).*

*Working through secrets, rotation, or workload identity at scale? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
