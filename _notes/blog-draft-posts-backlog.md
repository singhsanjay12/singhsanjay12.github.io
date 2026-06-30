# Blog draft-posts backlog

> Internal working notes. This lives in `_notes/`, which Jekyll ignores (underscore-prefixed,
> non-collection directory), so it is **never published** to singh-sanjay.com. It is committed to
> the repo so the state is available from any machine, not just the one it was created on.

## Status as of 2026-06-30

12 blog-post ideas were turned into **draft PRs** (one branch + hero SVG each, all CI-green, all
DRAFT). They are awaiting review/merge. To see live status from any machine:

```
gh pr list --repo singhsanjay12/singhsanjay12.github.io --draft
```

(Some may already be merged or closed later — verify before assuming they are still open.)

| PR | Title | Branch (`ssingh1/…`) | Placeholder date |
|----|-------|----------------------|------------------|
| #46 | The Power of Two Choices | power-of-two-choices-load-balancing | 2026-04-06 |
| #47 | Retries, Timeouts, and the Thundering Herd | retries-timeouts-thundering-herd | 2026-04-13 |
| #48 | Consistent Hashing and Bounded Loads | consistent-hashing-bounded-loads | 2026-04-20 |
| #49 | Connection Draining & Zero-Downtime Deploys | connection-draining-zero-downtime-deploys | 2026-04-27 |
| #50 | kube-proxy: iptables vs IPVS vs eBPF | kube-proxy-iptables-ipvs-ebpf | 2026-05-04 |
| #51 | Service Mesh: Sidecar vs Ambient | service-mesh-sidecar-vs-ambient | 2026-05-11 |
| #52 | Multi-Cluster Service Discovery | multi-cluster-service-discovery | 2026-05-18 |
| #53 | Enforced Trust Zones / Microsegmentation (RSAC slide material) | enforced-trust-zones-microsegmentation | 2026-05-25 |
| #54 | mTLS at Scale: SPIFFE/SPIRE | mtls-at-scale-spiffe-spire | 2026-06-01 |
| #55 | Continuous Access Evaluation | continuous-access-evaluation | 2026-06-08 |
| #56 | HTTP/2 and HTTP/3 at the Proxy | http2-http3-quic-at-the-proxy | 2026-06-15 |
| #57 | TLS Termination & Session Resumption | tls-termination-session-resumption | 2026-06-22 |

## Follow-ups to do at merge time

1. **Re-date before publishing.** The dates above are placeholders. Posts cannot be future-dated
   (Jekyll skips future-dated posts and the build effectively drops them), so re-space them to when
   each actually publishes.
2. **Add sibling cross-links.** Each draft currently links only to posts that were already merged
   when it was written, not to its sibling drafts. After merging some, add bidirectional links
   between the related new posts.

## How these were made / house rules (for the next session)

- One branch + draft PR per post; never push to `main`; never `--admin`; `gh auth switch --user singhsanjay12` before any PR.
- Post files: `_posts/YYYY-MM-DD-<slug>.md` + hero SVG at `assets/img/posts/<slug>/hero.svg`.
- CI (`bundle exec jekyll b` then `ruby tests/run_all.rb`) enforces: ≤3 em dashes (aim 0); no `{{`/`{%`;
  internal links must resolve to a built post (only link already-merged posts); hero SVG `width="800"`,
  no duplicate attributes, and avoid `viewBox="0 -25 800 420"` / `Georgia,serif` for simple heroes; built
  post > 5KB; no future dates.
- Theme is pinned to `jekyll-theme-chirpy = 7.4.1` (Gemfile) to keep light mode; there is no committed
  `Gemfile.lock`.
