require_relative "test_helper"

# Verifies that every internal link and asset reference written in a post
# source file resolves to a real file in the built site.
# Covers:
#   - Cross-post links:  [text](/2026/01/12/slug.html)
#   - In-body images:    ![alt](/assets/img/posts/.../diagram.svg)
#   - Front matter hero: image:\n  path: /assets/img/posts/.../hero.svg
class InternalLinksTest < Minitest::Test
  # Only skip infrastructure paths that Jekyll never copies as pages/assets.
  SKIP_PREFIXES = %w[/feed.xml /sitemap.xml /robots.txt].freeze

  def internal?(href)
    href.start_with?("/") &&
      !href.start_with?("//") &&
      SKIP_PREFIXES.none? { |p| href.start_with?(p) }
  end

  # Resolve a site-relative path to an actual file in _site/.
  # Handles:
  #   /2026/01/12/slug.html  -> _site/2026/01/12/slug.html   (direct file)
  #   /archives/             -> _site/archives/index.html    (directory index)
  #   /archives              -> _site/archives/index.html    (no trailing slash)
  #   /assets/img/hero.svg   -> _site/assets/img/hero.svg   (static asset)
  def path_exists_in_site?(href)
    path = href.split("#").first.chomp("/")

    return File.exist?("#{SITE}/index.html") if path.empty?

    File.exist?("#{SITE}#{path}") ||
      File.exist?("#{SITE}#{path}/index.html") ||
      File.exist?("#{SITE}#{path}.html")
  end

  # Collect all internal paths from a single source file.
  # Scans:
  #   1. Front matter image.path field (hero images)
  #   2. Markdown body for [text](href) and ![alt](src) links
  def links_from_source(source)
    content = File.read(source)
    links = []

    if (match = content.match(/\A---(.*?)---\n(.*)\z/m))
      front_matter, body = match.captures

      # Hero image path: `image:\n  path: /assets/img/...`
      front_matter.scan(/^\s*path:\s*(\/\S+)/) do |m|
        href = m.first
        links << [source, "front matter image.path", href] if internal?(href)
      end

      # In-body Markdown links [text](href) and images ![alt](src)
      body.scan(/\[[^\]]*\]\(([^)\s]+)\)/) do |m|
        href = m.first
        links << [source, "body link", href] if internal?(href)
      end
    else
      content.scan(/\[[^\]]*\]\(([^)\s]+)\)/) do |m|
        href = m.first
        links << [source, "body link", href] if internal?(href)
      end
    end

    links
  end

  def all_links
    Dir.glob("_posts/*.md").flat_map { |source| links_from_source(source) }
  end

  def test_no_broken_internal_links
    broken = all_links.reject { |_, _, href| path_exists_in_site?(href) }

    assert broken.empty?,
      "Found #{broken.size} broken internal link(s)/asset(s):\n" +
      broken.map { |file, location, href| "  #{file} (#{location}): #{href}" }.join("\n") +
      "\nEach path must resolve to a real file in #{SITE}/"
  end
end
