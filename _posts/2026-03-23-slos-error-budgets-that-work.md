---
title: "SLOs and Error Budgets That Actually Change Behavior"
description: "Most SLOs are decorative: a dashboard nobody acts on, a target that pages on noise, a number gamed to look healthy. Here is how to build SLIs that reflect user experience, set targets that are honest, and turn an error budget into the lever that decides whether you ship or freeze."
date: 2026-03-23 12:00:00 +0000
categories: [Distributed Systems, Observability]
tags: [slo, error-budget, observability, reliability, sre, distributed-systems]
image:
  path: /assets/img/posts/slos-error-budgets/hero.svg
  alt: "An SLI feeding an SLO target, a draining error budget gauge, and two burn-rate alerts: a fast burn that pages now and a slow burn that opens a ticket"
---

Most SLOs are decorative. There is a dashboard with a green number on it, a quarterly review where someone says reliability is "on track," and a target that nobody has ever used to make an actual decision. The number exists, but it does not change what anyone does on a Tuesday. That is the failure I want to talk about: not the math of SLOs, which is simple, but the question of whether the SLO is wired into any decision at all.

A good SLO is not a reporting artifact. It is a **lever**. It tells you, with no debate, whether to ship the next feature or stop and stabilize. If your SLO cannot answer that question, it is not doing its job, no matter how precise the percentage on the slide.

## The Four Golden Signals, and Turning Them Into SLIs

The starting point is the four golden signals: **latency, traffic, errors, and saturation**. They are a good checklist for what to measure, but they are not yet SLIs. The jump from signal to SLI is where most teams quietly go wrong.

An **SLI** (Service Level Indicator) is a number that measures one thing: how good the service was, from the perspective of whoever depends on it. The trap is measuring server internals instead of user experience. CPU at 70 percent is a saturation signal, but no user cares about your CPU. They care whether their request succeeded and how long it took. The SLI has to live at the boundary the user actually touches.

So the useful framing of each signal is a ratio of good events to total events:

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="20" x2="18" y2="10"/><line x1="12" y1="20" x2="12" y2="4"/><line x1="6" y1="20" x2="6" y2="14"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">SLI as a good-events ratio</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># availability SLI: fraction of requests that did not fail</span>
availability = good_requests / total_requests

<span style="color:#64748b;"># latency SLI: fraction served fast enough (a threshold, not an average)</span>
latency = requests_under_300ms / total_requests

<span style="color:#64748b;"># measure at the edge the user touches, not deep in the server:</span>
<span style="color:#64748b;">#   good_requests = status not in (500,502,503,504) AND served_within_SLA</span></code></pre>
</div>

Two details carry most of the value. First, **latency is a threshold, not an average**. An average of 200ms hides the 5 percent of users sitting at two seconds, and those are the users who leave. The SLI is "what fraction of requests came in under 300ms," because that maps to an experience, not to a statistic. Second, **measure where the user is**. A request that your server thinks succeeded but that timed out at the load balancer is a failure to the user, and your SLI should count it as one. This is the same lesson as [health checking from the client versus the server side](/2026/01/12/health-checks-client-vs-server-side-lb.html): the server's opinion of its own health is not the same as the caller's experience, and the SLI must be anchored to the caller.

## SLI, SLO, SLA: Three Words That Are Not Interchangeable

These three get used as synonyms, and the confusion is expensive.

The **SLI** is the measurement: 99.95 percent of requests succeeded last week. The **SLO** (Service Level Objective) is the target you set for that measurement: "99.9 percent of requests should succeed over a rolling 28 days." It is an internal promise, the line you hold yourself to. The **SLA** (Service Level Agreement) is the external contract with consequences: if availability drops below 99.5 percent, the customer gets a refund.

The ordering matters. Your SLO should always be stricter than your SLA, because the SLO is your early warning and the SLA is the cliff. If your SLA promises 99.5 percent, you might run an SLO at 99.9 percent, giving yourself margin to react before you breach the contract that costs money.

And the most important target decision: **100 percent is the wrong objective.** It sounds responsible to aim for zero errors, but it is a trap. The cost of each additional nine grows roughly tenfold while the user-visible benefit shrinks toward nothing. Worse, a 100 percent target means you can never take a risk: no deploys, no dependency upgrades, no experiments, because any of them might cause a single error. The right target is the **lowest reliability your users will not notice**, and not a fraction higher. That gap between 100 percent and your target is not slack. It is the budget you are about to spend on velocity.

## The Error Budget Is the Whole Point

Here is the idea that makes SLOs operational rather than decorative. If your SLO is 99.9 percent, then you are explicitly allowing 0.1 percent of requests to fail. That allowance is your **error budget**: the amount of unreliability you have permission to spend over the window.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="1" x2="12" y2="23"/><path d="M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">error budget math</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">SLO            = 99.9% over 28 days
error_budget   = 100% - 99.9%  =  0.1% of requests

<span style="color:#64748b;"># at 10,000 requests per second over 28 days:</span>
total_requests = 10000 * 86400 * 28        = ~24.2 billion
budget         = 0.1% of that              = ~24.2 million failures allowed

<span style="color:#64748b;"># in wall-clock terms of full downtime:</span>
0.1% of 28 days = ~40 minutes of total outage budget per window</code></pre>
</div>

The budget is the **bridge between reliability and velocity**, and it resolves an argument that otherwise runs forever. Reliability teams want to slow down and harden; product teams want to ship. The error budget settles it with a rule instead of a meeting:

