require_relative "test_helper"

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
    /tags/reverse-proxy/
    /tags/kubernetes/
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
