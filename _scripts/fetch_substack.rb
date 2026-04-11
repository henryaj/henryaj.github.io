#!/usr/bin/env ruby
require 'rss'
require 'net/http'
require 'json'
require 'fileutils'

FEED_URL  = 'https://henryaj.substack.com/feed'
REPO_ROOT = File.expand_path('..', __dir__)
POSTS_DIR = File.join(REPO_ROOT, '_posts')
DATA_DIR  = File.join(REPO_ROOT, '_data')
DATA_FILE = File.join(DATA_DIR, 'substack.json')
LIMIT     = 5

def slug_from_url(url)
  # https://henryaj.substack.com/p/some-post-title -> some-post-title
  url.split('/p/').last.split('?').first
end

def clean_html(html)
  # Remove Substack image expand/restack button blocks entirely
  html = html.gsub(/<div class="image-link-expand">.*?<\/div>\s*<\/div>\s*<\/div>/m, '')

  # Simplify captioned-image-container to <figure>
  # Extract just the first <img> and optional <figcaption> from each container
  html = html.gsub(/<div class="captioned-image-container"><figure>(.*?)<\/figure><\/div>/m) do
    inner = $1
    # Pull out the img src and alt from the mess of picture/source/srcset tags
    src = inner[/src="(https:\/\/substackcdn\.com[^"]+)"/, 1] || inner[/src="([^"]+)"/, 1]
    alt = inner[/alt="([^"]*)"/, 1] || ''
    caption = inner[/<figcaption[^>]*>(.*?)<\/figcaption>/m, 1]

    fig = "<figure>"
    fig += %(\n  <img src="#{src}" alt="#{alt}" loading="lazy">) if src
    fig += %(\n  <figcaption>#{caption}</figcaption>) if caption
    fig += "\n</figure>"
    fig
  end

  # Catch any remaining raw <img> tags with Substack clutter — simplify to src/alt
  html = html.gsub(/<img [^>]*data-attrs[^>]*>/) do |img|
    src = img[/src="([^"]+)"/, 1]
    alt = img[/alt="([^"]*)"/, 1] || ''
    %(<img src="#{src}" alt="#{alt}" loading="lazy">)
  end

  # Convert Substack footnotes to simpler markup
  html = html.gsub(/<a class="footnote-anchor"[^>]*id="([^"]*)"[^>]*href="([^"]*)"[^>]*>\d+<\/a>/) do
    %(<sup><a id="#{$1}" href="#{$2}">#{$1.sub('footnote-anchor-', '')}</a></sup>)
  end
  html = html.gsub(/<div class="footnote"[^>]*>/, '<div class="footnote">')
  html = html.gsub(/<a [^>]*class="footnote-number"[^>]*>(\d+)<\/a>/) do
    %(<strong>#{$1}.</strong> )
  end
  html = html.gsub(/<div class="footnote-content">/, '')

  # Remove Substack-specific div wrappers and data-component-name attrs
  html = html.gsub(/ data-component-name="[^"]*"/, '')
  html = html.gsub(/<div class="pencraft[^"]*"[^>]*>.*?<\/div>/m, '')
  html = html.gsub(/<button[^>]*>.*?<\/button>/m, '')

  # Remove empty divs
  html = html.gsub(/<div>\s*<\/div>/, '')
  # Collapse multiple blank lines
  html = html.gsub(/\n{3,}/, "\n\n")

  html.strip
end

uri  = URI(FEED_URL)
xml  = Net::HTTP.get(uri)
feed = RSS::Parser.parse(xml)

FileUtils.mkdir_p(POSTS_DIR)
FileUtils.mkdir_p(DATA_DIR)

homepage_data = []
new_count = 0

feed.items.each do |item|
  date = item.pubDate.strftime('%Y-%m-%d')
  slug = slug_from_url(item.link)
  filename = "#{date}-#{slug}.md"
  filepath = File.join(POSTS_DIR, filename)

  local_url = "/#{slug}/"

  # Build homepage data for the most recent posts
  if homepage_data.length < LIMIT
    homepage_data << {
      title: item.title,
      url: local_url,
      date: date
    }
  end

  # Skip if post already exists
  if File.exist?(filepath)
    puts "  skip: #{filename} (already exists)"
    next
  end

  content = clean_html(item.content_encoded)

  # Escape YAML-unsafe characters in title
  safe_title = item.title.gsub('"', '\\"')

  frontmatter = <<~YAML
    ---
    layout: post
    title: "#{safe_title}"
    date: #{date}
    canonical_url: #{item.link}
    source: substack
    ---
  YAML

  File.write(filepath, frontmatter + "\n" + content + "\n")
  puts "  new:  #{filename}"
  new_count += 1
end

File.write(DATA_FILE, JSON.pretty_generate(homepage_data))
puts "Synced #{new_count} new posts, #{homepage_data.length} in homepage data"
