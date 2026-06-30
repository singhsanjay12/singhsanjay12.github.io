---
title: "TCP Congestion Control at Scale: Why BBR Changed the Game"
description: "Congestion control quietly decides how fast every connection can push. Cubic treats packet loss as the signal and fills buffers along the way; BBR models the bottleneck directly. Here is how each works, the tradeoffs, and where it matters across a traffic fleet."
date: 2026-04-23 12:00:00 +0000
categories: [Distributed Systems, Networking]
tags: [tcp, congestion-control, bbr, networking, performance, distributed-systems]
image:
  path: /assets/img/posts/tcp-congestion-bbr/hero.svg
  alt: "Loss-based Cubic filling a router buffer to a sawtooth until packets drop, beside BBR pacing to the measured bottleneck bandwidth and round-trip propagation time"
---

Every TCP connection carries a hidden governor. It is not the application, not the socket buffer, not the link speed. It is the **congestion control algorithm**, the piece of the sender that decides, packet by packet, how much data is allowed to be in flight before an acknowledgment comes back. You never configure it directly, you rarely think about it, and most of the time it does its job invisibly. Then one day a cross-region transfer that should saturate a 10 Gbps link tops out at 200 Mbps, or your p99 latency doubles under load that the servers handled fine, and you discover that the governor has been quietly limiting you the entire time.

Congestion control is invisible until it limits your throughput or inflates your tail latency. This post is about the two algorithms most of a modern fleet runs on, **Cubic** and **BBR**, why they make opposite assumptions about what congestion even is, and what that difference does to real traffic.

## What Congestion Control Actually Decides

The sender keeps a number called the **congestion window** (cwnd): the amount of unacknowledged data it will allow on the wire at once. Throughput is roughly the window divided by the round-trip time. Make the window too small and you leave the link idle. Make it too large and you overflow a buffer somewhere in the path, packets drop, and everything stalls while TCP recovers.

The whole game is estimating the right window without anyone telling you what the path can carry. There is no signal from the network that says "the bottleneck is 1 Gbps and the queue is half full." The sender has to infer the state of a path it cannot see, using only the two things it can observe: which packets got acknowledged, and how long the acknowledgments took. Every congestion control algorithm is a different theory of how to turn those two observations into a window.

The theory you pick determines what the connection optimizes for, and the two dominant families pick opposite theories.

## Loss-Based Control: Treat a Drop as the Stop Sign

The classic family (Reno, and its modern default descendant **Cubic**) uses one signal above all: **packet loss means congestion.** The logic is intuitive. Routers have finite buffers. When you send faster than the bottleneck drains, the buffer fills, and when it overflows, packets drop. So a drop is the network telling you that you went too far. Back off, then probe back up.

Cubic does this with a window that grows along a cubic curve: fast when it is far below the last point where loss happened, cautious as it approaches that point, then aggressive again past it to discover new capacity. On a clean, deep-buffered link this works remarkably well, which is why it became the Linux default and carries most of the internet today.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">loss-based logic · pseudocode</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#94a3b8;">on</span> ack_received:
    cwnd = cubic_growth(cwnd, time_since_last_loss)  <span style="color:#64748b;"># grow toward last known limit</span>

<span style="color:#94a3b8;">on</span> packet_lost:                 <span style="color:#64748b;"># the ONLY congestion signal that counts</span>
    w_max  = cwnd                <span style="color:#64748b;"># remember where it broke</span>
    cwnd   = cwnd * <span style="color:#f0abfc;">0.7</span>          <span style="color:#64748b;"># multiplicative decrease, then climb back</span>

<span style="color:#64748b;"># Implication: the algorithm only learns the limit by exceeding it.</span>
<span style="color:#64748b;"># It must fill the buffer and cause a drop to find the edge.</span></code></pre>
</div>

That last line is the catch, and it is a big one. A loss-based algorithm finds the path limit by **exceeding it on purpose**. To know the buffer is full, it has to fill the buffer. This produces two silent failure modes that show up constantly at fleet scale.

