require_relative "test_helper"

# Enforces visual consistency rules across all SVG diagrams in assets/img/posts/.
#
# Three tiers of rules:
#   all_svgs        — must be true of every SVG regardless of age or format
#   standard_svgs   — SVGs that use the current viewBox="0 -25 800 420" canvas
#   captioned_svgs  — SVGs that include a Georgia-serif caption quote
class SvgTest < Minitest::Test
  SVG_GLOB        = "assets/img/posts/**/*.svg"
  STANDARD_VIEWBOX = 'viewBox="0 -25 800 420"'
  VIEWBOX_BOTTOM   = 395   # -25 + 420
  TEXT_BOTTOM_LIMIT = 385  # minimum 10px margin before viewBox edge

  def all_svgs
    Dir.glob(SVG_GLOB)
  end

  # SVGs that use the shared banner/grid/caption layout introduced for dns-lb and later posts.
  def standard_svgs
    all_svgs.select { |f| File.read(f).include?(STANDARD_VIEWBOX) }
  end

  # SVGs that include a caption section (detected by the Georgia serif quote line).
  def captioned_svgs
    all_svgs.select { |f| File.read(f).include?("Georgia,serif") }
  end

  # ── Canvas ────────────────────────────────────────────────────────────────

  # Every diagram must be exactly 800 px wide so embedded images are never
  # stretched or shrunk by the blog layout.
  def test_all_svgs_are_800px_wide
    all_svgs.each do |path|
      assert_match(/width="800"/, File.read(path),
        "#{path}: SVG must declare width=\"800\"")
    end
  end

  # ── Background gradient ───────────────────────────────────────────────────

  # Standard-format diagrams share the same subtle indigo→off-white gradient.
  # The gradient must be defined with id="bg" so the background <rect> can
  # reference it.  (Non-standard SVGs may use different gradient ids/colours.)
  def test_standard_svgs_define_bg_gradient
    standard_svgs.each do |path|
      assert_match(/id="bg"/, File.read(path),
        "#{path}: standard SVG must define a linearGradient with id=\"bg\"")
    end
  end

  # The two gradient stop colours must be exactly the brand values so all
  # standard diagrams share the same background tone.
  def test_standard_svgs_use_brand_gradient_colors
    standard_svgs.each do |path|
      content = File.read(path)
      assert_match(/#eef2ff/, content,
        "#{path}: gradient first stop must be #eef2ff (light indigo)")
      assert_match(/#f8fafc/, content,
        "#{path}: gradient second stop must be #f8fafc (off-white slate)")
    end
  end

  # ── Dot grid ──────────────────────────────────────────────────────────────

  # Standard-format diagrams use a subtle dot grid to give depth without noise.
  # Any new diagram that adopts the standard viewBox must also include the grid.
  def test_standard_svgs_have_dot_grid
    standard_svgs.each do |path|
      assert_match(/fill="#c7d2fe"/, File.read(path),
        "#{path}: standard SVG must include the dot grid (fill=\"#c7d2fe\")")
    end
  end

  # ── Caption quote text ────────────────────────────────────────────────────

  # The caption quote line uses a consistent typographic treatment across all
  # diagrams: bold italic Georgia serif at 12px in near-black.  A diagram may
  # also use Georgia for other purposes (e.g. a large hero title); we only
  # require that at least one Georgia element is a correctly-styled caption.
  def test_caption_quote_uses_correct_style
    captioned_svgs.each do |path|
      georgia_lines = File.read(path).lines.select { |l| l.include?("Georgia,serif") }
      assert georgia_lines.any?,
        "#{path}: captioned SVG must have at least one element with Georgia,serif"
      caption_line = georgia_lines.find do |l|
        l.match?(/font-size="12"/) &&
          l.match?(/font-weight="700"/) &&
          l.match?(/font-style="italic"/) &&
          l.match?(/fill="#1e293b"/)
      end
      assert caption_line,
        "#{path}: captioned SVG must have a caption quote with " \
        "font-size=\"12\", font-weight=\"700\", font-style=\"italic\", fill=\"#1e293b\""
    end
  end

  # ── Caption subtitle text ─────────────────────────────────────────────────

  # The subtitle below the quote uses a smaller slate-grey style.
  # font-size="9" and fill="#94a3b8" must both appear in captioned SVGs.
  def test_caption_subtitle_uses_correct_style
    captioned_svgs.each do |path|
      content = File.read(path)
      assert_match(/font-size="9"/, content,
        "#{path}: caption subtitle must use font-size=\"9\"")
      assert_match(/fill="#94a3b8"/, content,
        "#{path}: caption subtitle must use fill=\"#94a3b8\" (slate grey)")
    end
  end

  # ── Caption divider line ──────────────────────────────────────────────────

  # The horizontal rule above the caption uses the standard light border colour.
  def test_caption_divider_uses_standard_stroke
    captioned_svgs.each do |path|
      assert_match(/stroke="#e2e8f0"/, File.read(path),
        "#{path}: caption divider must use stroke=\"#e2e8f0\"")
    end
  end

  # ── Bottom margin ─────────────────────────────────────────────────────────

  # For the standard viewBox (y = -25 to 395) no text baseline should sit
  # below y=385.  Descenders on a 9px font extend ~3px below the baseline,
  # putting the lowest pixel at ~388 — still 7px from the clipping edge.
  def test_no_text_baseline_near_viewbox_bottom
    standard_svgs.each do |path|
      content = File.read(path)
      content.scan(/<text\b[^>]*\by="(\d+)"/) do |match|
        y = match[0].to_i
        assert y <= TEXT_BOTTOM_LIMIT,
          "#{path}: text at y=#{y} is within #{VIEWBOX_BOTTOM - y}px of the " \
          "viewBox bottom (#{VIEWBOX_BOTTOM}) — caption or content may be clipped. " \
          "Move it to y<=#{TEXT_BOTTOM_LIMIT}."
      end
    end
  end
end
