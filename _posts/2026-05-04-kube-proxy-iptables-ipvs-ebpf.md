---
title: "How kube-proxy Actually Routes a Packet: iptables vs IPVS vs eBPF"
description: "A ClusterIP is a virtual IP that nothing actually listens on. kube-proxy programs the kernel to rewrite it into a real pod, and the way it does that (iptables, IPVS, or eBPF) decides how your cluster behaves at scale."
date: 2026-05-04 12:00:00 +0000
categories: [Distributed Systems, Kubernetes]
tags: [kubernetes, kube-proxy, iptables, ipvs, ebpf, cilium, networking]
image:
  path: /assets/img/posts/kube-proxy-dataplane/hero.svg
  alt: "A packet sent to a ClusterIP being DNAT'd to one of several backend pods through three interchangeable dataplanes: iptables linear chains, IPVS hash tables, and eBPF maps"
---

There is a small lie at the center of every Kubernetes cluster, and it is load-bearing. When you resolve a `Service` and get back a `ClusterIP`, you get an address that **nothing actually listens on**. No process is bound to it. No NIC owns it. If you tried to find it with `ip addr`, it would not be there. It is a number that exists only so that the kernel can rewrite it into something real before the packet ever leaves the node.

The component that maintains that fiction is **kube-proxy**, and the interesting part is not that it does this. It is *how*. kube-proxy is really a translator from the Kubernetes API into kernel dataplane rules, and it has three very different backends to choose from: iptables, IPVS, and (increasingly) eBPF. They all answer the same question (where does a packet to a virtual IP go?), but they answer it with wildly different performance characteristics, and the one your cluster happens to run is usually an accident of when and how it was installed.

This is the data-plane companion to my post on [how service discovery actually works in Kubernetes](/2026/06/30/service-discovery-in-kubernetes.html). That post got you a ClusterIP from a name. This one follows the packet after that, into the kernel, where the load balancing actually happens, and connects to the [load-balancing algorithms](/2026/03/02/load-balancing-algorithms.html) those dataplanes do (or do not) implement.

## The Job: Rewrite a Virtual IP Into a Real One

Strip away the modes and kube-proxy does exactly one thing. It watches the API for `Service` and `EndpointSlice` objects, and for every ClusterIP it programs the node's kernel so that a packet addressed to that VIP is **DNAT'd** (destination network address translation) to one of the ready backend pod IPs.

Consider a Service `payments` with ClusterIP `10.96.0.21:8080` backed by three pods.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">what kube-proxy is translating</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># the fiction the client sees</span>
$ curl http://10.96.0.21:8080/charge

<span style="color:#64748b;"># the EndpointSlice kube-proxy is watching (the real backends)</span>
endpoints:
  - <span style="color:#a3e635;">10.1.7.4</span>:8443    <span style="color:#64748b;"># ready</span>
  - <span style="color:#a3e635;">10.1.7.9</span>:8443    <span style="color:#64748b;"># ready</span>
  - <span style="color:#a3e635;">10.1.8.2</span>:8443    <span style="color:#64748b;"># ready</span>

<span style="color:#64748b;"># the kernel must rewrite 10.96.0.21:8080 -&gt; one of those, per connection</span></code></pre>
</div>

Three things have to be true for this to work. The rewrite must be **per connection** and sticky for that connection's lifetime (you cannot bounce an established TCP flow to a different pod mid-stream). The return traffic must be **un-rewritten** so the client thinks it talked to the ClusterIP it dialed. And the choice of backend must be **load-balanced** across ready endpoints. The differences between the modes are entirely about how the kernel stores and evaluates those rewrite rules.

## iptables Mode: Correct, Simple, and Linear

iptables mode is the historical default, and it is the one most clusters silently run. kube-proxy expresses the whole Service catalog as netfilter rules. For each Service it installs a jump rule in the `nat` table that matches the ClusterIP, then a chain that picks a backend using the `statistic` module's probability matching, then a per-endpoint chain that performs the DNAT.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">iptables rules for one Service</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># match the ClusterIP, jump to the Service chain</span>
-A KUBE-SERVICES -d <span style="color:#a3e635;">10.96.0.21</span>/32 -p tcp --dport <span style="color:#f0abfc;">8080</span> -j KUBE-SVC-PAY

<span style="color:#64748b;"># pick a backend by probability (1/3, then 1/2 of the rest, then last)</span>
-A KUBE-SVC-PAY -m statistic --mode random --probability <span style="color:#f0abfc;">0.333</span> -j KUBE-SEP-A
-A KUBE-SVC-PAY -m statistic --mode random --probability <span style="color:#f0abfc;">0.500</span> -j KUBE-SEP-B
-A KUBE-SVC-PAY -j KUBE-SEP-C

