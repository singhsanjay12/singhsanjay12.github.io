---
title: "Continuous Access Evaluation, Concretely: Closing the Token Revocation Gap"
description: "A valid bearer token survives a revocation by minutes. This is how Continuous Access Evaluation, built on OpenID Shared Signals and CAEP, streams security events so the enforcement point cuts a live session mid-flight."
date: 2026-06-08 12:00:00 +0000
categories: [Security, Zero Trust]
tags: [zero-trust, continuous-validation, cae, oauth, sessions, security]
image:
  path: /assets/img/posts/continuous-access-evaluation/hero.svg
  alt: "An identity provider pushing a session-revoked security event to a proxy that cuts a live session mid-stream"
---

When I [spoke at RSAC 2026](/2026/03/30/rsac-2026-beyond-zero-trust.html) the line that got the most nods, and the most uncomfortable silence, was this: **a bearer token is valid until it expires, and that gap between "this session should die" and "this session is dead" is measured in minutes.** Everyone in the room knew it. Almost nobody had closed it. This post is the concrete follow-up: the mechanism that closes the gap, the standards that make it interoperable, and how to actually build the loop.

If you have read the [reverse-proxy enforcement point](/2025/08/03/zero-trust-with-reverse-proxy.html) and the [control plane that backs it](/2025/10/20/zero-trust-control-plane-and-sessions.html), you already have the chassis. Continuous Access Evaluation is the wire that connects the identity provider's "this is no longer safe" to the enforcement point's "then it stops now."

## The Hidden Assumption in Every OAuth Deployment

Here is the assumption baked into almost every OAuth and OIDC deployment, and it is so normal that nobody writes it down: **a token, once issued, is trusted until its expiry, and nothing checks in between.**

The access token is a self-contained claim about the past. The identity provider signed it at issuance time, the resource server validates the signature and the expiry, and that is the whole conversation. There is no callback. There is no heartbeat. The resource server never asks the IdP "is alice still alice, and is her laptop still compliant?" It asks once, at the door, and then it believes the answer for the full lifetime of the token.

So when alice's account is disabled at 10:00, or her laptop's disk encryption is turned off at 10:03, or her refresh token is detected on a residential IP in another country at 10:05, the access token she is holding keeps working. It works until it expires on its own schedule. If that token has a fifteen-minute lifetime, you have a fifteen-minute window where the thing that justified the access is gone but the access is not. The silent failure mode is that this window is invisible. Nothing logs "we kept serving a session we should have killed," because from the resource server's point of view, the token was valid the whole time.

## The Partial Answers, and Why They Stay Partial

The industry has two standard moves to shrink this window. Both help. Neither closes it.

**The first is shorter tokens.** Drop the access token lifetime from sixty minutes to five, and the worst-case exposure drops with it. This is real, and it is the right default. But it is a tax, not a fix. Every shortened token is more refresh traffic against the IdP, more token-endpoint load, more JWKS validation, and more chances for a refresh to fail at an inconvenient moment. You are paying continuously to narrow a window you never actually close. A five-minute token still means five minutes of a compromised device acting with full authority, and you cannot push the lifetime to zero, because at zero you have rebuilt a synchronous introspection call on every request.

**The second is step-up authentication on sensitive actions.** Force a fresh factor before a wire transfer or a production deploy. This is genuinely good, and you should do it. But it only guards the actions you remembered to classify as sensitive. The interesting attacks live in the actions you did not flag: the read that exfiltrates, the lateral pivot through an endpoint nobody thought was dangerous, the slow enumeration that never trips a single "sensitive" gate. Step-up protects specific doors. It does nothing for the session walking freely through every room you left unlabeled.

Both answers share a shape: they make the polling tighter or the gates narrower. Neither changes the fundamental model, which is that the enforcement point pulls trust on a schedule it chose in advance, blind to what is actually happening to the identity right now.

## Continuous Access Evaluation: Push, Not Poll

Continuous Access Evaluation (CAE) inverts the model. Instead of the enforcement point polling the IdP, or worse, never asking again, the IdP **pushes a security event** the instant something changes, and the enforcement point reacts mid-session.

The mental picture is the hero image. A session is admitted, requests flow, and then the IdP emits a "session revoked" event. The proxy holding that session receives it, invalidates the cached decision, and cuts the connection on the next request (or proactively, if you are aggressive about it). The exposure window is no longer one token lifetime. It is one event-propagation latency, which you can drive into the low seconds.

