#!/usr/bin/env ruby
require 'rss'
require 'cgi'
require 'net/http'
require 'json'
require 'time'
require 'fileutils'

FEED_URL  = 'https://henryaj.substack.com/feed'
API_URL   = 'https://henryaj.substack.com/api/v1/posts'
POST_API  = 'https://henryaj.substack.com/api/v1/post'
REPO_ROOT = File.expand_path('..', __dir__)
POSTS_DIR = File.join(REPO_ROOT, '_posts')
DATA_DIR  = File.join(REPO_ROOT, '_data')
IMAGES_DIR = File.join(REPO_ROOT, 'images', 'substack')
DATA_FILE      = File.join(DATA_DIR, 'substack.json')
STATS_FILE     = File.join(DATA_DIR, 'substack_stats.json')
FAVOURITES_FILE = File.join(DATA_DIR, 'reader_favourites.json')
COMMENTS_FILE  = File.join(DATA_DIR, 'substack_comments.json')
LIMIT          = 5
FAVOURITES_YEAR = '2026'
FAVOURITES_LIMIT = 5
USER_AGENT = 'Mozilla/5.0 (compatible; JekyllBuild/1.0)'

def http_fetch(url, depth = 0)
  raise "Too many redirects for #{url}" if depth > 5

  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == 'https'
  req = Net::HTTP::Get.new(uri)
  req['User-Agent'] = USER_AGENT
  req['Accept'] = '*/*'
  response = http.request(req)

  # Follow redirects
  if response.is_a?(Net::HTTPRedirection)
    return http_fetch(response['location'], depth + 1)
  end

  response
end

def http_get(url)
  http_fetch(url).body
end

def fetch_api_metadata
  metadata = {}
  page_size = 50
  offset = 0
  loop do
    body = http_get("#{API_URL}?limit=#{page_size}&offset=#{offset}")
    posts = JSON.parse(body)
    break if posts.empty?
    posts.each do |post|
      metadata[post['slug']] = {
        id: post['id'],
        title: post['title'],
        post_date: post['post_date'],
        comment_count: post['comment_count'] || 0,
        reaction_count: post['reaction_count'] || 0
      }
    end
    break if posts.length < page_size
    offset += page_size
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

# Index just past the </div> closing the tag that opens at `start`, or nil if the
# markup is unbalanced. Substack nests its widgets and embeds several divs deep, so
# a non-greedy /<div...>.*?<\/div>/ would close at the first </div> and leave orphaned
# markup behind; the only way to find the real closing tag is to count depth.
def div_extent(html, start)
  depth = 0
  i = start
  while i < html.length
    if html[i, 4] == '<div'
      depth += 1
      i += 4
    elsif html[i, 6] == '</div>'
      depth -= 1
      i += 6
      return i if depth.zero?
    else
      i += 1
    end
  end
  nil
end

# Remove the "reader-supported publication / Subscribe" CTA Substack appends to the
# body, along with the <hr> separator it sometimes puts immediately before it.
def strip_subscribe_widgets(html)
  loop do
    start = html.index(/<div[^>]*class="[^"]*subscription-widget[^"]*"/)
    break unless start

    finish = div_extent(html, start)
    # Unbalanced markup: leave it alone rather than truncating the post.
    break unless finish

    preceding = html[0...start]
    if (sep = preceding.match(/<div>\s*<hr>\s*<\/div>\s*\z/))
      start = sep.begin(0)
    end

    html = html[0...start] + html[finish..]
  end
  html
end

def clean_html(html)
  html = strip_subscribe_widgets(html)

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

# Substack ships its embeds as a <div> carrying a data-attrs JSON payload. Some of
# them (an embedded post) also contain rendered markup, styled by CSS that exists
# only on Substack — here that arrived as a bare stack of links. The rest (post
# digests, image galleries, tweets, video) contain nothing at all: the payload IS
# the content, and without Substack's JavaScript to expand it the reader sees an
# empty div. 35 gallery images were invisible on this site for exactly that reason.
#
# So: read the payload and re-emit each embed as plain markup the site's own CSS
# already knows how to set. Everything Substack renders that this site has no
# vocabulary for — cover thumbnails, avatars, like/comment counts that freeze at
# fetch time and rot from there — is dropped rather than approximated.
EMBED_CLASSES = %w[
  embedded-post-wrap
  digest-post-embed
  image-gallery-embed
  twitter-embed
  native-video-embed
].freeze

