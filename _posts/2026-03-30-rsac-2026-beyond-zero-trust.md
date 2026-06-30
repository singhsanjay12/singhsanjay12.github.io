---
title: "Beyond Zero Trust: What Speaking at RSAC 2026 Taught Me About Continuous Validation"
description: "I gave a talk at RSA Conference 2026 called 'Beyond Zero Trust: Continuous Validation for Modern Enterprise Security.' This is the argument I made on stage, the pushback I got from the room, and what I am taking back to the code."
date: 2026-03-30 12:00:00 +0000
categories: [Security, Zero Trust]
tags: [zero-trust, continuous-validation, rsac, conference, security, control-plane, session-management]
image:
  path: /assets/img/posts/rsac-2026/hero.svg
  alt: "A user session being continuously re-validated over time, with access cut the moment a signal turns risky"
---

On March 23 I stood in front of a room at RSA Conference 2026 and made an argument I have been turning over for two years: **Zero Trust is not a thing you deploy. It is a thing you keep doing.** The talk was titled *Beyond Zero Trust: Continuous Validation for Modern Enterprise Security*, and this post is the written version of it, including the parts the room disagreed with.

[![On stage at RSA Conference 2026 presenting Beyond Zero Trust, with a slide titled From Flat Network to Enforced Trust Zones](/assets/img/posts/rsac-2026/rsac-talk-stage.jpg)](https://www.rsaconference.com/Library/presentation/USA/2026/Beyond%20Zero%20Trust%20Continuous%20Validation%20for%20Modern%20Enterprise%20Security)
_On stage at RSAC 2026, walking through how a flat network becomes enforced trust zones._

> 🎤 **Watch the full session on demand:** [Beyond Zero Trust: Continuous Validation for Modern Enterprise Security](https://www.rsaconference.com/Library/presentation/USA/2026/Beyond%20Zero%20Trust%20Continuous%20Validation%20for%20Modern%20Enterprise%20Security) on the RSA Conference library.

If you have read my earlier posts on building a Zero Trust enforcement point with a [reverse proxy](/2025/08/03/zero-trust-with-reverse-proxy.html) and the [control plane that backs it](/2025/10/20/zero-trust-control-plane-and-sessions.html), this is the natural next chapter. Those posts were about closing the perimeter and revoking access fast. This talk was about the uncomfortable space in between: everything that happens to a session *after* it is allowed in.

## Authentication Is a Moment. Trust Is a Duration.

The sentence I opened with was deliberately provocative: most "Zero Trust" deployments are still gate-based. A user authenticates, the device presents a certificate, a policy evaluates once, and a session is issued. From that point forward the session is treated as trustworthy until it expires. That is not Zero Trust. That is a longer-lived perimeter with a nicer login page.

The original Zero Trust principle is "never trust, always verify." The word doing the heavy lifting is **always**. Verification at the door is a moment. The session that the door issues lasts for minutes or hours, and during that time the world changes. The laptop that was compliant at 9am has disabled disk encryption by 11am. The user who logged in from the office is now tunneling through a residential VPN. The token that was issued to a human is now being replayed by something that is not a human.

Continuous validation is the answer to a simple question: if the conditions that justified access disappear, how long does the access survive them?

## Why "We Did Zero Trust" Is the Wrong Sentence

Almost every conversation I had in the hallway started with some version of "we already did Zero Trust." I started asking a follow-up: *what re-evaluates an active session, and how often?* The answers clustered into three buckets.

Most often, the answer was "the token expires." That is time-based, not signal-based. A 30-minute token means a compromised device has a 30-minute window where nothing is watching. Refresh-token rotation narrows the blast radius but does not close it, because rotation re-checks possession of a credential, not the posture of the thing holding it.

Sometimes the answer was "we step up on sensitive actions." Better, but it only covers the actions you remembered to flag. The interesting attacks live in the actions you did not classify as sensitive.

Rarely, the answer was "we stream device and identity signals into the session and cut it mid-flight when they degrade." That is continuous validation, and the teams doing it had usually built it the hard way, after an incident.

The gap between "we authenticate with strong factors" and "we continuously validate the session" is where most of the real risk sits. It is invisible on an architecture diagram because the boxes look identical. The difference is entirely in the time dimension.

## What Continuous Validation Actually Looks Like

The mechanism is not exotic. It is the control plane from my [Part Two post](/2025/10/20/zero-trust-control-plane-and-sessions.html), pointed inward at live sessions instead of only at the login event.

Three things have to be true. First, the enforcement point has to re-evaluate policy on a cadence or on a signal, not only at session creation. In a reverse-proxy architecture this is natural: every request already passes through the proxy, so every request is an opportunity to ask "is this still allowed?" rather than "was this allowed an hour ago?"

Second, the signals that policy reads have to be live. Device posture from the endpoint agent, a risk score from the identity provider, behavioral anomalies from the session itself. These feed the policy decision continuously, so a posture change propagates into an access decision in seconds rather than at the next login.

Third, revocation has to be fast and global. A risk signal that takes minutes to reach the enforcement fleet is a risk signal that arrives after the damage. This is the part I spent the most time on in the earlier posts, because it is the part that is genuinely hard at scale: broadcasting a "this session is dead" decision to every proxy instance before the next request lands.

Put together, the session in the hero image is the mental model. It is allowed in, then re-checked at every step against device posture, risk, and behavior. The moment a check fails, the session is cut. The user does not get to ride out the rest of a 30-minute token on a now-compromised laptop.

## What the Room Pushed Back On

The best part of the talk was not the talk. It was the questions, and three of them were sharp enough that I want to record them honestly rather than pretend the model is free of cost.

**"Does per-request evaluation wreck your latency?"** It can, if you evaluate naively. The answer is to make the common case cheap: cache the policy decision with a short, signal-bound lifetime, and only do a full re-evaluation when a signal actually changes or the cache entry ages out. The enforcement point holds a small amount of per-session state and invalidates it on a pushed signal. You are not running a full policy engine on every request. You are running it when something changed.

**"Won't you log people out constantly with false positives?"** This is the real tension, and it is a product decision as much as a security one. Continuous validation that is too twitchy trains users to expect random logouts, which is its own security failure because people stop trusting the signal. The teams that got this right tuned for graceful degradation: drop to a lower trust tier and ask for a step-up factor before hard-revoking, and reserve the hard cut for unambiguous signals like a posture failure or a confirmed credential theft.

**"Is this just a vendor feature with a new name?"** Fair, and I said so. Continuous Access Evaluation exists as a standard, several IdPs ship versions of it, and the mesh and proxy ecosystems have the primitives. The reason it still belongs in a talk is that having the primitives and operating them as a coherent loop are very different things. Most orgs own all the pieces and have never connected them into a closed loop. The talk was about the loop, not the parts.

## What I Am Taking Back to the Code

I left with a short list, and it is mostly about closing gaps rather than building something new.

The first item is auditing where our own sessions are time-bound versus signal-bound, because I suspect the honest answer is "mostly time-bound, and we tell ourselves otherwise." The second is measuring revocation propagation as a real SLO, the time from a risk signal to the last enforcement point honoring it, because you cannot improve a number you do not look at. The third is being deliberate about the false-positive budget, since a continuous validation system that erodes user trust is worse than an honest gate.

The framing I will keep using is the one I opened with. A login is a photograph. It tells you the session was trustworthy at the instant the shutter clicked. Continuous validation is the video. The whole point of Zero Trust was never to take a better photograph. It was to keep watching.

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">The session that was safe to admit an hour ago is a claim about the past. Zero Trust is the discipline of refusing to keep believing it for free.</p>

---

*The full talk is [available to watch on demand](https://www.rsaconference.com/Library/presentation/USA/2026/Beyond%20Zero%20Trust%20Continuous%20Validation%20for%20Modern%20Enterprise%20Security) in the RSA Conference library. It built directly on my two-part series on Zero Trust with a reverse proxy: [Part One](/2025/08/03/zero-trust-with-reverse-proxy.html) on the enforcement point, and [Part Two](/2025/10/20/zero-trust-control-plane-and-sessions.html) on the control plane and sessions.*

*Were you in the room at RSAC, or working through continuous validation in your own stack? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
