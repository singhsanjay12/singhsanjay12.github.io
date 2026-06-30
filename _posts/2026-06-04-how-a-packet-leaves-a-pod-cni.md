---
title: "How a Packet Leaves a Pod: CNI, Overlays, and BGP"
description: "Before any Service or kube-proxy rule runs, a packet has to physically leave a pod's network namespace, cross the node, and find another node. Here is the path it takes, and the real tradeoff between overlay encapsulation and native BGP routing that decides your cluster's network."
date: 2026-06-04 12:00:00 +0000
categories: [Distributed Systems, Kubernetes]
tags: [kubernetes, cni, networking, overlay, bgp, pod-networking]
image:
  path: /assets/img/posts/cni-pod-networking/hero.svg
  alt: "A packet leaving a pod through a veth pair to the node bridge, then either VXLAN-encapsulated across an overlay or routed natively to another node via BGP, into a destination pod"
---

Most people meet Kubernetes networking from the top down: a Service name, a ClusterIP, kube-proxy load-balancing to some pods. That is the layer I wrote about in [how service discovery actually works in Kubernetes](/2026/06/30/service-discovery-in-kubernetes.html). But every one of those abstractions rests on a quieter assumption that nobody states out loud: **a packet can already get from one pod to another, on its own routable IP, with no NAT in between.** Services do not make that true. The CNI plugin does. And the way it makes it true determines your cluster's latency, its MTU, and how much of your physical network you have to control.

This post is the layer underneath. It is about the packet itself: how it leaves a pod's network namespace, crosses the node, and reaches a pod on a different machine. Once you have followed that path, the choice between an overlay and native routing stops being a vendor checkbox and becomes an architectural decision you can actually reason about.

## The Pod Network Model: One Flat, NAT-Free Space

Kubernetes makes three demands of any network implementation, and they are worth stating precisely because every design below exists to satisfy them:

- Every pod gets its own IP address.
- Any pod can reach any other pod using that IP, without NAT.
- The IP a pod sees on itself is the same IP every other pod uses to reach it.

That last point is the one that trips people coming from Docker's default bridge, where containers sit behind a NAT and advertise a port on the host. In Kubernetes there is no port juggling between pods. The cluster is one flat IP space. A pod at `10.1.2.7` talks to a pod at `10.1.9.4` exactly as if they were two hosts on the same subnet, even when those pods live on different nodes in different racks.

This is a deliberate simplification, and it is the foundation everything else stands on. Services, network policy, and service meshes all assume pod IPs are real and reachable. The job of making them real falls to a plugin that implements the **Container Network Interface (CNI)**: Calico, Cilium, Flannel, and others. When the kubelet starts a pod, it calls the CNI plugin with one instruction: give this pod a network. What the plugin does next is the whole story.

## Leaving the Pod: the veth Pair

A pod lives in its own Linux **network namespace**: an isolated copy of the network stack with its own interfaces, routing table, and rules. For a packet to leave, there has to be a wire out of that namespace. The CNI plugin builds that wire as a **veth pair**: a virtual Ethernet cable with two ends. One end becomes `eth0` inside the pod's namespace. The other end stays in the node's root namespace, plugged into a bridge or handed to a routing datapath.

You can see both ends if you look.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">the veth pair, from both sides</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># inside the pod: a single eth0 with the pod IP</span>
$ kubectl exec -it api -- ip addr show eth0
3: eth0@if42: ...
    inet <span style="color:#a3e635;">10.1.2.7</span>/24 scope global eth0

<span style="color:#64748b;"># on the node: the other end of the same cable</span>
$ ip link | grep -A1 veth
42: <span style="color:#7dd3fc;">veth9f3a1c</span>@if3: ...
    <span style="color:#64748b;"># if42 inside maps to if3 outside: same pair</span></code></pre>
</div>

The `@if42` and `@if3` suffixes are the two ends pointing at each other. Inside the pod, the default route points at the node end of the veth. So a packet from `10.1.2.7` to `10.1.9.4` does not know about overlays or BGP. It just goes out `eth0`, across the veth, and surfaces in the node's root namespace. Everything interesting happens after that, on the node.

## Crossing the Node, Then the Hard Part: Off It

In the root namespace the node has to decide where this packet goes. For traffic to a pod on the same node, it is easy: the destination veth is right there, the node bridges or routes the packet straight across, and it never touches a NIC. The latency is memory-copy fast.