This is the same broadcast problem I described in the [control plane post](/2025/10/20/zero-trust-control-plane-and-sessions.html), just sourced from the identity side instead of the device-certificate side. The enforcement point already re-evaluates policy per request. CAE gives that re-evaluation a live, IdP-sourced signal to read.

## The Standards: Shared Signals and CAEP

The reason this is more than a vendor feature is that it is standardized. The OpenID Foundation's **Shared Signals Framework (SSF)** defines the transport: a transmitter (the IdP) and a receiver (your enforcement point) agree on a stream, and the transmitter delivers Security Event Tokens (SETs, signed JWTs carrying a single event) over that stream. The **Continuous Access Evaluation Profile (CAEP)** sits on top of SSF and defines the security-relevant event types: the vocabulary of "what just changed."

A receiver registers a stream and tells the transmitter which event types it cares about and where to deliver them.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">SSF stream configuration · receiver subscribes to CAEP events</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># the enforcement point registers a stream with the IdP (transmitter)</span>
POST /ssf/streams
{
  <span style="color:#a3e635;">"delivery"</span>: { <span style="color:#a3e635;">"method"</span>: <span style="color:#a3e635;">"push"</span>, <span style="color:#a3e635;">"endpoint_url"</span>: <span style="color:#a3e635;">"https://proxy.internal/ssf/events"</span> },
  <span style="color:#a3e635;">"events_requested"</span>: [
    <span style="color:#a3e635;">"...caep/session-revoked"</span>,
    <span style="color:#a3e635;">"...caep/credential-change"</span>,
    <span style="color:#a3e635;">"...caep/device-compliance-change"</span>,
    <span style="color:#a3e635;">"...caep/assurance-level-change"</span>
  ]
}</code></pre>
</div>

The payoff of the standard is the same payoff TrustBridge gets from OIDC discovery: the enforcement point integrates with the event vocabulary once, and any conforming IdP can feed it. You are not hard-coding Okta's webhook shape or Entra's, you are subscribing to a stream of typed events.

## The Event Types That Matter

CAEP's value is that the events are specific. Each one carries a subject (which identity or session) and a reason, so the receiver can apply different policy to different signals.

- **Session revoked.** The strongest signal. An admin disabled the account, the user logged out everywhere, or a fraud system killed the session. This is unambiguous: cut it.
- **Credential change.** A password reset, an MFA enrollment change, a key rotation. Existing tokens minted under the old credential should not be trusted on the same footing.
- **Device compliance / posture change.** The endpoint agent reports that disk encryption was disabled, a jailbreak was detected, or the device fell out of the managed fleet. The same human is now on a less trustworthy machine.
- **Assurance-level change.** The IdP's confidence in the identity dropped, often because of a risk signal (a token replayed from an anomalous IP, an impossible-travel pattern, a sudden geo or network change).

The reason typing matters is that not every event deserves a hard cut. A confirmed session-revoked is a guillotine. A posture change might warrant a drop to a lower trust tier and a step-up prompt rather than an immediate kill. The receiver maps event type to action, and that mapping is where the real policy lives.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">a CAEP Security Event Token, decoded</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># the IdP signs and pushes this the instant the session is killed</span>
{
  <span style="color:#a3e635;">"iss"</span>: <span style="color:#a3e635;">"https://idp.example.com"</span>,
  <span style="color:#a3e635;">"iat"</span>: <span style="color:#f0abfc;">1717848000</span>,
  <span style="color:#a3e635;">"events"</span>: {
    <span style="color:#a3e635;">"...caep/session-revoked"</span>: {
      <span style="color:#a3e635;">"subject"</span>: { <span style="color:#a3e635;">"format"</span>: <span style="color:#a3e635;">"opaque"</span>, <span style="color:#a3e635;">"id"</span>: <span style="color:#a3e635;">"sess-9f3a..."</span> },
      <span style="color:#a3e635;">"event_timestamp"</span>: <span style="color:#f0abfc;">1717848000</span>,
      <span style="color:#a3e635;">"reason_admin"</span>: <span style="color:#a3e635;">"account disabled by admin"</span>
    }
  }
}</code></pre>
</div>

