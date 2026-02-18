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
