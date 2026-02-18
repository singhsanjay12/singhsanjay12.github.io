# singh-sanjay.com

Personal engineering blog focused on distributed systems, Kubernetes, reverse proxies, and Zero Trust security. Live at [singh-sanjay.com](https://singh-sanjay.com).

Built with [Jekyll](https://jekyllrb.com) and the [Chirpy](https://github.com/cotes2020/jekyll-theme-chirpy) theme. Deployed automatically to GitHub Pages via GitHub Actions.

---

## Local Development

### Prerequisites

- Ruby 3.x (recommended via [Homebrew](https://brew.sh): `brew install ruby`)
- Bundler: `gem install bundler`

### Setup

```bash
git clone https://github.com/singhsanjay12/singhsanjay12.github.io.git
cd singhsanjay12.github.io
bundle install
```

### Run the dev server

```bash
bundle exec jekyll serve --livereload
```

Open [http://127.0.0.1:4000](http://127.0.0.1:4000). The site rebuilds automatically on file changes.

> **Note:** Giscus comments only render in production mode. To preview them locally:
> ```bash
> JEKYLL_ENV=production bundle exec jekyll serve
> ```

### Run tests

Build the site first, then run the test suite:

```bash
JEKYLL_ENV=production bundle exec jekyll build
ruby tests/run_all.rb
```

Individual suites can be run in isolation:

```bash
ruby tests/homepage_test.rb
ruby tests/posts_test.rb
# etc.
```

---

## Writing Posts

Create a file in `_posts/` named `YYYY-MM-DD-your-post-title.md`:

```yaml
---
title: "Your Post Title"
date: YYYY-MM-DD 00:00:00 -0700
categories: [Top Category, Sub Category]
tags: [tag-one, tag-two, tag-three]
---

Post content here.
```

---

## Project Structure

```
├── _config.yml                        # Site configuration (theme, Giscus, plugins)
├── _posts/                            # Blog posts (YYYY-MM-DD-slug.md)
├── _tabs/                             # Sidebar nav pages (about, tags, categories, archives)
├── _layouts/
│   └── home.html                      # Homepage layout (overrides Chirpy default)
├── _includes/
│   ├── navlinks.html
│   └── sharelinks.html
├── assets/
│   ├── css/
│   │   └── jekyll-theme-chirpy.scss   # Custom styles appended to Chirpy's compiled CSS
│   └── img/
│       ├── avatar.jpg                 # Sidebar profile photo
│       └── favicons/                  # favicon.svg, favicon.ico, apple-touch-icon.png
├── index.html                         # Homepage (hero section + Chirpy post list)
├── tests/
│   ├── test_helper.rb                 # Shared require + SITE constant
│   ├── run_all.rb                     # Runs all test suites in one process
│   ├── homepage_test.rb               # HomepageTest, NavigationTest
│   ├── about_test.rb                  # AboutPageTest
│   ├── css_test.rb                    # CssIntegrityTest
│   ├── posts_test.rb                  # PostsTest
│   ├── archives_test.rb               # ArchivesTest
│   └── build_test.rb                  # BuildIntegrityTest
├── .github/workflows/pages-deploy.yml # Build → test → deploy pipeline
├── Gemfile                            # jekyll, jekyll-theme-chirpy, jekyll-archives, jekyll-sitemap
└── README.md
```

---

## Deployment

Pushing to `main` triggers the GitHub Actions pipeline (`.github/workflows/pages-deploy.yml`), which:

1. Builds the site with `JEKYLL_ENV=production`
2. Runs `ruby tests/run_all.rb` — a failing test blocks deployment
3. Deploys to GitHub Pages at [singh-sanjay.com](https://singh-sanjay.com)

---

## Key Customizations

| What | Where |
|---|---|
| Hero section (name, role, badge pills) | `index.html` |
| Badge pill links | `index.html` — each links to a `/tags/<slug>/` page |
| Custom CSS (hero, focus cards, timeline) | `assets/css/jekyll-theme-chirpy.scss` |
| Giscus comments config | `_config.yml` under `comments:` |
| Individual tag/category pages | Enabled via `jekyll-archives` in `Gemfile` + `_config.yml` |
| Favicon | `assets/img/favicons/` |

---

## Troubleshooting

**Port 4000 already in use:**
```bash
bundle exec jekyll serve --port 4001
```

**Stale `_site` after config changes:**
Kill any background server (`pkill -f "jekyll serve"`) and rebuild manually — a running server will regenerate the site using the config it loaded at startup, overwriting a fresh build.

**Tag/category pages returning 404:**
Ensure `jekyll-archives` is present in `Gemfile` under `:jekyll_plugins` and configured in `_config.yml`. The `ArchivesTest` suite will catch this in CI.
