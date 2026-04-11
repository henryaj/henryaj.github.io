#!/usr/bin/env ruby
require 'rss'
require 'net/http'
require 'json'
require 'fileutils'

FEED_URL  = 'https://henryaj.substack.com/feed'
API_URL   = 'https://henryaj.substack.com/api/v1/posts'
REPO_ROOT = File.expand_path('..', __dir__)
POSTS_DIR = File.join(REPO_ROOT, '_posts')
DATA_DIR  = File.join(REPO_ROOT, '_data')
DATA_FILE  = File.join(DATA_DIR, 'substack.json')
STATS_FILE = File.join(DATA_DIR, 'substack_stats.json')
LIMIT      = 5
USER_AGENT = 'Mozilla/5.0 (compatible; JekyllBuild/1.0)'

def http_get(url)
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  req = Net::HTTP::Get.new(uri)
  req['User-Agent'] = USER_AGENT
  req['Accept'] = '*/*'
  response = http.request(req)

  # Follow redirects
  if response.is_a?(Net::HTTPRedirection)
    return http_get(response['location'])
  end

  response.body
end

def fetch_api_metadata
  body = http_get("#{API_URL}?limit=50")
  posts = JSON.parse(body)

  metadata = {}
  posts.each do |post|
    metadata[post['slug']] = {
      comment_count: post['comment_count'] || 0,
      reaction_count: post['reaction_count'] || 0
    }
  end
  metadata
rescue StandardError => e
  warn "Warning: Could not fetch Substack API metadata: #{e.message}"
  {}
end

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

  # Extract footnote content by number before modifying anchors
  footnotes = {}
  html.scan(/<div class="footnote"[^>]*>\s*<a [^>]*class="footnote-number"[^>]*>(\d+)<\/a>\s*<div class="footnote-content">(.*?)<\/div>\s*<\/div>/m) do
    footnotes[$1] = $2.strip
  end

  # Remove footnote blocks from the bottom
  html = html.gsub(/<div class="footnote"[^>]*>\s*<a [^>]*class="footnote-number"[^>]*>\d+<\/a>\s*<div class="footnote-content">.*?<\/div>\s*<\/div>/m, '')

  # Convert inline footnote anchors to sidenotes: inject content right after the anchor
  html = html.gsub(/<a class="footnote-anchor"[^>]*id="([^"]*)"[^>]*href="([^"]*)"[^>]*>(\d+)<\/a>/) do
    id, _href, num = $1, $2, $3
    content = (footnotes[num] || '').gsub(/<\/?p>/, ' ').gsub(/<br\s*\/?>/, ' ').strip
    %(<span class="sidenote-wrapper"><a href="#fn-#{num}" class="sidenote-toggle"><sup>#{num}</sup></a><span class="sidenote"><strong>#{num}.</strong> #{content}</span></span>)
  end

  # Remove Substack-specific div wrappers and data-component-name attrs
  html = html.gsub(/ data-component-name="[^"]*"/, '')
  html = html.gsub(/<div class="pencraft[^"]*"[^>]*>.*?<\/div>/m, '')
  html = html.gsub(/<button[^>]*>.*?<\/button>/m, '')

  # Remove empty divs
  html = html.gsub(/<div>\s*<\/div>/, '')
  # Collapse multiple blank lines
  html = html.gsub(/\n{3,}/, "\n\n")

  # Append mobile footnotes section at the bottom
  unless footnotes.empty?
    html += "\n\n<div class=\"mobile-footnotes\">\n<hr>\n"
    footnotes.sort_by { |k, _| k.to_i }.each do |num, content|
      clean_content = content.gsub(/<\/?p>/, ' ').gsub(/<br\s*\/?>/, ' ').strip
      html += "<div class=\"mobile-footnote\" id=\"fn-#{num}\"><strong>#{num}.</strong> #{clean_content}</div>\n"
    end
    html += "</div>"
  end

  html.strip
end

xml = http_get(FEED_URL)

# Verify we got XML, not a Cloudflare challenge page
unless xml.start_with?('<?xml') || xml.start_with?('<rss')
  warn "Warning: RSS feed returned non-XML response (likely blocked). Generating homepage data from existing posts."
  FileUtils.mkdir_p(DATA_DIR)

  # Build homepage data from committed substack posts
  substack_posts = Dir.glob(File.join(POSTS_DIR, '*.md')).sort.reverse.filter_map do |f|
    content = File.read(f)
    next unless content.include?('source: substack')
    title = content[/^title:\s*"(.+)"/, 1]
    date = content[/^date:\s*(\S+)/, 1]
    slug = File.basename(f, '.md').sub(/^\d{4}-\d{2}-\d{2}-/, '')
    {title: title, url: "/#{slug}/", date: date}
  end

  File.write(DATA_FILE, JSON.pretty_generate(substack_posts.first(LIMIT)))
  puts "Wrote #{[substack_posts.length, LIMIT].min} posts to homepage data from existing files"
  exit 0
end

feed = RSS::Parser.parse(xml)
api_metadata = fetch_api_metadata

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

# Write per-post stats keyed by slug (for use in post layout)
stats = {}
api_metadata.each do |slug, meta|
  stats[slug] = { comment_count: meta[:comment_count], reaction_count: meta[:reaction_count] }
end
File.write(STATS_FILE, JSON.pretty_generate(stats))

puts "Synced #{new_count} new posts, #{homepage_data.length} in homepage data, #{stats.length} post stats"