<span style="color:#64748b;"># the actual DNAT to a pod IP</span>
-A KUBE-SEP-A -p tcp -j DNAT --to-destination <span style="color:#a3e635;">10.1.7.4</span>:8443</code></pre>
</div>

This is correct and easy to inspect, and for a small cluster it is genuinely fine. The problem is structural: netfilter evaluates rules as a **linear, ordered list**. The `KUBE-SERVICES` chain is walked top to bottom until a packet matches. With a handful of Services that is nothing. With ten thousand Services, each with several endpoints, you are looking at tens of thousands of rules that the kernel may traverse, and rule evaluation is **O(n)** in the number of rules.

Two costs bite here, and people conflate them. The first is the per-packet matching cost, which mostly affects connection setup. The second, and usually the worse one, is **rule programming time**. When a single endpoint changes, kube-proxy in iptables mode historically had to rewrite a large fraction of the table and reload it atomically. In big clusters that sync could take seconds, which means there is a window where the kernel's view of endpoints lags reality. That lag is the scaling cliff: not a smooth slowdown but a point, somewhere in the low thousands of Services, where reconcile latency and tail connection latency both start climbing together. The `minSyncPeriod` tuning knob exists precisely because of this, and tuning it is choosing which kind of staleness you prefer.

## IPVS Mode: Hash Tables and Real Algorithms

IPVS (IP Virtual Server) was built into the Linux kernel for exactly this job: in-kernel L4 load balancing. When kube-proxy runs in IPVS mode, it stops expressing Services as netfilter match chains and instead programs IPVS **virtual servers**, each backed by a set of real servers (the pod IPs). The lookup from VIP to backend set is a **hash table**, so it is effectively **O(1)** regardless of how many Services you have.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">ipvsadm view of one virtual server</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">$ ipvsadm -Ln
TCP  <span style="color:#a3e635;">10.96.0.21</span>:8080 rr                <span style="color:#64748b;"># rr = round robin scheduler</span>
  -&gt; <span style="color:#a3e635;">10.1.7.4</span>:8443   Masq  1  ...
  -&gt; <span style="color:#a3e635;">10.1.7.9</span>:8443   Masq  1  ...
  -&gt; <span style="color:#a3e635;">10.1.8.2</span>:8443   Masq  1  ...</code></pre>
</div>

The second win is that IPVS ships with **real scheduling algorithms**, not just statistical coin-flips. Round robin (`rr`), weighted round robin (`wrr`), least connection (`lc`), weighted least connection (`wlc`), and source hashing (`sh`) are all available. This matters: `lc` and `wlc` route to the backend with the fewest active connections, which is the in-kernel version of the least-connections strategy I walked through in [load-balancing algorithms](/2026/03/02/load-balancing-algorithms.html). iptables mode can only approximate uniform random; IPVS can actually balance by load.

The thing to understand is that **IPVS does not fully escape iptables**. kube-proxy in IPVS mode still uses a small, bounded set of iptables rules for things like packet marking, masquerading, and `NodePort` handling, but that set does not grow with the number of Services. So the comparison is not "IPVS has no iptables." It is "IPVS keeps the iptables surface constant while iptables mode lets it grow without bound." For clusters past a few thousand Services, that constant-versus-linear difference is the whole argument.

## eBPF and Cilium: Deleting kube-proxy

The newest answer is to stop translating into iptables or IPVS at all, and instead attach **eBPF** programs directly to the kernel's networking hooks. This is the model [Cilium](https://cilium.io/) popularized, and it can replace kube-proxy entirely (`kube-proxy replacement`).

