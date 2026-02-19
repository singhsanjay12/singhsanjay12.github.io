require_relative "test_helper"

# Verifies that every internal link written in a post source file resolves to
# a real page in the built site.  Catches broken cross-post references early,
# before they reach production and cause 404s.
class InternalLinksTest < Minitest::Test
  # Paths that intentionally don't produce HTML pages.
  SKIP_PREFIXES = %w[/assets/ /feed.xml /sitemap.xml /robots.txt].freeze

  # Returns true when the href looks like an internal path we should check.
  def internal?(href)
    href.start_with?("/") &&
      !href.start_with?("//") &&
      SKIP_PREFIXES.none? { |p| href.start_with?(p) }
  end

  # Check whether a site-relative path exists in the built output.
  # Handles three common URL forms:
  #   /2026/01/12/slug.html  -> _site/2026/01/12/slug.html  (direct file)
  #   /archives/             -> _site/archives/index.html   (directory index)
  #   /archives              -> _site/archives/index.html   (without trailing slash)
  def path_exists_in_site?(href)
    path = href.split("#").first.chomp("/")

    return File.exist?("#{SITE}/index.html") if path.empty?

    File.exist?("#{SITE}#{path}") ||
      File.exist?("#{SITE}#{path}/index.html") ||
      File.exist?("#{SITE}#{path}.html")
  end

  # Scan all post markdown sources for internal Markdown links [text](/path).
  def links_from_sources
    links = []
    Dir.glob("_posts/*.md").each do |source|
      File.read(source).scan(/\[[^\]]*\]\(([^)\s]+)\)/) do |match|
        href = match.first
        links << [source, href] if internal?(href)
      end
    end
    links
  end

  def test_no_broken_internal_links
    broken = links_from_sources.reject { |_, href| path_exists_in_site?(href) }

    assert broken.empty?,
      "Found #{broken.size} broken internal link(s) in post sources:\n" +
      broken.map { |file, href| "  #{file}: #{href}" }.join("\n") +
      "\nEach path must resolve to a real file in #{SITE}/ — " \
      "check permalink format (/:year/:month/:day/:title.html)"
  end
end