The hard problem is a pod on a **different** node. The underlying physical network has never heard of `10.1.9.4`. Your data-center fabric routes node IPs, not pod IPs. If the node simply put that packet on the wire, the first switch would drop it: no route to that destination. This is the central problem CNI has to solve, and there are two fundamentally different answers. One hides the pod IP from the fabric. The other teaches the fabric about it.

## Overlay Networks: Wrap the Packet and Ship It

The overlay answer is encapsulation. The node takes the pod's packet, the one addressed `10.1.2.7` to `10.1.9.4`, and wraps it inside a new packet addressed from node A's IP to node B's IP. The fabric only ever sees node-to-node traffic, which it already knows how to route. The destination node unwraps it and delivers the inner packet to the local pod. The most common encapsulation is **VXLAN**; **Geneve** is its more extensible successor, and it is what Cilium uses by default.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="7" width="20" height="14" rx="2"/><path d="M16 21V5a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v16"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">a VXLAN-encapsulated pod packet</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># what the fabric sees (outer):  node A  -&gt;  node B</span>
[ outer IP: 10.0.4.11 -&gt; 10.0.4.27 ]
  [ outer UDP: dport 4789 ]
    [ VXLAN header: VNI 4096 ]
      <span style="color:#64748b;"># what the pods see (inner), carried untouched:</span>
      [ inner IP: <span style="color:#a3e635;">10.1.2.7</span> -&gt; <span style="color:#a3e635;">10.1.9.4</span> ]
        [ TCP / payload ... ]</code></pre>
</div>

The appeal is enormous: an overlay **works on any network**. It does not care about your switches, your routing protocol, or whether you own the fabric at all. Cloud VPC, on-prem, a laptop running kind: if nodes can reach each other's IPs, the overlay works. This is why Flannel's VXLAN backend and Calico's overlay mode are the path of least resistance, and why most clusters start here.

The tax is two-fold. First, **encap and decap cost CPU and add latency** on every cross-node packet. With hardware offload it is small; without it, on a busy node, it is measurable. Second, and more insidiously, there is the **MTU gotcha**. The outer headers (IP plus UDP plus VXLAN) eat roughly 50 bytes. If your nodes use a 1500-byte MTU and you leave the pod MTU at 1500, every full-size encapsulated frame exceeds 1500 on the wire. Best case it fragments and you pay a performance penalty. Worst case, with PMTU discovery broken by a firewall dropping ICMP, large packets vanish silently: small requests work, big responses hang, and you spend an afternoon blaming the application. The fix is to set the pod MTU below the node MTU (1450 for standard VXLAN) or to run jumbo frames end to end.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">the silent MTU failure</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">node MTU            = 1500
VXLAN overhead      = 50
safe pod MTU        = <span style="color:#a3e635;">1450</span>     <span style="color:#64748b;"># pod set to 1500 -&gt; oversized frames</span>

<span style="color:#64748b;"># symptom: tiny requests fine, large transfers stall.</span>
<span style="color:#64748b;"># cause: 1500-byte inner + 50-byte outer drops on the wire.</span></code></pre>
</div>

## Native Routing and BGP: Teach the Fabric the Pod CIDRs

The other answer refuses to wrap anything. If the fabric could just route pod IPs directly, there would be no encapsulation, no overhead, and no MTU math. **Native routing** makes exactly that happen. Each node owns a slice of the pod address space, its **pod CIDR**, say `10.1.2.0/24`. The trick is getting every router and every other node to know that `10.1.2.0/24` lives behind this node's IP. The standard way to distribute that knowledge is **BGP**, the same protocol the internet uses to exchange routes.

Calico in BGP mode and Cilium with native routing both run a BGP speaker on each node. The node advertises its pod CIDR as a route, the fabric (or a route reflector, or the other nodes) learns it, and from then on a packet to `10.1.9.4` is forwarded hop by hop like any normal IP packet. No wrapper. The pod packet hits the wire exactly as the pod wrote it.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">BGP-learned pod routes on the node</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">$ ip route
<span style="color:#a3e635;">10.1.2.0/24</span> dev bridge proto kernel    <span style="color:#64748b;"># my own pods, local</span>
<span style="color:#a3e635;">10.1.9.0/24</span> via 10.0.4.27 proto bird     <span style="color:#64748b;"># node B's pods, via BGP</span>
<span style="color:#a3e635;">10.1.5.0/24</span> via 10.0.4.18 proto bird     <span style="color:#64748b;"># node C's pods, via BGP</span>

