require_relative "test_helper"

class VisitorCounterTest < Minitest::Test
  def setup
    @index = File.read("#{SITE}/index.html")
    @css   = File.read("#{SITE}/assets/css/jekyll-theme-chirpy.css")
  end

  # The hits.sh script must be injected into every built page, not just the index.
  def test_counter_script_present_on_all_pages
    Dir.glob("#{SITE}/**/*.html").reject { |f| f.include?("404") }.each do |path|
      html = File.read(path)
      assert_match(/hits\.sh/, html,
        "#{path} is missing the visitor counter script — check _includes/head.html")
    end
  end

  # Guard against the label being changed without updating the test.
  def test_counter_label_is_humans
    assert_match(/label=humans/, @index,
      "Visitor counter label must be 'humans' — update head.html if intentionally changed")
  end

  # The counter must be fixed-positioned so it floats at bottom-right on all pages.
  def test_counter_is_fixed_positioned
    assert_match(/#visitor-counter\b[^}]*position\s*:\s*fixed/m, @css,
      "#visitor-counter must use position: fixed in compiled CSS")
  end

  # Ensure it stays anchored to bottom-right, not drifting to another corner.
  def test_counter_anchored_bottom_right
    assert_match(/#visitor-counter\b[^}]*bottom\s*:/m, @css,
      "#visitor-counter must have a 'bottom' value in compiled CSS")
    assert_match(/#visitor-counter\b[^}]*right\s*:/m, @css,
      "#visitor-counter must have a 'right' value in compiled CSS")
  end
end
