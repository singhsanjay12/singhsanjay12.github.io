require "minitest/autorun"

# Run from repo root after `jekyll build`:
#   ruby tests/site_test.rb

SITE = "_site"

class HomepageTest < Minitest::Test
  def setup
    @html = File.read("#{SITE}/index.html")
  end

  def test_light_theme_is_default
    assert_match(/data-mode="light"/, @html,
      "Homepage <html> must have data-mode=\"light\"")
  end

  def test_avatar_tag_present
    assert_match(%r{src="/assets/img/avatar\.jpg"}, @html,
      "Sidebar avatar img src must point to /assets/img/avatar.jpg")
  end

  def test_avatar_file_exists
    assert File.exist?("#{SITE}/assets/img/avatar.jpg"),
      "Avatar image file must exist in built site at assets/img/avatar.jpg"
  end

  def test_hero_section_present
    assert_match(/class="hero-section"/, @html,
      "Hero section must be present on homepage")
  end

  def test_hero_linkedin_link
    assert_match(%r{linkedin\.com/in/singhsanjay12}, @html,
      "LinkedIn URL must appear in hero section")
  end

  def test_hero_email_link
    assert_match(/gargwanshi\.sanjay@gmail\.com/, @html,
      "Email address must appear in hero section")
  end

  def test_css_loaded
    assert_match(%r{/assets/css/jekyll-theme-chirpy\.css}, @html,
      "Main Chirpy CSS must be linked in page head")
  end

  def test_site_title
    assert_match(/Sanjay Singh/, @html,
      "Site title must appear on homepage")
  end
end

class AboutPageTest < Minitest::Test
  def setup
    @html = File.read("#{SITE}/about/index.html")
  end

  def test_about_page_built
    assert File.exist?("#{SITE}/about/index.html"),
      "About page must be present in built site"
  end

  def test_experience_timeline
    assert_match(/timeline/, @html,
      "About page must contain experience timeline")
  end

  def test_linkedin_tenure
    assert_match(/2015.*Present|Present.*2015/m, @html,
      "Experience timeline must show 2015 – Present for LinkedIn")
  end

  def test_education_section
    assert_match(/Motilal Nehru/, @html,
      "Education section must list MNNIT Allahabad")
  end

  def test_focus_cards
    assert_match(/focus-grid/, @html,
      "About page must contain focus area cards grid")
  end

  def test_connect_links
    assert_match(/connect-links/, @html,
      "About page must contain connect links section")
  end
end

