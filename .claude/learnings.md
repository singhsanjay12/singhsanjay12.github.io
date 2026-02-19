# Agent Learnings — singhsanjay12.github.io

Reference for Claude and other agents working in this repo. Covers conventions, gotchas, and patterns discovered across multiple sessions.

---

## Workflow Rules

- **Never merge a PR without explicit user confirmation.** Always create the PR, share the URL, and wait for the user to say "merge it" before running `gh pr merge`.
- Branch naming: `{username}/{description}` in kebab-case. Username is `ssingh1`.
- Stage specific files with `git add <file>`, never `git add .` or `git add -A`.
- Commit messages should explain *why*, not just *what*.

---

## Post Front Matter

```yaml
---
title: "Post Title"
date: YYYY-MM-DD 12:00:00 +0000
categories: [Top, Sub]
tags: [tag-one, tag-two]
image:
  path: /assets/img/posts/<slug>/hero.svg
  alt: "Description of the hero image"
---
```

The `image:` block is what causes the hero to appear on the home page and at the top of the post. Without it, no image shows.

---

## SVG Design System

All diagrams and hero images in this repo follow a consistent visual language.

### Canvas Sizes

| Use | `width` | `height` | `viewBox` |
|---|---|---|---|
| Hero image (home page) | 800 | 420 | `0 -25 800 420` |
| Flow / architecture diagram | 800 | varies | `0 0 800 <height>` |

**Hero images must use `viewBox="0 -25 800 420"`** (not `0 0 800 420`). The Chirpy theme renders post-list thumbnails with `object-fit: cover` at a 40:21 ratio. The `-25` vertical offset shifts content down slightly so it is not clipped at the top.

### Color Palette

| Role | Hex | Usage |
|---|---|---|
| Blue (primary) | `#4f8ef7` / `#2563eb` | Client nodes, main flow arrows, TrustBridge header |
| Blue dark | `#1d4ed8` | Gradient end for TrustBridge circle |
| Green | `#27ae60` | Healthy / success / backend nodes |
| Amber | `#f59e0b` | Warning / degraded / policy check |
| Red | `#e74c3c` | Error / blocked / attacker |
| Slate text | `#1e293b` | Primary labels |
| Muted text | `#64748b` | Secondary labels |
| Very muted | `#94a3b8` | Captions, dashed connectors |
| Background | gradient `#eef2ff` → `#f8fafc` | All SVG backgrounds |
| White | `#ffffff` | Node fill |

### Standard `<defs>` Block

```xml
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1" gradientUnits="objectBoundingBox">
    <stop offset="0%" stop-color="#eef2ff"/>
    <stop offset="100%" stop-color="#f8fafc"/>
  </linearGradient>
  <!-- Blue right-pointing arrow -->
  <marker id="arrowB" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
    <path d="M0,0 L0,6 L8,3 z" fill="#4f8ef7"/>
  </marker>
  <!-- Green right-pointing arrow -->
  <marker id="arrowG" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
    <path d="M0,0 L0,6 L8,3 z" fill="#27ae60"/>
  </marker>
  <!-- Red right-pointing arrow -->
  <marker id="arrowR" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
    <path d="M0,0 L0,6 L8,3 z" fill="#e74c3c"/>
  </marker>
  <!-- Gray LEFT-pointing arrow (refX="2", flipped path) -->
  <marker id="arrowL" markerWidth="8" markerHeight="8" refX="2" refY="3" orient="auto">
    <path d="M8,0 L8,6 L0,3 z" fill="#94a3b8"/>
  </marker>
  <filter id="sh">
    <feDropShadow dx="0" dy="2" stdDeviation="3" flood-color="#00000018"/>
  </filter>
</defs>
<rect width="800" height="<H>" fill="url(#bg)"/>
```

### Rounded Header Band on a Box

To get a box with a colored rounded-top / square-bottom header:

```xml
<!-- Outer box -->
<rect x="X" y="Y" width="W" height="H" rx="10" fill="white" stroke="#2563eb" stroke-width="2" filter="url(#sh)"/>
<!-- Header band (top rounded, bottom flush) -->
<path d="M{X+rx},{Y} L{X+W-rx},{Y} Q{X+W},{Y},{X+W},{Y+rx} L{X+W},{Y+bh} L{X},{Y+bh} L{X},{Y+rx} Q{X},{Y},{X+rx},{Y} Z" fill="#2563eb"/>
<!-- Text in header -->
<text x="{X+W/2}" y="{Y+bh-6}" text-anchor="middle" fill="white" font-size="11" font-weight="700">Label</text>
```