The first is **bufferbloat**. Modern routers and middleboxes ship with enormous buffers, sometimes hundreds of milliseconds deep. Cubic happily fills them, because a packet sitting in a fat queue is not lost, it is just delayed, and delay is not a signal Cubic listens to. So the connection runs with a full queue more or less permanently. Throughput looks fine. But every packet now waits behind that standing queue, and your round-trip time, the very thing that drives your tail latency, balloons. The link is not congested in any harmful sense, yet latency is wrecked.

The second is the opposite environment: **shallow-buffer, lossy links**. On Wi-Fi, cellular, or a long-haul path with a tiny bit of random (non-congestion) packet loss, Cubic misreads. A packet dropped by radio interference looks identical to a packet dropped by a full buffer, so Cubic slams the window down even though the path is wide open. On a long-fat network (high bandwidth, high latency) the recovery is brutally slow, because the window climbs back one round-trip at a time. A 0.1% random loss rate, harmless in principle, can cap a transcontinental transfer at a fraction of the available bandwidth. This is exactly the regime where I have watched a healthy [load-balanced backend](/2026/03/02/load-balancing-algorithms.html) look slow for reasons that had nothing to do with the backend.

## BBR: Model the Pipe Instead of Probing for the Drop

BBR (Bottleneck Bandwidth and Round-trip propagation time) starts from a different premise. Loss is a lagging, ambiguous signal. So stop using it as the primary one. Instead, **build a model of the path** from what the acknowledgments actually reveal, and pace the sender to that model.

Two measurements drive it. The maximum delivery rate the sender has recently observed estimates the **bottleneck bandwidth**: how fast the narrowest link in the path can drain data. The minimum round-trip time recently observed estimates the **round-trip propagation delay**: the physical latency of the path with no queuing. Multiply them and you get the bandwidth-delay product, the exact amount of data needed to keep the pipe full and no more. BBR aims to keep precisely that much in flight: enough to saturate the bottleneck, not enough to build a standing queue.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">BBR model · pseudocode</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#94a3b8;">on</span> ack_received:
    btl_bw  = max(delivery_rate, recent_window)   <span style="color:#64748b;"># fastest rate we have seen</span>
    rt_prop = min(rtt, recent_window)             <span style="color:#64748b;"># lowest RTT (no queue) we have seen</span>

    bdp        = btl_bw * rt_prop                 <span style="color:#64748b;"># exactly fills the pipe, no more</span>
    pacing_rate = btl_bw                          <span style="color:#64748b;"># send AT the bottleneck rate, paced evenly</span>
    cwnd        = <span style="color:#f0abfc;">2</span> * bdp                       <span style="color:#64748b;"># small headroom for ack timing</span>

<span style="color:#64748b;"># A single random drop does NOT collapse the window.</span>
<span style="color:#64748b;"># Loss is an input to the model, not the stop sign.</span></code></pre>
</div>

The consequences are exactly where loss-based control struggled. Because BBR paces to the bottleneck rate rather than slamming bytes out and waiting for a drop, it does not build a standing queue, so it sidesteps bufferbloat: throughput stays high and latency stays near the propagation floor. And because a single random loss is just noise in the bandwidth estimate rather than a stop sign, BBR keeps moving on lossy long-fat links where Cubic would have collapsed. Google reported large throughput gains pushing BBR across its edge and onto YouTube delivery for precisely these reasons: long, lossy, high-bandwidth paths to users.

It is the same shift in thinking I keep coming back to elsewhere in the stack: stop reacting to a crude after-the-fact failure signal, and instead **maintain a live model of the resource you are actually using.** That is the same instinct behind keeping a real-time view of healthy endpoints rather than waiting for a request to fail, which I wrote about in [when DNS load balancing is not enough](/2026/02/24/when-dns-load-balancing-is-not-enough.html).

## The Tradeoffs and the Controversy

BBR is not a free upgrade, and the honest version of this story includes where it hurts.

The loudest objection is **fairness with Cubic flows**. When BBR and Cubic share a bottleneck, they are playing by different rules. BBR paces to its model and does not interpret the queue Cubic builds as a reason to back off the way another Cubic flow would. Depending on buffer depth and the number of flows, BBRv1 could take more than its arithmetic share, starving the Cubic flows next to it, or in deep-buffer cases give up share to them. In a shared internet, where you cannot dictate what algorithm everyone else runs, "behaves well next to Cubic" is not optional, and BBRv1 did not fully clear that bar.

