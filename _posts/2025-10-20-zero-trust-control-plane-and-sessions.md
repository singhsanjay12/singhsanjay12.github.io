---
title: "Why Zero Trust Matters and How to Implement It with a Reverse Proxy : Part Two"
description: "The first post closed the perimeter. This one tackles what happens after: how a Zero Trust control plane revokes access in seconds, manages sessions, and abstracts SSO across identity providers."
date: 2025-10-20 12:00:00 +0000
categories: [Security, Zero Trust]
tags: [zero-trust, mtls, reverse-proxy, control-plane, sso, oidc, trustbridge]
image:
  path: /assets/img/posts/zero-trust/hero-part-two.svg
  alt: "Control plane broadcasting an instant access revocation across a distributed proxy fleet"
---

[Part One](/2025/08/03/zero-trust-with-reverse-proxy.html) established the case for a reverse proxy as the Zero Trust enforcement point: every request validated against device identity, user identity, and policy before it reaches a backend. That architecture closes the perimeter model's biggest gap: trust based on network location.

But it leaves a harder question open. Closing the door at connection time is not enough. What happens when someone who was legitimate at login time is no longer legitimate five minutes later?

Revoking access still takes hours in most organizations. The goal of this post is to show why, and what it takes to get that number to seconds.

## From Flat Networks to Enforced Trust Zones

Before getting into the mechanics of revocation, it helps to be precise about the network model TrustBridge operates on. The perimeter model assumes a flat internal network: once inside, you can reach most things. Zero Trust requires the opposite.

TrustBridge enforces trust zones defined along two dimensions:

- **Trusted vs. Untrusted:** traffic originating from managed infrastructure vs. arbitrary external sources
- **Managed vs. Unmanaged:** devices with a cryptographically verified identity vs. devices without one

Crossing a zone boundary requires validation. Traffic that cannot be validated does not cross. Lateral movement (the defining characteristic of how breaches spread) is structurally prevented rather than just monitored after the fact.

![Trust zones: managed/unmanaged and trusted/untrusted dimensions, with TrustBridge at each boundary](/assets/img/posts/zero-trust/trust-zones.svg)

At the network layer this means L2/L3 isolation between zones, with NACLs at every boundary and host-level firewalls. Servers are dual-homed with NICs pinned to specific zone pairs: the L4 load balancer's first NIC handles public ingress, its second handles outbound to the L7 proxy only. The L7 proxy's first NIC accepts inbound traffic from the L4 tier only; its second handles outbound to the trusted zone. There are no cross-zone interfaces. Traffic flows only forward.

What makes this more than just network segmentation is what happens at each boundary.

## Protocol Break and Re-Origination

The phrase "reverse proxy" undersells what is actually happening. TrustBridge does not inspect and pass packets. It terminates the connection entirely and opens a new one.

**At the L4 boundary:** TCP terminates. The connection is inspected. A new TCP connection is opened to the L7 proxy. Untrusted traffic never reaches the trusted network end-to-end; it is broken apart and re-origination begins from scratch.

**At the L7 boundary:** HTTP terminates. Policies are enforced. A new connection is opened to the trusted zone. The backend service sees a fresh request from TrustBridge, not from the original client.

This is the mechanism that makes certificate revocation enforceable. Because TrustBridge terminates every TCP connection, it controls when connections are established and when they end. A certificate that was valid when the original connection was opened can be re-evaluated the next time a connection is established. TrustBridge decides when that is.

## The Data Plane and the Control Plane

The proxy is the *data plane*. It handles live traffic. But it needs instructions: which rules to enforce, which certificate authorities to trust, which identity provider to use, which devices and users are on the allowlist or denylist.

Those instructions come from the *control plane*.

The control plane has two primary responsibilities:

1. **Define and manage access policies.** It holds the authoritative rule definitions and computes the effective policy for each proxy instance.
2. **Act as the authoritative source for allowlists and denylists.** Device certificates that are revoked, users whose accounts are terminated: the control plane knows first, and it ensures the proxy fleet knows within seconds.

