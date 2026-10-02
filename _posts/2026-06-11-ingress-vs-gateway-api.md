---
title: "Ingress vs Gateway API: The Kubernetes Traffic-Entry Rewrite"
description: "Ingress gave Kubernetes a portable way to do host and path routing, then quietly pushed everything else into vendor-specific annotations. Gateway API is the redesign: a role-oriented, typed set of resources that splits the infra owner from the app owner and makes expressive routing first-class."
date: 2026-06-11 12:00:00 +0000
categories: [Distributed Systems, Kubernetes]
tags: [kubernetes, ingress, gateway-api, networking, traffic, reverse-proxy]
image:
  path: /assets/img/posts/ingress-gateway-api/hero.svg
  alt: "A single overloaded Ingress object stuffed with vendor annotations on the left, versus the role-split Gateway API on the right: an infra-owned GatewayClass and Gateway with app-owned HTTPRoutes attached"
---

For most of Kubernetes' life, the answer to "how does HTTP traffic get into the cluster?" was the same: **you write an Ingress object**. It is one of the first APIs anyone learns, and for the narrow thing it was designed to do, host and path routing, it works fine. The trouble is that almost nothing real stops at host and path routing. The moment you need a rewrite, a redirect, a timeout, a header match, a canary split, or mutual TLS, you discover that the Ingress spec has nothing to say about it, and you reach for an annotation. That annotation is where portability quietly dies.

This is the cluster-edge companion to my writing on [how reverse proxies handle concurrent connections](/2026/03/09/concurrent-requests-reverse-proxy.html) and [how service discovery actually works in Kubernetes](/2026/06/30/service-discovery-in-kubernetes.html). Those posts are about the data plane and east-west traffic; this one is about the API you use to configure the north-south door, and why the community is rewriting it.

## The Ingress Object Is Thinner Than It Looks

An Ingress object is genuinely small. It carries a list of hosts, a list of paths, and the backend Service each path maps to. That is the entire portable surface.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">ingress.yaml</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop
  annotations:
    <span style="color:#f0abfc;">nginx.ingress.kubernetes.io/rewrite-target</span>: /
    <span style="color:#f0abfc;">nginx.ingress.kubernetes.io/canary</span>: <span style="color:#a3e635;">"true"</span>
    <span style="color:#f0abfc;">nginx.ingress.kubernetes.io/canary-weight</span>: <span style="color:#a3e635;">"10"</span>   <span style="color:#64748b;"># 10% traffic split, as a string</span>
spec:
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service: { name: api, port: { number: <span style="color:#f0abfc;">8080</span> } }</code></pre>
</div>

Look at where the interesting behavior lives. The host and path are typed fields the API understands. The traffic split, the rewrite, the canary logic: all of that is in `annotations`, as opaque strings, prefixed with a vendor's name. Kubernetes does not validate them, does not understand them, and cannot port them. Move this manifest from the NGINX controller to Traefik or to a cloud load-balancer controller and every one of those annotation lines is wrong. You have not written a portable routing config; you have written NGINX configuration that happens to be wearing an Ingress costume.

The deeper problem is governance. An Ingress is a single object that mixes two very different concerns: **who owns the listener, the certificate, and the IP address**, and **who owns the routing rules for one application**. On a real cluster those are different people. The platform team owns the front door. Each app team owns its own paths. Ingress gives them one shared object to fight over, with no way to delegate a slice of it safely.

## Gateway API: Roles, Not One Blob

Gateway API is the official successor, and its central idea is not a new feature. It is a **separation of roles** expressed as separate, typed resources. Instead of one Ingress object, you get three kinds, each owned by a different persona.

A **GatewayClass** is the cluster-wide template, owned by the infrastructure provider. It names the controller implementation (the thing that actually programs an Envoy, an NGINX, or a cloud load balancer). It is the Gateway API analog of a StorageClass.

A **Gateway** is owned by the platform or cluster operator. It declares listeners: ports, protocols, hostnames, and TLS certificates. This is the front door, and the people who own DNS and certificates own this object.