That is much of why **versions matter**. BBRv1 (2016) ignored loss almost entirely and could be unfair and could overshoot on shallow buffers. BBRv2 added an explicit response to loss and to ECN (explicit congestion notification) signals, trading a little raw throughput for far better coexistence with loss-based flows. BBRv3 refined the model and convergence further. If someone says "we tried BBR and it was unfair" or "we tried BBR and it was great," the first question is always which version, on which kernel, against which competing traffic.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">setting the algorithm on Linux</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># which algorithms the kernel can run</span>
$ sysctl net.ipv4.tcp_available_congestion_control
net.ipv4.tcp_available_congestion_control = reno cubic bbr

<span style="color:#64748b;"># switch the default sender side to bbr</span>
$ sysctl -w net.ipv4.tcp_congestion_control=bbr

<span style="color:#64748b;"># bbr pairs best with fair-queue pacing in the qdisc</span>
$ tc qdisc add dev eth0 root fq

<span style="color:#64748b;"># per-socket override (an app can choose its own):</span>
<span style="color:#64748b;">#   setsockopt(fd, IPPROTO_TCP, TCP_CONGESTION, "bbr", 4)</span></code></pre>
</div>

There are also paths where BBR simply does not help, or hurts. On short, clean, deep-buffered datacenter links, Cubic was never the bottleneck, so there is little to gain and a real risk of regressing if the BBR model misestimates. And BBR is a **sender-side** decision: it improves the direction you are sending. It does nothing for the receive direction unless the other end also runs it, which matters when you reason about where to deploy it.

## Where It Shows Up Across a Traffic Fleet

This stops being academic the moment you run servers that talk to the wider internet. A few places where the choice is load-bearing.

**Edge servers terminating user connections.** The last mile to users is the canonical lossy, variable-RTT path: mobile radios, congested home links, far-flung geographies. This is BBR's strongest case, and it is why it tends to land first on edge tiers and CDN nodes. Higher goodput to real users on bad networks is a direct product metric, not a lab number.

**Cross-region and backbone links.** Long-fat pipes between datacenters are where loss-based recovery is slowest and BBR's pipe model pays off most. A bulk replication or backup stream that Cubic caps at a fraction of a link can come much closer to filling it under BBR.

**CDN and large-object delivery.** Throughput on big responses, video segments, images, downloads, is dominated by how fast the window opens and how it survives loss. The same connection-management discipline that makes a [reverse proxy efficient under concurrency](/2026/03/09/concurrent-requests-reverse-proxy.html) is undercut if every one of those connections is throttled by a pessimistic congestion controller.

**The interaction with load balancing and retries** is the subtle one. Congestion control shapes the latency distribution that everything upstream reacts to. If Cubic bufferbloat inflates RTT, a [least-latency or latency-aware load balancer](/2026/03/02/load-balancing-algorithms.html) sees a distorted picture and may steer traffic on bad data. Worse, retries and congestion control feed each other: a connection stalled because Cubic collapsed on random loss can trip a client timeout, the client retries, and the retry adds load to a path that was not actually congested. Switching the edge to BBR can quietly cut a class of timeout-driven retries that looked like an application problem and were really a transport problem.

The throughline is the one this blog keeps returning to: the layers you treat as invisible infrastructure are making decisions for you, on assumptions you did not choose. Cubic assumes loss means congestion. BBR assumes it can model the pipe. Neither is universally right. But knowing which one is running, and what it believes about your network, is the difference between tuning a system you understand and being surprised by one you do not.

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">Congestion control is the most consequential setting most engineers never touch. Cubic learns the limit by crashing into it. BBR tries to picture the pipe before it does. The win is not a magic flag: it is matching the algorithm's assumptions to the network you actually run on.</p>

---

*This connects to my earlier writing on [load balancing algorithms](/2026/03/02/load-balancing-algorithms.html), [concurrent connections in reverse proxies](/2026/03/09/concurrent-requests-reverse-proxy.html), and [when DNS load balancing is not enough](/2026/02/24/when-dns-load-balancing-is-not-enough.html).*

*Tuning transport behavior across an edge or backbone fleet? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