<span style="color:#64748b;"># a packet to 10.1.9.4 is just routed: no encap, native MTU.</span></code></pre>
</div>

The payoff is real: **no per-packet encapsulation tax, full MTU, and a packet you can read** in a tcpdump without peeling off a VXLAN header. Calico can even disable overlay only between nodes on the same subnet (cross-subnet mode) and fall back to encapsulation only where it is needed.

The cost is a requirement, not a tax: you need the fabric to cooperate. Your network has to accept BGP sessions from the nodes, or you need a route reflector, and the pod CIDRs have to be routable address space that nobody else is using. In a cloud VPC you often cannot peer BGP with the underlay at all, which is why managed clouds frequently use their own VPC-native CNI that programs routes through the cloud API instead. Native routing is faster and cleaner, but it trades portability for control of the network. You buy speed with operational ownership.

## eBPF Datapaths: Replacing the Plumbing

Both models above traditionally lean on the node's bridge plus a thicket of iptables rules for delivery and policy. At scale, iptables becomes a liability: rules are evaluated as a linear list, and a cluster with thousands of Services and policies can spend real CPU walking it on every connection. This is the same linear-evaluation problem I touched on when discussing how proxies stay cheap on the hot path in [how reverse proxies handle concurrent connections](/2026/03/09/concurrent-requests-reverse-proxy.html).

**Cilium** replaces that plumbing with **eBPF**: small programs attached directly to the kernel's networking hooks, often right at the veth, that make forwarding and policy decisions in compiled code using hash-map lookups instead of a rule list. The packet can be redirected to its destination without traversing the bridge or the iptables chains at all. The result is policy enforcement and pod-to-pod forwarding that stays flat as the cluster grows, plus identity-aware policy that keys on workload identity rather than IP. eBPF is orthogonal to the overlay-versus-BGP choice: Cilium can run it under a Geneve overlay or under native routing. It is a replacement for the datapath, not for the encapsulation decision.

## Where This Sits Beneath Services

It is worth being explicit about the layering, because the abstractions blur it. Everything in this post is **pod-to-pod connectivity**: raw IP reachability between two pods. A Kubernetes Service is built on top of that. When a client resolves a ClusterIP and kube-proxy (or Cilium's eBPF) rewrites it to a real backend pod IP, the packet that results still has to physically travel from one pod to another, and that travel is exactly the veth-then-overlay-or-BGP path described here. Network policy, the question of whether that pod is even allowed to talk to this one, is a filter applied along the same path.

So the dependency runs downward. Service discovery depends on Services. Services depend on kube-proxy rewriting to pod IPs. Pod IPs being reachable at all depends on the CNI. If pod-to-pod is broken, no amount of correct Service configuration will save you: the ClusterIP resolves, kube-proxy picks a healthy backend, and the packet still cannot find the node. I have watched teams debug "the Service is down" for an hour when the truth was an MTU mismatch two layers below, dropping exactly the large packets. The same way a stale DNS answer hides a healthy backend in [DNS or a service registry](/2026/06/23/dns-vs-service-registry.html), a broken datapath hides a perfectly correct Service.

## What to Reach For, and When

The honest summary is short. Reach for an **overlay** (Flannel, or Calico/Cilium in encapsulation mode) when you want it to just work, when you do not control the fabric, or when you are on a network that will not route your pod CIDRs. Accept the small encap tax and, more importantly, get the pod MTU right so you never meet the silent large-packet failure.

Reach for **native routing with BGP** (Calico or Cilium) when you own the network, when latency and full MTU matter, and when you would rather peer BGP than pay encapsulation on every cross-node packet. Layer **eBPF** (Cilium) under either when iptables scale, identity-aware policy, or datapath performance is the constraint. The choice is not about which CNI is best in the abstract. It is about one question you now have the tools to answer: do you control the fabric the pod's packet has to cross, or do you have to hide that packet from it?

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">A Service name is a promise that some other pod is reachable. The CNI is what keeps that promise, one veth, one encapsulated frame, or one BGP route at a time.</p>

---

*This is the layer beneath [how service discovery actually works in Kubernetes](/2026/06/30/service-discovery-in-kubernetes.html), and it shares the hot-path discipline I wrote about in [how reverse proxies handle concurrent connections](/2026/03/09/concurrent-requests-reverse-proxy.html) and the silent-failure theme of [DNS or a service registry](/2026/06/23/dns-vs-service-registry.html).*

*Debugging pod-to-pod connectivity or choosing a CNI at scale? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
