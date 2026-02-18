require_relative "test_helper"

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