def embed_attrs(tag)
  json = tag[/data-attrs="([^"]*)"/, 1]
  return nil unless json
  JSON.parse(CGI.unescapeHTML(json))
rescue JSON::ParserError
  nil
end

def esc(text)
  CGI.escapeHTML(text.to_s)
end

# Each part in its own span: Silkscreen at 12px with a letter-spaced tracking runs
# wide, and a three-name byline wraps — without this it breaks inside the date and
# leaves the year stranded on a line of its own.
def meta_line(parts)
  parts.compact.map { |part| %(<span>#{esc(part)}</span>) }.join(' &#183; ')
end

def embed_date(value)
  Time.parse(value).utc.strftime('%-d %b %Y')
rescue StandardError
  nil
end

# Substack's CDN resizes anything you hand it, and the signature in the URLs it
# writes turns out not to be checked — so a raw S3 original (galleries reference
# those directly, at up to 4000px) can be pulled through the same transform the
# body images use. That's a 3.2MB PNG down to a 64KB JPEG, and it moots the HEICs.
def cdn_resized(url)
  return url if url.start_with?('https://substackcdn.com/')
  "https://substackcdn.com/image/fetch/w_1456,c_limit,f_auto,q_auto:good," \
    "fl_progressive:steep/#{CGI.escape(url)}"
end

# An embedded post that happens to be one of Henry's own is on this site too, so
# point at the local copy rather than sending the reader back to Substack.
def embed_link(url)
  slug = url[%r{\Ahttps://henryaj\.substack\.com/p/([^/?#]+)}, 1]
  return url unless slug
  Dir.glob(File.join(POSTS_DIR, "*-#{slug}.md")).empty? ? url : "/#{slug}/"
end

# Both the "embedded post" and "post digest" embeds are a pointer at another post,
# so they get the same card: title, standfirst if there is one, and a Silkscreen
# meta line built from whichever of the two payload shapes this is.
def post_card(attrs)
  url = attrs['url'] || attrs['canonical_url']
  title = attrs['title']
  return '' unless url && title

  bylines = (attrs['bylines'] || attrs['publishedBylines'] || []).filter_map { |b| b['name'] }
  meta = [attrs['publication_name'], *bylines, embed_date(attrs['date'] || attrs['post_date'])]
  excerpt = [attrs['truncated_body_text'], attrs['caption']].map(&:to_s).find { |t| !t.strip.empty? }

  card = %(<aside class="post-embed">\n)
  card += %(  <a class="post-embed-title" href="#{esc(embed_link(url))}">#{esc(title)}</a>\n)
  card += %(  <p class="post-embed-excerpt">#{esc(excerpt.strip)}</p>\n) if excerpt
  card += %(  <div class="post-embed-meta">#{meta_line(meta)}</div>\n)
  card + %(</aside>)
end

def gallery_figure(attrs)
  gallery = attrs['gallery'] || {}
  images = (gallery['images'] || []).filter_map { |image| image['src'] }
  return '' if images.empty?

  alt = esc(gallery['alt'])
  figure = %(<figure class="gallery">\n)
  figure += images.map { |src| %(  <img src="#{esc(cdn_resized(src))}" alt="#{alt}" loading="lazy">) }.join("\n")
  figure += %(\n  <figcaption>#{esc(gallery['caption'])}</figcaption>) unless gallery['caption'].to_s.strip.empty?
  figure + %(\n</figure>)
end

# Just the text and who said it. The payload also carries a twimg video URL and a
# thumbnail with a play button burned into it, both of which would be a dead end
# here — this site has no player and hotlinking twimg is a broken image waiting to
# happen.
def tweet_quote(attrs)
  text = attrs['full_text']
  return '' unless text

  who = [attrs['name'], attrs['username'] && "@#{attrs['username']}"].compact.join(' ')
  date = embed_date(attrs['date'])
  meta = [attrs['url'] ? %(<a href="#{esc(attrs['url'])}">#{esc(who)}</a>) : %(<span>#{esc(who)}</span>),
          date && %(<span>#{esc(date)}</span>)].compact.join(' &#183; ')
  %(<blockquote class="tweet-embed">\n  <p>#{esc(text.strip)}</p>\n) +
    %(  <div class="post-embed-meta">#{meta}</div>\n</blockquote>)
end

# Substack uploads video to its own player and the payload names only an internal
# upload id — there's no URL to point a <video> at. Say so and link out, rather
# than leaving the reader with the silent gap the empty div gave them.
def video_link(_attrs, canonical_url)
  return '' unless canonical_url
  %(<p class="post-embed-meta">Video &#183; ) +
    %(<a href="#{esc(canonical_url)}">watch on Substack</a></p>)
end

def rewrite_embed(klass, attrs, canonical_url)
  case klass
  when 'embedded-post-wrap', 'digest-post-embed' then post_card(attrs)
  when 'image-gallery-embed' then gallery_figure(attrs)
  when 'twitter-embed' then tweet_quote(attrs)
  when 'native-video-embed' then video_link(attrs, canonical_url)
  else ''
  end
end

def rewrite_embeds(html, canonical_url)
  EMBED_CLASSES.each do |klass|
    search_from = 0
    loop do
      start = html.index(%(<div class="#{klass}"), search_from)
      break unless start

      finish = div_extent(html, start)
      # Unbalanced markup: leave the embed alone rather than eating the rest of the post.
      break unless finish

      attrs = embed_attrs(html[start...finish])
      replacement = attrs ? rewrite_embed(klass, attrs, canonical_url) : ''
      html = html[0...start] + replacement + html[finish..]
      # Past the replacement, so a handler that declines to rewrite can't spin forever.
      search_from = start + replacement.length
    end
  end
  html
end

# Substack hotlinks every image from its own CDN, so a post here is only as durable
# as those URLs are. Pull each image into the repo the first time it's seen and
# rewrite the tag to point at the local copy.
#
# Fetch the CDN URL rather than the S3 original it wraps: the originals include
# HEICs, which most browsers won't render, and the CDN transcodes them to JPEG on
# the way out. The transform in the URL (w_1456 for body images, w_56 for the odd
# inline logo) is left as Substack wrote it, so each image arrives at the size the
# post actually asked for.
IMAGE_EXTENSIONS = {
  'image/jpeg' => 'jpg',
  'image/png'  => 'png',
  'image/gif'  => 'gif',
  'image/webp' => 'webp',
  'image/avif' => 'avif',
  'image/svg+xml' => 'svg'
}.freeze

# Images land in images/substack/<slug>/, numbered in the order they appear. Nothing
# reads the number, so a gap or a restart after a failed fetch is harmless — but two
# files must never collide, hence picking up after whatever is already on disk.
def next_image_path(slug, ext)
  dir = File.join(IMAGES_DIR, slug)
  FileUtils.mkdir_p(dir)
  used = Dir.children(dir).map { |f| File.basename(f, '.*').to_i }
  seq = (used.max || 0) + 1
  File.join(dir, "#{seq}.#{ext}")
end

def download_image(url, slug)
  response = http_fetch(url)
  unless response.is_a?(Net::HTTPSuccess)
    warn "    warn: #{response.code} fetching #{url}"
    return nil
  end

  type = response['content-type'].to_s.split(';').first
  ext = IMAGE_EXTENSIONS[type]
  unless ext
    warn "    warn: unhandled content type #{type.inspect} for #{url}"
    return nil
  end

  path = next_image_path(slug, ext)
  File.binwrite(path, response.body)
  "/images/substack/#{slug}/#{File.basename(path)}"
rescue StandardError => e
  warn "    warn: could not fetch #{url}: #{e.message}"
  nil
end

# Only <img src> is touched. The data-attrs JSON blobs on Substack's embed divs
# carry CDN URLs too, but nothing on this site renders them.
def localise_images(html, slug)
  seen = {}
  html.gsub(/(<img\b[^>]*\bsrc=")([^"]+)(")/) do
    prefix, url, suffix = $1, $2, $3
    if url.start_with?('http')
      local = seen.key?(url) ? seen[url] : (seen[url] = download_image(url, slug))
      url = local if local
    end
    "#{prefix}#{url}#{suffix}"
  end
end

# Runs over every Substack post on each sync, not just the ones written this time:
# both passes are idempotent (a rewritten post has no embeds or remote URLs left to
# find) and it means a fetch that failed on an earlier run gets another go. Embeds
# are rewritten before images, so the gallery images they unpack get localised in
# the same sweep.
def rewrite_posts
  Dir.glob(File.join(POSTS_DIR, '*.md')).sort.each do |path|
    raw = File.read(path)
    next unless raw.include?('source: substack')
    # Split the frontmatter off so rewriting can only ever touch the body.
    head, body = raw.match(/\A(---\n.*?\n---\n)(.*)\z/m)&.captures
    next unless body

    slug = File.basename(path, '.md').sub(/^\d{4}-\d{2}-\d{2}-/, '')
    rewritten = localise_images(rewrite_embeds(body, head[/^canonical_url:\s*(\S+)/, 1]), slug)
    next if rewritten == body

    File.write(path, head + rewritten)
    puts "  rewrote: #{File.basename(path)}"
  end
end

# Comments live only on Substack — there's no backend here — so they're pulled in
# read-only and rendered at the foot of the post. The endpoint takes no token: the
# thread is public, and so is the JSON.
#
# Every sync rewrites the whole file rather than appending to it, which is what
# makes an edited or deleted comment upstream actually disappear here. Posts whose
# fetch fails keep whatever was synced last time — a network blip shouldn't silently
# empty a thread.
MAX_COMMENT_DEPTH = 3

# A comment body arrives twice: `body` as plain text, and `body_json` as a ProseMirror
# document. The document is what gets rendered, because the plain text has lost the
# links. It's rebuilt node by node with every string escaped on the way out — this is
# text written by strangers, and none of it may reach the page as markup.
def comment_marks(html, marks)
  (marks || []).reduce(html) do |acc, mark|
    case mark['type']
    when 'strong' then "<strong>#{acc}</strong>"
    when 'em' then "<em>#{acc}</em>"
    when 'code' then "<code>#{acc}</code>"
    when 'link'
      href = mark.dig('attrs', 'href').to_s
      # Anything not plainly http(s) — javascript:, data: — is dropped, not sanitised.
      next acc unless href.match?(%r{\Ahttps?://}i)
      %(<a href="#{esc(href)}" rel="nofollow ugc noopener">#{acc}</a>)
    else acc
    end
  end
end

def comment_node(node)
  children = (node['content'] || []).map { |child| comment_node(child) }.join
  case node['type']
  when 'text' then comment_marks(esc(node['text']), node['marks'])
  when 'paragraph' then children.empty? ? '' : "<p>#{children}</p>"
  when 'blockquote' then "<blockquote>#{children}</blockquote>"
  when 'hard_break', 'hardBreak' then '<br>'
  # doc, lists, and whatever Substack adds later: keep the text, drop the wrapper.
  else children
  end
end

def comment_html(comment)
  doc = comment['body_json']
  return comment_node(doc) if doc

  # No document at all (the odd old comment): the plain text still has the paragraphs.
  comment['body'].to_s.split(/\n{2,}/).filter_map do |para|
    next if para.strip.empty?
    "<p>#{esc(para.strip).gsub("\n", '<br>')}</p>"
  end.join
end

# Threads nest arbitrarily — this one goes four deep — and Liquid has no clean way to
# recurse a template into itself. So the tree is flattened here into reading order with
# a depth on each comment, and the layout indents from that. A deleted comment is
# dropped but its replies are kept, pulled up to its depth rather than left indented
# under a parent that isn't there.
def flatten_comments(comments, depth, out = [])
  (comments || []).each do |comment|
    kept = !comment['deleted'] && comment['status'] == 'published'
    if kept
      out << {
        name: comment['name'].to_s.strip,
        date: embed_date(comment['date']),
        datetime: comment['date'],
        depth: [depth, MAX_COMMENT_DEPTH].min,
        reactions: comment['reaction_count'].to_i,
        html: comment_html(comment)
      }
    end
    flatten_comments(comment['children'], kept ? depth + 1 : depth, out)
  end
  out
end

def existing_comments
  JSON.parse(File.read(COMMENTS_FILE))
rescue StandardError
  {}
end

def fetch_comments(api_metadata)
  previous = existing_comments
  threads = {}
  api_metadata.each do |slug, meta|
    next unless meta[:id] && meta[:comment_count].to_i.positive?

    # The render is inside the rescue too: an unexpected node shape is as much a
    # reason to keep the last good thread as a failed request, and letting it raise
    # here would abort the sync after the other data files had already been written.
    begin
      payload = JSON.parse(http_get("#{POST_API}/#{meta[:id]}/comments?all_comments=true&sort=oldest_first"))
      thread = flatten_comments(payload['comments'], 0)
    rescue StandardError => e
      warn "  warn: could not fetch comments for #{slug}: #{e.message}"
      threads[slug] = previous[slug] if previous[slug]
      next
    end

    threads[slug] = thread unless thread.empty?
  end
  threads
end


xml = http_get(FEED_URL)

# Verify we got XML, not a Cloudflare challenge page
unless xml.start_with?('<?xml') || xml.start_with?('<rss')
  warn "Warning: RSS feed returned non-XML response (likely blocked). Generating homepage data from existing posts."
  FileUtils.mkdir_p(DATA_DIR)

  # Build homepage data from committed substack posts
  substack_posts = Dir.glob(File.join(POSTS_DIR, '*.md')).filter_map do |f|
    content = File.read(f)
    next unless content.include?('source: substack')
    # Both values were written as double-quoted YAML scalars, so an embedded quote
    # is on disk as \". Pulling them back out with a regex rather than a YAML parser
    # means undoing that by hand — otherwise the backslashes reach the homepage.
    title = content[/^title:\s*"(.+)"/, 1]&.gsub('\\"', '"')
    subtitle = content[/^subtitle:\s*"(.*)"/, 1]&.gsub('\\"', '"')
    date_str = content[/^date:\s*(.+)$/, 1]&.strip
    slug = File.basename(f, '.md').sub(/^\d{4}-\d{2}-\d{2}-/, '')
    parsed = Time.parse(date_str) rescue nil
    short_date = parsed ? parsed.utc.strftime('%b %-d') : date_str
    {title: title, url: "/#{slug}/", date: short_date, subtitle: subtitle.to_s,
     _sort: parsed || Time.at(0)}
  end.sort_by { |p| p[:_sort] }.reverse.map { |p| p.reject { |k, _| k == :_sort } }

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

feed.items.sort_by { |item| item.pubDate }.reverse.each do |item|
  date = item.pubDate.utc.strftime('%Y-%m-%d')
  datetime = item.pubDate.utc.strftime('%Y-%m-%d %H:%M:%S +0000')
  slug = slug_from_url(item.link)
  filename = "#{date}-#{slug}.md"
  filepath = File.join(POSTS_DIR, filename)

  local_url = "/#{slug}/"

  # Build homepage data for the most recent posts
  if homepage_data.length < LIMIT
    homepage_data << {
      title: item.title,
      url: local_url,
      date: item.pubDate.strftime('%b %-d'),
      subtitle: item.description.to_s.gsub(/\s+/, ' ').strip
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
  # The RSS description is the Substack subtitle; the homepage sets it under each entry.
  safe_subtitle = item.description.to_s.gsub(/\s+/, ' ').strip.gsub('"', '\\"')

  frontmatter = <<~YAML
    ---
    layout: post
    title: "#{safe_title}"
    subtitle: "#{safe_subtitle}"
    date: #{datetime}
    canonical_url: #{item.link}
    source: substack
    ---
  YAML

  File.write(filepath, frontmatter + "\n" + content + "\n")
  puts "  new:  #{filename}"
  new_count += 1
end

rewrite_posts

File.write(DATA_FILE, JSON.pretty_generate(homepage_data))

# Write per-post stats keyed by slug (for use in post layout)
stats = {}
api_metadata.each do |slug, meta|
  stats[slug] = { comment_count: meta[:comment_count], reaction_count: meta[:reaction_count] }
end

# Top reader favourites for the configured year, by reaction count
favourites = api_metadata
  .select { |_slug, meta| meta[:post_date].to_s.start_with?(FAVOURITES_YEAR) }
  .sort_by { |_slug, meta| -meta[:reaction_count] }
  .first(FAVOURITES_LIMIT)
  .map { |slug, meta| { title: meta[:title], url: "/#{slug}/", reaction_count: meta[:reaction_count] } }

# Everything below is derived from the API sweep, and an empty hash means that sweep
# failed rather than that there's nothing to say — writing from it would blank every
# count on the site, empty the Best-of list and wipe every comment thread, and `just
# sync` would commit and push the result. On a failure the last good files stand.
if api_metadata.empty?
  warn 'Warning: no Substack API metadata — leaving stats, favourites and comments as they are'
  comment_threads = nil
else
  File.write(STATS_FILE, JSON.pretty_generate(stats))
  File.write(FAVOURITES_FILE, JSON.pretty_generate(favourites))
  comment_threads = fetch_comments(api_metadata)
end
File.write(COMMENTS_FILE, JSON.pretty_generate(comment_threads)) if comment_threads
comment_total = comment_threads.to_h.values.sum(&:length)

puts "Synced #{new_count} new posts, #{homepage_data.length} in homepage data, #{stats.length} post stats, " \
     "#{favourites.length} favourites, #{comment_total} comments on #{comment_threads.to_h.length} posts"