Where `bh` is the header band height (typically 28–32px) and `rx` is 10.

### Animation Classes (Hero Images)

```xml
<defs>
  <style>
    @keyframes dash  { to { stroke-dashoffset: -20; } }
    @keyframes pulse { 0%,100% { opacity:1; } 50% { opacity:0.3; } }
    @keyframes err   { 0%,100% { opacity:0.9; } 50% { opacity:0.15; } }
    .flow   { animation: dash  1.8s linear      infinite; }
    .block  { animation: dash  1.1s linear      infinite; }
    .blink  { animation: pulse 1.3s ease-in-out infinite; }
    .denied { animation: err   0.9s ease-in-out infinite; }
  </style>
</defs>
```

Apply to `<line>` elements with `stroke-dasharray="6 4"`. Use `.flow` for normal traffic, `.block` for attack traffic (faster), `.denied` on the blocked badge, `.blink` on a glow halo circle behind a central node.

### Font

```
font-family="'Segoe UI',system-ui,sans-serif"
```

Set on the root `<svg>` element. Individual elements can override with `font-family="Georgia,serif"` for italic quotes/captions.

---

## Asset Layout

```
assets/img/posts/
├── dns/
│   ├── hero.svg
│   ├── udp-truncation.svg
│   └── ttl-timeline.svg
├── lb/
│   ├── hero.svg
│   ├── server-side-lb.svg
│   ├── client-side-lb.svg
│   ├── server-side-health-check.svg
│   ├── active-health-check.svg
│   └── passive-health-check.svg
└── zero-trust/
    ├── hero.svg
    └── trustbridge-flow.svg
```

When adding images for a new post, create a subdirectory named after the post's topic slug (not the full date-slug).

---

## Replacing ASCII Diagrams in Posts

ASCII diagrams in posts are fenced code blocks:

````
```
   ASCII content here
```
````

**Gotcha**: The `Edit` tool requires an *exact* byte-for-byte match for `old_string`. Special characters in ASCII art (box-drawing chars like `│`, `─`, `┌`, `►`, circled numbers `①②③`) must be copied verbatim from the file — do not retype them. Always `Read` the file first and copy the exact lines from the output into `old_string`.

Replace with an image reference:

```markdown
![Alt text describing the diagram](/assets/img/posts/<slug>/<name>.svg)
```

---

## Posts in This Repo

| File | Topic | Images |
|---|---|---|
| `2025-01-10-how-dns-really-works.md` | DNS resolution, UDP truncation, TTL | `dns/hero.svg`, `dns/udp-truncation.svg`, `dns/ttl-timeline.svg` |
| `2025-08-03-zero-trust-with-reverse-proxy.md` | Zero Trust, mTLS, TrustBridge (Part 1) | `zero-trust/hero.svg`, `zero-trust/trustbridge-flow.svg` |
| `2026-01-12-health-checks-client-vs-server-side-lb.md` | Load balancing health checks | `lb/hero.svg`, `lb/server-side-lb.svg`, `lb/client-side-lb.svg`, `lb/server-side-health-check.svg`, `lb/active-health-check.svg`, `lb/passive-health-check.svg` |

---

## Hero Image Concepts (for consistency)

Each hero uses a distinct visual concept tied to the post's central irony or insight:

| Post | Concept |
|---|---|
| DNS | Hub-and-spoke resolver chain; red broken node for NXDOMAIN |
| Zero Trust | Hub-and-spoke with TrustBridge as blue enforcer; attacker blocked with animated ✗ |
| Load Balancing | "Zombie instance" — Instance 3 split green (health check: 200 OK) / red (users: 500 error) |

New hero images should follow the same hub-and-spoke or narrative split-panel pattern, use the standard color palette, include an italic quote caption at the bottom, and use the `viewBox="0 -25 800 420"` offset.

---

## Common Mistakes to Avoid

1. **Merging without user confirmation** — always share the PR URL and wait.
2. **`git add .`** — stage specific files only.
3. **Hero image not appearing on home page** — check that `image: path:` is in the front matter *and* that `viewBox="0 -25 800 420"` is used (not `0 0 800 420`).
4. **Left-pointing arrow marker** — `arrowL` needs `refX="2"` (not `refX="6"`) and a flipped path `M8,0 L8,6 L0,3 z`. Using the standard right-arrow defs for a left-pointing arrow produces a misaligned arrowhead.
5. **Edit tool exact match** — read the file, copy content verbatim, do not paraphrase or re-encode special characters.