![Control plane pushing policy and revocation state to proxy fleet via gRPC/XDS; emergency path for instant enforcement](/assets/img/posts/zero-trust/control-plane-arch.svg)

**How policies reach the proxy:**

The control plane maintains a persistent push channel to each proxy instance using gRPC. For Envoy-based deployments this is the xDS protocol, the same mechanism used in service mesh control planes,. For HAProxy deployments it is the HAProxy runtime API combined with a custom DSL.

On startup, each proxy fetches its current policy bundle. The control plane then streams updates as they occur. Hot-reload is built into both Envoy and HAProxy: policy changes take effect without dropping connections.

A policy rule at the L7 enforcement point:

```yaml
- resource: /api/payroll/*
  effect: allow
  conditions:
    groups: [finance, hr-admin]
    device_trust: managed
    mfa_verified: true

- resource: /internal/admin/*
  effect: allow
  conditions:
    groups: [infra-oncall]
    device_trust: managed
```

Rules are evaluated per-request against the combined identity context assembled from the device certificate claims and SSO token claims. No match means deny.

**Emergency enforcement:**

The control plane has a separate fast path for urgent changes. Standard policy updates are pushed on a normal propagation cycle. An emergency revocation (a compromised device, a terminated employee who should lose access immediately) goes through a dedicated mechanism that bypasses the normal sync interval and forces an immediate update across all proxy instances. The target window is single-digit seconds from the time the administrator acts.

## The Long-Lived Session Problem

Protocol break and re-origination handles the transport layer. But there is still the question of what happens to connections that are already established.

mTLS certificate validation happens once: at the TLS handshake. Once a session is up, requests flowing over that session do not re-validate the certificate. HTTP/2 multiplexes many requests over a single connection. A client can open a connection, pass mTLS, and then make thousands of requests without the certificate being evaluated again.

The control plane can update its policy instantly. The proxy can have the new policy loaded in seconds. But an existing connection on a proxy instance is still running on the session that was established before the revocation.

**Concrete scenario:**

An employee is terminated. Their manager notifies IT. The device certificate is revoked in the CA. The IdP account is disabled. The control plane propagates both changes to the proxy fleet in seconds.

But the employee's laptop has an open connection to TrustBridge, established thirty minutes ago. Under standard TLS semantics, that session is still valid. The certificate was good when the session started.

Without an additional mechanism, the session stays up until the client disconnects. In practice that can mean hours.

## Bounded Sessions: Enforcing Re-Origination at a TTL

The solution is straightforward once you have protocol termination: enforce a maximum session lifetime at the proxy.

TrustBridge tracks session age. When a session reaches its configured maximum (typically 10 to 15 minutes for high-security environments), TrustBridge sends a TCP FIN. The client must reconnect. Re-origination begins again from scratch: new TCP connection, new TLS handshake, new certificate validation, new policy check.

![Session lifecycle with TTL: session established, requests flow, TTL reached, TCP FIN, reconnect, certificate recheck against current revocation state](/assets/img/posts/zero-trust/session-lifecycle.svg)

At reconnect, TrustBridge checks the device certificate against the current revocation state. If the certificate was revoked between the original handshake and this one, the handshake fails. The connection is never re-established.

**Certificate revocation mechanisms:**

*OCSP stapling* is the preferred approach in TrustBridge deployments. The client fetches its own OCSP response from the CA in advance and presents it during the handshake. TrustBridge validates the stapled response (signature, freshness, revocation status) without making a live network call to the CA. No latency penalty at reconnect. No dependency on OCSP responder availability at the critical moment.

*Short-lived certificates* are the architectural alternative. Certs expire in hours rather than months. A revoked cert simply isn't renewed, and it dies on its own schedule. This eliminates the CRL/OCSP infrastructure entirely, at the cost of requiring a fully automated, highly reliable cert issuance pipeline. Any failure in renewal means connection failure at the next reconnect. TrustBridge supports both models.