An **HTTPRoute** (and its siblings `TCPRoute`, `GRPCRoute`, `TLSRoute`) is owned by the application team. It says "for these hostnames and paths, with these header and method matches, send traffic to these backends, with these weights." It attaches itself to a Gateway rather than redefining the listener.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">gateway.yaml (owned by the platform team)</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: edge
  namespace: infra
spec:
  gatewayClassName: envoy        <span style="color:#64748b;"># picks the controller implementation</span>
  listeners:
    - name: https
      protocol: HTTPS
      port: <span style="color:#f0abfc;">443</span>
      tls:
        certificateRefs: [ { name: shop-cert } ]
      allowedRoutes:
        namespaces: { from: Selector, selector: { matchLabels: { team: shop } } }</code></pre>
</div>

The `allowedRoutes` block is the part Ingress never had: the Gateway owner explicitly delegates, declaring which namespaces are allowed to attach routes to this listener. The platform team keeps the certificate and the IP; the app team gets a sanctioned, scoped way to bind to it without touching the front door.

## Routing That Does Not Need an Annotation

Everything that used to be a vendor annotation becomes a typed field on the route. Header matches, method matches, traffic weights, request mirroring, redirects, and rewrites are all part of the spec, which means they validate, they are portable across implementations, and they read like configuration instead of escape hatches.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">httproute.yaml (owned by the app team)</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;">apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api
  namespace: shop
spec:
  parentRefs:
    - name: edge
      namespace: infra         <span style="color:#64748b;"># attaches to the platform team's Gateway</span>
  hostnames: [ "shop.example.com" ]
  rules:
    - matches:
        - path: { type: PathPrefix, value: /api }
          headers:
            - name: x-canary
              value: <span style="color:#a3e635;">"yes"</span>      <span style="color:#64748b;"># header match is a first-class field</span>
      backendRefs:
        - { name: api-next, port: <span style="color:#f0abfc;">8080</span>, weight: <span style="color:#f0abfc;">10</span> }   <span style="color:#64748b;"># weighted split, typed</span>
        - { name: api,      port: <span style="color:#f0abfc;">8080</span>, weight: <span style="color:#f0abfc;">90</span> }</code></pre>
</div>

Two things are worth pausing on. First, the traffic split is a real number on a real field, not a quoted percentage in an annotation that one controller happens to parse. Second, the route lives in the `shop` namespace and reaches across to a Gateway in `infra` through `parentRefs`. That **cross-namespace attachment** is the mechanism that finally lets an app team manage its own routing without either editing a shared object or being handed cluster-admin. When a backend lives in a different namespace from the route, a `ReferenceGrant` object in the target namespace must opt in, so delegation is always explicit and auditable in both directions.

It is also genuinely multi-protocol. Ingress was HTTP and HTTPS only; anything L4 lived in a `LoadBalancer` Service or another annotation dialect. Gateway API makes `TCPRoute`, `TLSRoute`, and `GRPCRoute` siblings of `HTTPRoute`, so a single Gateway can terminate TLS for HTTP on one listener and pass raw TCP for a database proxy on another, described in the same typed model.

## The Proxy Underneath, and the Mesh Beside It

None of this routing happens by magic. A Gateway API resource is a declaration of intent; a **controller** watches those objects and programs an actual data-plane proxy to match. In practice that proxy is very often Envoy, configured over xDS, which is exactly the control-plane-driven model I walked through in the [proxy concurrency post](/2026/03/09/concurrent-requests-reverse-proxy.html). The Gateway API is the user-facing, portable schema; xDS is the wire protocol the controller uses to push the resulting config into the proxy workers. You write a typed `HTTPRoute`, the controller translates it into listeners, routes, and clusters, and the proxy starts splitting traffic the way the weights say.

The endpoints those clusters point at come from the same registry that backs in-cluster discovery: the Service and its EndpointSlices, health-filtered by readiness, which is the machinery I covered in [service discovery in Kubernetes](/2026/06/30/service-discovery-in-kubernetes.html). And the choice of which backend to send a given request to, once weights and matches have selected a pool, is the [load-balancing algorithm](/2026/03/02/load-balancing-algorithms.html) running inside that proxy. Gateway API sits cleanly on top of all of it: a stable, typed front door over the live registry and the proxy you already run.

