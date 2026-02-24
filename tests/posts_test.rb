require_relative "test_helper"

class PostsTest < Minitest::Test
  # All built post HTML files (excludes index pages, tabs, etc.)
  def built_posts
    Dir.glob("#{SITE}/**/*.html").reject do |f|
      basename = File.basename(f)
      basename == "index.html" ||
        basename == "404.html" ||
        basename == "archive.html" ||
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


  # Every post must have an explicit description for meta description SEO control.
  def test_posts_have_description
    Dir.glob("_posts/*.md").each do |source|
      front_matter = File.read(source).match(/\A---(.*?)---/m)&.captures&.first || ""
      assert_match(/^description:/, front_matter,
        "#{source} is missing a 'description:' field in front matter — " \
        "add one so jekyll-seo-tag uses it as the meta description instead of auto-generating")
    end
  end

  # Posts must not overuse em dashes — cap at 3 per post to keep prose readable.
  EM_DASH_LIMIT = 3

  def test_em_dash_count_in_post_sources
    Dir.glob("_posts/*.md").each do |source|
      body = File.read(source).sub(/\A---.*?---\n/m, "")
      count = body.scan(/\u2014/).size
      assert count <= EM_DASH_LIMIT,
        "#{source} contains #{count} em dashes (limit: #{EM_DASH_LIMIT}). " \
        "Use colons, commas, or parentheses for the excess."
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

  # "Further Reading" / related-posts section must not appear on any post.
  def test_no_further_reading_section
    built_posts.each do |path|
      html = File.read(path)
      refute_match(/id="related-posts"/, html,
        "#{path} contains the Further Reading section — remove 'related-posts' from tail_includes in _layouts/post.html")
    end
  end

  # Every post must have social share buttons rendered by post-sharing.html.
  def test_posts_have_share_buttons
    built_posts.each do |path|
      html = File.read(path)
      assert_match(/share-wrapper/, html,
        "#{path} is missing social share buttons — check _data/share.yml exists")
      assert_match(/fa-x-twitter|fa-linkedin|fa-facebook/, html,
        "#{path} share buttons must include X, LinkedIn, or Facebook icons")
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

  # DNS load balancing post: core failure modes must all be present.
  def test_dns_load_balancing_post_content
    post = Dir.glob("#{SITE}/**/when-dns-load-balancing-is-not-enough.html").first
    assert post, "DNS load balancing post must be present in built site"
    html = File.read(post)
    %w[TTL active-active circuit].each do |term|
      assert_match(/#{term}/i, html,
        "DNS load balancing post must mention '#{term}'")
    end
    assert_match(/connection/i, html,
      "DNS load balancing post must discuss connection reuse")
    assert_match(/health/i, html,
      "DNS load balancing post must discuss DNS having no health signal")
    assert_match(/fleet/i, html,
      "DNS load balancing post must discuss dynamic fleet behaviour")
    refute_match(/LinkedIn scale/i, html,
      "DNS load balancing post must not reference internal LinkedIn scale language")
  end

  # DNS post: key topics must all be present.
  def test_dns_post_content
    post = Dir.glob("#{SITE}/**/dns-the-silent-killer-of-distributed-systems.html").first
    assert post, "DNS post must be present in built site"
    html = File.read(post)
    %w[UDP TCP truncat TTL].each do |term|
      assert_match(/#{term}/i, html,
        "DNS post must mention '#{term}'")
    end
    assert_match(/recovery|recover/i, html,
      "DNS post must discuss recovery strategies")
    refute_match(/LinkedIn scale/i, html,
      "DNS post must not reference internal LinkedIn scale language")
  end
end