**The exposure window:**

With bounded sessions, the worst-case window is one session lifetime. A 15-minute TTL means no revoked certificate can be used for more than 15 minutes after revocation, regardless of when the client attempts to reconnect. For environments with very high security requirements, sessions as short as five minutes are practical given the reconnect overhead is negligible for most applications.

## Context-Aware Policy: Beyond Identity

Standard Zero Trust validates two signals per request: who is the user, and which device are they on. TrustBridge extends this with additional context signals that feed into per-request policy evaluation:

**Session context.** How long has this session been active? A session approaching its TTL is treated differently from a session that just established.

**Location signals.** What network is the device connecting from? A managed device connecting from a known office network may have broader access than the same device connecting from an unknown network, depending on the policy.

**Behavioral signals.** Is this access pattern consistent with what this user normally does? TrustBridge can be configured to feed anomaly signals from downstream systems into policy decisions: if a user who normally accesses three internal services suddenly starts enumerating endpoints, that context can reduce their access level without terminating the session entirely.

**Multi-device sessions.** When the same user has active sessions from multiple devices simultaneously, this is surfaced as a context signal. Policies can treat multi-device access as normal (common for engineers with a desktop and a laptop) or as a flag requiring additional verification (unusual for a contractor who typically uses a single machine).

**Impossible travel detection.** Because TrustBridge handles every authentication event across the entire fleet, it can detect when the same identity authenticates from two locations that are physically incompatible within the elapsed time. A login from Tokyo followed by one from New York three minutes later is not a suspicious pattern; it is an impossible one. TrustBridge blocks the new session and invalidates the existing one. Individual applications cannot make this check; the proxy can, because it sees all of them.

Policy rules express these conditions explicitly:

```yaml
- resource: /api/sensitive/*
  effect: allow
  conditions:
    groups: [security-eng]
    device_trust: managed
    network: known_corporate
    session_age_max: 900   # seconds
    anomaly_score_max: 0.3
```

## SSO at the Proxy: Provider-Agnostic by Design

TrustBridge integrates with identity providers at the proxy layer, not at the application layer. Backends never handle an SSO flow. They receive a request with normalized identity headers and trust them, because requests only arrive from TrustBridge.

The proxy integrates with IdPs over OIDC, SAML, and LDAP, whichever protocol the organization's IdP supports. This matters for legacy environments where not every IdP has been migrated to OIDC.

**The verification flow:**

1. Request arrives without a valid session
2. TrustBridge initiates the IdP flow (redirect for browsers, device flow or local token reuse for CLI)
3. After successful authentication, TrustBridge validates the token: JWT signature via JWKS, standard claims, configured group/role claims
4. TrustBridge establishes a session and assembles the identity context
5. On every request, the context is evaluated against the current policy from the control plane
6. The backend receives a normalized identity header:

```
X-Verified-User:   alice@example.com
X-Verified-Groups: engineering,infra-oncall
X-Verified-Device: managed/corp-laptop-7824
X-Auth-Time:       1729432800
```

The backend trusts these headers because it only accepts traffic from TrustBridge. It does not implement a token validation library. It does not know which IdP is in use. That complexity is entirely absorbed at the proxy.

