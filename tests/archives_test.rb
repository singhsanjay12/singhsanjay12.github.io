require_relative "test_helper"

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