- **Budget remaining: ship.** You are within your reliability promise, so spend the budget on velocity. Deploy, run the risky migration, push the experiment. Burning budget on purpose is allowed, because that is what it is for.
- **Budget burned: freeze and stabilize.** When the budget is exhausted, feature work stops and reliability work starts. No new risk until the window rolls forward and the budget refills.

This reframes reliability from "be as reliable as possible," which has no stopping rule, into "stay inside the budget," which does. It also makes the tradeoff honest. A team that never burns its budget is not being heroic; it is being too cautious and leaving velocity on the table. A team that blows through it is shipping recklessly. The budget makes both visible as numbers rather than opinions.

## Burn-Rate Alerting, Not Threshold Alerting

Now the part that separates an SLO you act on from a pager that cries wolf. The naive way to alert is on a threshold: page when the error rate crosses 1 percent. This is terrible. A brief 1 percent blip pages someone at 3am for an incident that self-healed, and a steady 0.3 percent leak that will quietly eat your whole monthly budget never pages at all. Threshold alerts fire on noise and miss slow bleeds.

The better mechanism is **burn rate**: how fast you are consuming the error budget relative to the rate that would exhaust it exactly at the end of the window. A burn rate of 1 means you will spend the budget precisely on schedule. A burn rate of 14 means you will be out of budget in about a day. Alert on the rate of consumption, not the instantaneous error level.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="23 6 13.5 15.5 8.5 10.5 1 18"/><polyline points="17 6 23 6 23 12"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">multi-window burn-rate alert</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># burn_rate = error_rate / (1 - SLO)</span>
<span style="color:#64748b;"># SLO 99.9% -&gt; budget 0.1%; a 1.4% error rate is a burn rate of 14</span>

<span style="color:#94a3b8;">FAST BURN</span>  (page now): burn_rate &gt;= 14 over 5m  AND over 1h
                           <span style="color:#64748b;"># ~2% of budget in an hour; wake someone</span>

<span style="color:#94a3b8;">SLOW BURN</span>  (ticket):   burn_rate &gt;= 3  over 1h  AND over 6h
                           <span style="color:#64748b;"># a steady leak draining the month; fix in hours</span>

<span style="color:#64748b;"># the second (longer) window is the noise filter:</span>
<span style="color:#64748b;"># a 90-second blip clears the 5m window but never the 1h one,</span>
<span style="color:#64748b;"># so it never pages.</span></code></pre>
</div>

The **multi-window** trick is what kills the false pages. Each alert requires the burn rate to be high over both a short window and a longer one. The short window makes the alert react quickly to a real, severe burn. The long window makes sure the condition is sustained, not a momentary spike. A transient blip trips the short window but clears the long one, so no page. This is the same instinct as draining and health gates in the load-balancing world: you want to react to sustained reality, not to one bad sample, the same way [load-balancing algorithms](/2026/03/02/load-balancing-algorithms.html) smooth over a single slow response rather than ejecting a backend on one timeout.

You typically run two or three of these in parallel: a fast-burn alert that pages a human because the budget is vanishing in hours, and a slow-burn alert that opens a ticket because a quiet leak will eat the month if left alone. The fast burn protects against the outage; the slow burn protects against the death by a thousand cuts that threshold alerts never catch.

## Why Most SLOs Stay Decorative

With the mechanics in place, here is the honest part: most SLOs still fail to change anything, and it is usually one of three reasons.

**The SLI is wrong.** It measures the server, not the user. It tracks average latency, so it never sees the slow tail. It counts a request as successful when the backend returned 200, even though the response was a useless error page or arrived after the client gave up. If the SLI does not move when users are unhappy, no target built on it will ever mean anything. This is the most common and most fatal mistake, and it traces straight back to measuring internals instead of the experience at the edge, the same edge problem that shows up in [how a reverse proxy actually sees a request succeed or fail](/2026/03/09/concurrent-requests-reverse-proxy.html).

**There is no enforcement.** The budget burns, the dashboard turns red, and the team ships anyway because nobody agreed in advance that a burned budget means a freeze. An error budget with no policy attached is just a chart. The decision rule (ship when there is budget, freeze when there is not) has to be agreed before the budget burns, by the people who own both reliability and roadmap, or it will be argued away in the moment exactly when it matters.

**The target is gamed.** When the SLO becomes a number someone is measured on, the incentive flips from "serve users well" to "make the number look good." Teams quietly exclude error classes, redefine "good" until almost everything qualifies, or pick a forgiving window that hides bad days inside good months. The target turns green and the users are still unhappy. An SLO that is optimized as a metric instead of used as a signal has stopped describing reality.

The SLOs that actually work share one property: someone has, at least once, made a real and uncomfortable decision because of one. They delayed a launch because the budget was gone. They told a product team "yes, ship it, we have room." The moment an SLO causes a decision that would otherwise have gone the other way, it stops being decoration and starts being infrastructure.

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">An SLO is not a number you report. It is a number you obey. If no decision in your team has ever gone the other way because of it, you do not have an SLO. You have a dashboard.</p>

---

*This connects to my earlier writing on [health checking in client vs server-side load balancing](/2026/01/12/health-checks-client-vs-server-side-lb.html), [load-balancing algorithms](/2026/03/02/load-balancing-algorithms.html), and [how reverse proxies handle requests at scale](/2026/03/09/concurrent-requests-reverse-proxy.html).*

*Wiring SLOs into real ship-or-freeze decisions on your team? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
