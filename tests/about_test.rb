require_relative "test_helper"

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