## Where the Enforcement Point Re-Evaluates

The receiver does two things with an event. It updates per-session state, and it decides when that state is consulted.

In a reverse-proxy architecture the natural consultation point is the next request: every request already passes through the proxy, so the cheapest correct design is to invalidate the cached decision for that subject and force a full re-evaluation on the next call. This keeps the common path fast (cached decision, no IdP round-trip) and pays the cost only when a signal actually arrived. It mirrors exactly the short, signal-bound caching I argued for at RSAC: do not run a policy engine on every request, run it when something changed.

For a session-revoked event you can be more aggressive than waiting for the next request. The proxy holds the live connection, so it can proactively send a TCP FIN and tear the session down mid-stream, the same re-origination kill switch from the [control plane post](/2025/10/20/zero-trust-control-plane-and-sessions.html). For a posture or assurance change you usually do not need to be that violent: marking the session for re-evaluation on its next request is enough, because the degraded state will be caught the moment the user does anything.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">receiver: map event type to action</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># on receiving a verified SET (signature + iss + replay window checked)</span>
on_event(evt):
    if evt.type == <span style="color:#a3e635;">"session-revoked"</span>:
        sessions.kill(evt.subject)        <span style="color:#64748b;"># hard cut, TCP FIN now</span>
    elif evt.type == <span style="color:#a3e635;">"credential-change"</span>:
        sessions.invalidate(evt.subject)  <span style="color:#64748b;"># force re-auth next request</span>
    elif evt.type == <span style="color:#a3e635;">"device-compliance-change"</span>:
        sessions.downgrade(evt.subject)   <span style="color:#64748b;"># lower trust tier, step-up</span>
    elif evt.type == <span style="color:#a3e635;">"assurance-level-change"</span>:
        sessions.mark_recheck(evt.subject)
</code></pre>
</div>

## The Tradeoffs Nobody Mentions in the Brochure

Two tensions decide whether this loop helps or hurts.

**Latency versus security.** A pushed event that takes minutes to reach the enforcement fleet is a pushed event that arrived after the damage. The whole value of CAE is propagation speed, so you have to measure it as a real number: the time from the IdP emitting the event to the last enforcement point honoring it. Treat it as an SLO, the same way I argued for treating revocation propagation as an SLO at RSAC. If you cannot say what that number is today, you do not actually know how big your window is.

**False positives versus trust.** An event stream that is too twitchy logs people out at random, and a continuous-validation system that erodes user trust is worse than an honest gate, because people stop believing the signal. This is why event typing matters: reserve the hard cut for unambiguous events (confirmed session revocation, confirmed credential theft) and degrade gracefully (lower tier, step-up factor) for the softer signals. The receiver's job is not to react maximally to every event. It is to react proportionally.

## Building the Loop

Start where the gap is widest, not where the work is easiest. The order I would take it:

First, **measure your real exposure window**: not the token lifetime you configured, but the wall-clock time from "account disabled" to "every session for that account is gone." That number is almost always worse than people think, and it is the number CAE moves. Second, **subscribe one enforcement point to one event type**, session-revoked, end to end, and verify a real revocation cuts a real live session in seconds. Third, **add the softer events with graceful degradation** rather than hard cuts, and tune against a false-positive budget you decide up front. Fourth, **make the propagation latency an SLO** with an alert, because a CAE loop that silently slows to minutes has quietly become the polling model you replaced.

The point is not to add another control. You almost certainly own all the pieces already: an IdP that can emit events, an enforcement point that re-evaluates per request, a session store you can invalidate. The point is to connect them into a closed loop so that "this should stop" and "this stopped" become the same moment instead of fifteen minutes apart.

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">A token is a promise the identity provider made in the past. Continuous Access Evaluation is how it tells you, the instant it changes its mind, that the promise no longer holds.</p>

---

*This is the concrete follow-up to my [RSAC 2026 talk on continuous validation](/2026/03/30/rsac-2026-beyond-zero-trust.html), and it builds on the Zero Trust series: the [reverse-proxy enforcement point](/2025/08/03/zero-trust-with-reverse-proxy.html) and the [control plane and sessions](/2025/10/20/zero-trust-control-plane-and-sessions.html).*

*Building this loop in your own stack, or measuring your real revocation window for the first time? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