One important detail: TrustBridge does not simply forward the original SSO token downstream. It assembles a new JWT (signed by TrustBridge's own key) that contains the normalized identity claims. Backend services decode this token using TrustBridge's public key. They validate TrustBridge's signature, not the IdP's. The original token never crosses the trust boundary.

![SSO abstraction: OIDC, SAML, LDAP IdPs behind TrustBridge; browser and CLI both handled; backends receive only normalized headers](/assets/img/posts/zero-trust/sso-abstraction.svg)

**Changing identity providers:**

OIDC is a standard. Okta, Azure AD, Ping, Auth0, Dex all expose the same discovery document at `/.well-known/openid-configuration`. TrustBridge discovers the IdP's capabilities (authorization endpoint, token endpoint, JWKS URI) from that document.

Migrating from one IdP to another is a configuration change at TrustBridge:

```yaml
idp:
  discovery_url: https://login.microsoftonline.com/{tenant}/v2.0/.well-known/openid-configuration
  client_id: trustbridge-prod
  client_secret_ref: vault/secret/trustbridge/idp-client
  claim_mappings:
    user:   preferred_username
    groups: roles
```

No application changes. Every backend continues to receive the same normalized headers. They never knew which IdP was behind the proxy, and they still do not. The `claim_mappings` block handles provider-specific claim naming: Okta uses `groups`, Azure AD uses `roles`, a custom deployment might use something else. TrustBridge normalizes all of it to whatever schema your backends expect.

**CLI and non-browser clients:**

A common failure mode in Zero Trust deployments is treating the browser as the only client that matters. Engineers use CLIs. Automation uses service accounts. Both need to work, and both need the same identity and device verification that browsers get.

For CLI clients, TrustBridge initiates a device authorization flow: it opens the IdP's browser-based login page, and the CLI waits for a token. Once authentication completes, TrustBridge issues a session token that the CLI stores locally and reuses across sessions. The token is short-lived and bound to the device certificate, and both must be valid for the CLI session to continue. The user gets full SSO including MFA, without building a custom auth flow into every CLI tool.

SSH access follows the same model via SSH-over-HTTP tunneling. SSH connections are configured to route through TrustBridge over an HTTP CONNECT tunnel. The mTLS handshake and SSO check happen at the proxy before the SSH session is established. Engineers accessing production environments over SSH get identical enforcement to browser access: same device check, same user verification, same policy evaluation.

**How traffic reaches the proxy:**

Split-horizon DNS is how TrustBridge ensures all internal traffic goes through the enforcement point. Internal DNS returns the proxy's address for internal hostnames. Clients (browser, CLI, or SSH) resolve the same hostname and land at TrustBridge. There are no parallel paths that bypass enforcement, and no need to configure each client with a proxy address explicitly.

**Token expiry and the second kill switch:**

Access tokens are short-lived. TrustBridge handles renewal using the refresh token before the current token expires. If refresh fails (account disabled, session revoked, forced logout), TrustBridge terminates the session and re-prompts for authentication.

This is the second independent mechanism alongside certificate revocation. Disabling an account at the IdP terminates access within the access token TTL. For immediate response, TrustBridge can use token introspection to synchronously validate session status against the IdP on each request, at the cost of an extra round-trip.

## Two Kill Switches, Bounded Windows

The architecture gives two independent mechanisms for terminating access, each with a bounded exposure window:

**Device certificate revocation** operates through protocol re-origination and session TTL. Revoke the cert; at worst the attacker has one session lifetime of remaining access. With short-lived certs or OCSP stapling, the proxy enforces this at every reconnect.

**Identity provider account revocation** operates through token expiry and refresh failure. Disable the account; at worst the attacker has one access token TTL of remaining access. With synchronous introspection, it is immediate.

An attacker who has compromised both device credentials and SSO credentials (the worst-case scenario), which faces both mechanisms operating independently. There is no path to long-term persistence through either vector alone.

## Where to Start

If you are thinking about whether and how to move toward this architecture, three measurements are worth taking first:

1. **Your weakest revocation path.** After a user account is disabled or a device cert is revoked, how long does it take for access to be fully terminated across your application fleet? If the answer is measured in hours, that is the gap this architecture addresses.

2. **Your enforcement gaps.** Which applications are reachable from unmanaged devices or through VPN alone, without device certificate verification? Which CLI tools bypass SSO? These are the surfaces a compromised credential can exploit that Zero Trust closes.

3. **Your identity provider dependencies.** How many applications implement their own IdP integration? Each one is a migration problem and a consistency risk. Centralizing at the proxy reduces that surface to a single integration.

---

*If you are working through similar problems, reach out on [LinkedIn](https://www.linkedin.com/in/singhsanjay12) or by [email](mailto:gargwanshi.sanjay@gmail.com).*