The mechanism: a Service and its endpoints are stored in **eBPF maps** (kernel hash maps keyed by VIP and port). An eBPF program attached at a low hook (the socket layer via `connect()`, or at the driver's XDP/`tc` ingress hook) does the lookup and the DNAT. Because the rewrite can happen at the socket layer for in-cluster traffic, a pod connecting to a ClusterIP can be translated to the backend pod IP **before the packet is ever built**, which skips a chunk of the network stack and the per-packet NAT cost entirely.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">Cilium replacing kube-proxy</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># install with kube-proxy turned off entirely</span>
$ cilium install --set kubeProxyReplacement=true

<span style="color:#64748b;"># services now live in eBPF maps, not iptables / ipvs</span>
$ cilium service list
ID   Frontend            Backends
1    <span style="color:#a3e635;">10.96.0.21</span>:8080    <span style="color:#a3e635;">10.1.7.4</span>:8443, <span style="color:#a3e635;">10.1.7.9</span>:8443, <span style="color:#a3e635;">10.1.8.2</span>:8443

<span style="color:#64748b;"># and there is no growing iptables nat table behind it</span>
$ iptables -t nat -S KUBE-SERVICES 2&gt;/dev/null | wc -l
0</code></pre>
</div>

The payoffs are lower and more predictable latency (no linear chain walk, often no per-packet conntrack for the fast path), updates that touch only the changed map entry instead of reloading a table, and the same L7-aware machinery feeding network policy and observability. This is the same control-plane-pushes-dataplane-state pattern I described for service meshes in the [service discovery post](/2026/06/30/service-discovery-in-kubernetes.html), pulled down into the kernel itself. The cost is operational: eBPF needs a reasonably modern kernel, the debugging tools are different from the `iptables -S` muscle memory everyone has, and you are now running a CNI that owns far more of the stack.

## conntrack, and Where It Runs Out

All of this leans on the kernel's **connection tracking** table (`conntrack`), which is how the kernel remembers that a given flow was already DNAT'd to a given pod so that subsequent packets and the return path get rewritten consistently. iptables and IPVS modes both depend on it heavily; eBPF dataplanes can do their own flow tracking in maps and lean on it less.

conntrack is a fixed-size table, and **it is one of the most common silent failure modes in Kubernetes networking.** When `nf_conntrack_max` fills up, the kernel starts dropping new connections and logs `nf_conntrack: table full, dropping packet`. The application sees this as random connection timeouts that correlate with nothing in the app logs, which is a miserable thing to debug.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">checking conntrack pressure</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">$ cat /proc/sys/net/netfilter/nf_conntrack_count   <span style="color:#64748b;"># in-use entries</span>
<span style="color:#f0abfc;">131072</span>
$ cat /proc/sys/net/netfilter/nf_conntrack_max     <span style="color:#64748b;"># the ceiling</span>
<span style="color:#f0abfc;">131072</span>                                             <span style="color:#64748b;"># full: new connections now drop</span></code></pre>
</div>

A node that opens many short-lived connections (a busy proxy, a chatty batch job) can exhaust conntrack long before it runs out of CPU or memory. The mitigations are raising the ceiling, tuning the timeouts so closed flows are reaped faster, or moving to an eBPF dataplane that does not put every flow through the netfilter conntrack table in the first place. This is one of the quietest arguments for eBPF: it does not just go faster, it removes a fixed-size kernel resource from the hot path.

## Knowing Which Mode You Run, and When to Switch

The honest starting point is that most people do not know which mode they are running, because it was decided by whoever installed the cluster. Find out before you tune anything.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">which dataplane is this cluster on?</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># the kube-proxy config map says iptables or ipvs</span>
$ kubectl -n kube-system get cm kube-proxy -o yaml | grep mode
    mode: <span style="color:#a3e635;">"ipvs"</span>

<span style="color:#64748b;"># or there is no kube-proxy at all (eBPF / Cilium replaced it)</span>
$ kubectl -n kube-system get ds kube-proxy
No resources found</code></pre>
</div>

The decision framework is short. **Stay on iptables** if you have a small or mid-size cluster (hundreds of Services); it is the best-understood and most universally supported mode, and switching buys you nothing. **Move to IPVS** when Service and endpoint counts climb into the thousands and you start seeing rising kube-proxy sync times or connection-setup latency, or when you specifically want least-connection load balancing in the kernel. **Reach for an eBPF dataplane** when you want the lowest, most predictable latency, when conntrack exhaustion is a recurring incident, or when you are already adopting a CNI like Cilium for network policy and observability and the kube-proxy replacement comes along for the ride. The same control-plane caution from the rest of my [zero-trust](/2025/08/03/zero-trust-with-reverse-proxy.html) and proxy writing applies: every one of these moves more of your routing into a system whose failure takes the whole node's networking with it, so you trade a known set of failure modes for a different one. Pick the trade deliberately, not by default.

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">A ClusterIP is a promise the kernel keeps. iptables, IPVS, and eBPF are just three different bookkeeping systems for keeping it, and the one you are running decides whether that promise holds at ten Services or ten thousand.</p>

---

*This is the data-plane sequel to [how service discovery actually works in Kubernetes](/2026/06/30/service-discovery-in-kubernetes.html), and it picks up the [load-balancing algorithms](/2026/03/02/load-balancing-algorithms.html) those dataplanes implement in the kernel.*

*Debugging kube-proxy at scale or weighing an eBPF migration? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