There is one more relationship worth naming. Gateway API started as a north-south (cluster ingress) API, but a working group called **GAMMA** extended the same resources to describe east-west, service-to-service traffic inside a mesh. The insight is that "route this traffic to these backends with these rules" is the same shape of problem whether the client is outside the cluster or another pod inside it. With GAMMA, an `HTTPRoute` can attach to a Service as its parent instead of a Gateway, and a mesh like Istio or Linkerd programs the sidecars accordingly. One API now describes both the front door and the internal mesh, which is a meaningful consolidation over the era when ingress and mesh each had their own incompatible CRDs.

## Migration Reality, and When Ingress Is Still Fine

The honest part. Gateway API is stable for its core resources and is the direction every major implementation is moving, but **Ingress is not deprecated and is not going away**. You do not need to rewrite a working cluster this quarter.

Migration is usually incremental rather than a flag day. You stand up a Gateway alongside your existing Ingress, point a few low-risk routes at it, and move workloads over as teams are ready. The community even ships an `ingress2gateway` tool that converts existing Ingress objects (annotations included, where it can map them) into Gateway and HTTPRoute equivalents to give you a starting point.

<div style="border-radius:8px;overflow:hidden;margin:1.5em 0;box-shadow:0 1px 6px rgba(0,0,0,0.15);">
  <div style="padding:7px 14px;background:#0f172a;display:flex;align-items:center;gap:8px;">
    <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#6366f1" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
    <span style="font-family:system-ui,sans-serif;font-size:11px;color:#94a3b8;font-weight:500;letter-spacing:0.3px;">incremental migration</span>
  </div>
  <pre style="margin:0;padding:16px 18px;background:#1e293b;overflow-x:auto;"><code style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace;font-size:13px;color:#e2e8f0;line-height:1.65;"><span style="color:#64748b;"># convert existing Ingress objects to Gateway API as a starting point</span>
$ ingress2gateway print --input-file ingress.yaml

<span style="color:#64748b;"># run Gateway and Ingress side by side; cut routes over one at a time</span>
$ kubectl get gateways,httproutes -A
$ kubectl get ingress -A           <span style="color:#64748b;"># old door stays up until the last route moves</span></code></pre>
</div>

So when is plain Ingress still the right call? When the job really is just host and path routing to a handful of backends, when one team owns the whole cluster and the role-separation buys you nothing, or when your platform's annotations already cover your needs and you have no portability requirement. For a small internal cluster with three services behind one hostname, an Ingress is a perfectly good four-line object and Gateway API's extra resources are overhead.

You reach for Gateway API when the cluster is shared, when routing logic outgrows host and path (weighted splits, header routing, mirroring, redirects), when you need L4 and L7 in one model, when portability across implementations actually matters, or when the same team wants one API spanning the front door and the mesh. That is most clusters that grow up. The pattern underneath is the one the rest of the stack already taught: **a stable, typed declaration of intent in front, an implementation that programs a real proxy behind, and clear ownership boundaries keeping the two honest.**

<p style="font-family: Georgia, serif; font-style: italic; font-size: 1.05em; border-left: 3px solid #c7d2fe; padding-left: 1em; margin-top: 2em; color: #1e293b;">Ingress did not fail because it routed traffic badly. It failed because it put portable routing and unportable configuration in the same object, and asked one team to own both. Gateway API's real feature is the boundary it draws.</p>

---

*This builds on my earlier pieces on [how reverse proxies handle concurrent connections](/2026/03/09/concurrent-requests-reverse-proxy.html), [service discovery in Kubernetes](/2026/06/30/service-discovery-in-kubernetes.html), and [load-balancing algorithms](/2026/03/02/load-balancing-algorithms.html).*

*Migrating a cluster from Ingress to Gateway API, or drawing the platform-versus-app ownership line? I am on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or reachable by [email](mailto:hello@singh-sanjay.com).*