class CssIntegrityTest < Minitest::Test
  def setup
    @css = File.read("#{SITE}/assets/css/jekyll-theme-chirpy.css")
  end

  # Guard against referencing CSS variables that don't exist in Chirpy.
  # var(--border-color) is undefined; the correct variable is --main-border-color.
  def test_no_undefined_border_color_variable
    refute_match(/var\(--border-color\)/, @css,
      "CSS must not use var(--border-color) — Chirpy defines --main-border-color instead. " \
      "Undefined CSS variables resolve to nothing, making borders invisible.")
  end

  def test_focus_card_uses_card_shadow
    assert_match(/focus-card[^}]*card-shadow|card-shadow[^}]*focus-card/m, @css,
      "focus-card must use var(--card-shadow) for Chirpy-native card elevation")
  end

  def test_focus_card_uses_card_bg
    assert_match(/focus-card[^}]*card-bg|card-bg[^}]*focus-card/m, @css,
      "focus-card must set background via var(--card-bg)")
  end

  def test_hero_divider_uses_main_border_color
    assert_match(/hero-section[^}]*main-border-color|main-border-color[^}]*hero-section/m, @css,
      "hero-section bottom border must use var(--main-border-color)")
  end

  def test_custom_classes_compiled
    %w[hero-section focus-grid focus-card timeline connect-links].each do |cls|
      assert_match(/\.#{cls}\b/, @css, "CSS class .#{cls} must be present in compiled CSS")
    end
  end
end

class PostsTest < Minitest::Test
  # All built post HTML files (excludes index pages, tabs, etc.)
  def built_posts
    Dir.glob("#{SITE}/**/*.html").reject do |f|
      basename = File.basename(f)
      basename == "index.html" ||
        basename == "404.html" ||
        f.include?("/tags/") ||
        f.include?("/categories/") ||
        f.include?("/archives/") ||
        f.include?("/about/")
    end
  end

  # Every _posts/*.md source file must have a corresponding built HTML file.
  def test_all_source_posts_are_built
    Dir.glob("_posts/*.md").each do |source|
      slug = File.basename(source, ".md").sub(/^\d{4}-\d{2}-\d{2}-/, "")
      built = Dir.glob("#{SITE}/**/#{slug}.html")
      assert built.any?,
        "Source post '#{source}' has no built HTML in _site (expected slug: #{slug})"
    end
  end

  # No post should contain unprocessed Liquid tags in the rendered output.
  def test_no_unprocessed_liquid_in_posts
    built_posts.each do |path|
      html = File.read(path)
      refute_match(/\{\{|\{%/, html,
        "#{path} contains unprocessed Liquid tags — check for escaping issues in the source")
    end
  end

  # Enforce the no-em-dash rule on source files before they reach the reader.
  def test_no_em_dashes_in_post_sources
    Dir.glob("_posts/*.md").each do |source|
      body = File.read(source).sub(/\A---.*?---\n/m, "")
      refute_match(/\u2014/, body,
        "#{source} contains an em dash (—). Use colons, semicolons, or commas instead.")
    end
  end

  # A suspiciously small post HTML likely means content was dropped.
  def test_posts_have_minimum_content
    built_posts.each do |path|
      assert File.size(path) > 5_000,
        "#{path} is under 5KB — post content may be missing or truncated"
    end
  end

  # Giscus comments script must be injected into every post.
  def test_posts_have_giscus_comments
    built_posts.each do |path|
      html = File.read(path)
      assert_match(/giscus/, html,
        "#{path} is missing the Giscus comments script — check comments config in _config.yml")
    end
  end

  # Zero Trust post: key content and the LinkedIn reference we explicitly removed.
  def test_zero_trust_post_content
    post = Dir.glob("#{SITE}/**/zero-trust-with-reverse-proxy.html").first
    assert post, "Zero Trust post must be present in built site"
    html = File.read(post)
    assert_match(/TrustBridge/, html,
      "Zero Trust post must mention TrustBridge")
    assert_match(/mTLS/, html,
      "Zero Trust post must mention mTLS")
    assert_match(/enterprise scale/, html,
      "Zero Trust post must say 'enterprise scale'")
    refute_match(/LinkedIn scale/, html,
      "Zero Trust post must not say 'LinkedIn scale' — use 'enterprise scale'")
  end

  # Health checks post: both model names and both health check types must be present.
  def test_health_checks_post_content
    post = Dir.glob("#{SITE}/**/health-checks-client-vs-server-side-lb.html").first
    assert post, "Health checks post must be present in built site"
    html = File.read(post)
    %w[client-side server-side passive active].each do |term|
      assert_match(/#{term}/i, html,
        "Health checks post must mention '#{term}'")
    end
  end
end

class NavigationTest < Minitest::Test
  def setup
    @html = File.read("#{SITE}/index.html")
  end

  # Hero badge pills must be <a> tags, not plain <span> elements.
  def test_hero_badges_are_links
    assert_match(/<a[^>]+class="badge"/, @html,
      "Hero badge pills must be <a> anchor tags with href — plain <span> elements are not clickable")
  end

  # Every badge href must point to a page that actually exists in the built site.
  # If jekyll-archives is disabled or a link is misspelled this will catch it.
  BADGE_HREFS = %w[
    /tags/kubernetes/
    /tags/reverse-proxy/
    /tags/zero-trust/
    /tags/service-discovery/
    /tags/load-balancing/
    /tags/distributed-systems/
  ].freeze

  def test_hero_badge_hrefs_present_in_html
    BADGE_HREFS.each do |href|
      assert_match(/href="#{Regexp.escape(href)}"/, @html,
        "Expected badge link href=\"#{href}\" not found on homepage")
    end
  end

  def test_hero_badge_hrefs_resolve_to_built_pages
    BADGE_HREFS.each do |href|
      path = "#{SITE}#{href.chomp('/')}/index.html"
      assert File.exist?(path),
        "Badge href '#{href}' has no built page at #{path} — " \
        "jekyll-archives may be disabled or the tag/category name changed"
    end
  end
end

class ArchivesTest < Minitest::Test
  # Guard against jekyll-archives being accidentally disabled.
  # Without it, /tags/<name>/ and /categories/<name>/ return 404.
  def test_individual_tag_pages_generated
    tag_pages = Dir.glob("#{SITE}/tags/*/index.html")
    assert tag_pages.any?,
      "No individual tag pages found under _site/tags/ — " \
      "ensure jekyll-archives is enabled in Gemfile and _config.yml"
  end

  def test_individual_category_pages_generated
    cat_pages = Dir.glob("#{SITE}/categories/*/index.html")
    assert cat_pages.any?,
      "No individual category pages found under _site/categories/ — " \
      "ensure jekyll-archives is enabled in Gemfile and _config.yml"
  end

  # Every tag used in any post must have a corresponding built page.
  def test_all_post_tags_have_pages
    Dir.glob("_posts/*.md").each do |source|
      front_matter = File.read(source)[/\A---.*?---/m].to_s
      front_matter.scan(/tags:\s*\[([^\]]+)\]/).flatten.first.to_s
        .split(",").map(&:strip).each do |tag|
          slug = tag.downcase.gsub(/\s+/, "-")
          assert File.exist?("#{SITE}/tags/#{slug}/index.html"),
            "Post '#{source}' has tag '#{tag}' but no built page at _site/tags/#{slug}/"
        end
    end
  end

  # Every category used in any post must have a corresponding built page.
  def test_all_post_categories_have_pages
    Dir.glob("_posts/*.md").each do |source|
      front_matter = File.read(source)[/\A---.*?---/m].to_s
      front_matter.scan(/categories:\s*\[([^\]]+)\]/).flatten.first.to_s
        .split(",").map(&:strip).each do |cat|
          slug = cat.downcase.gsub(/\s+/, "-")
          assert File.exist?("#{SITE}/categories/#{slug}/index.html"),
            "Post '#{source}' has category '#{cat}' but no built page at _site/categories/#{slug}/"
        end
    end
  end

  # Archive pages must not be empty stubs.
  def test_tag_pages_have_content
    Dir.glob("#{SITE}/tags/*/index.html").each do |path|
      assert File.size(path) > 2_000,
        "#{path} is suspiciously small — tag archive page may be broken"
    end
  end

  def test_category_pages_have_content
    Dir.glob("#{SITE}/categories/*/index.html").each do |path|
      assert File.size(path) > 2_000,
        "#{path} is suspiciously small — category archive page may be broken"
    end
  end
end

class BuildIntegrityTest < Minitest::Test
  def test_site_directory_exists
    assert Dir.exist?(SITE),
      "_site directory must exist — run `jekyll build` first"
  end

  def test_css_file_built
    assert File.exist?("#{SITE}/assets/css/jekyll-theme-chirpy.css"),
      "CSS must be compiled and present in built site"
  end

  def test_post_built
    posts = Dir.glob("#{SITE}/**/*.html").select { |f| f.include?("zero-trust") }
    assert posts.any?,
      "Blog post about Zero Trust must be built"
  end

  def test_avatar_not_empty
    path = "#{SITE}/assets/img/avatar.jpg"
    assert File.exist?(path), "Avatar file must exist"
    assert File.size(path) > 10_000,
      "Avatar image is suspiciously small — may be corrupt or placeholder"
  end

  def test_no_broken_layout
    index = File.read("#{SITE}/index.html")
    refute_match(/Liquid (Error|Warning)/, index,
      "No Liquid errors should appear in rendered HTML")
  end
end
