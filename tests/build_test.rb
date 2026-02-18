require_relative "test_helper"

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
