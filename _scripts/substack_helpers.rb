require 'net/http'
require 'json'
require 'uri'

module SubstackHelpers
  USER_AGENT = 'Mozilla/5.0 (compatible; JekyllBuild/1.0)'
  API_URL    = 'https://henryaj.substack.com/api/v1/posts'

  module_function

  def http_get(url)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Get.new(uri)
    req['User-Agent'] = USER_AGENT
    req['Accept'] = '*/*'
    response = http.request(req)
    return http_get(response['location']) if response.is_a?(Net::HTTPRedirection)
    response.body
  end

  def fetch_all_api_posts
    posts = []
    page_size = 50
    offset = 0
    loop do
      body = http_get("#{API_URL}?limit=#{page_size}&offset=#{offset}")
      page = JSON.parse(body)
      break if page.empty?
      posts.concat(page)
      break if page.length < page_size
      offset += page_size
    end
    posts
  end

  def slug_from_url(url)
    url.split('/p/').last.split('?').first
  end

  def clean_html(html)
    html = html.gsub(/<div class="image-link-expand">.*?<\/div>\s*<\/div>\s*<\/div>/m, '')

    html = html.gsub(/<div class="captioned-image-container"><figure>(.*?)<\/figure><\/div>/m) do
      inner = $1
      src = inner[/src="(https:\/\/substackcdn\.com[^"]+)"/, 1] || inner[/src="([^"]+)"/, 1]
      alt = inner[/alt="([^"]*)"/, 1] || ''
      caption = inner[/<figcaption[^>]*>(.*?)<\/figcaption>/m, 1]

      fig = "<figure>"
      fig += %(\n  <img src="#{src}" alt="#{alt}" loading="lazy">) if src
      fig += %(\n  <figcaption>#{caption}</figcaption>) if caption
      fig += "\n</figure>"
      fig
    end

    html = html.gsub(/<img [^>]*data-attrs[^>]*>/) do |img|
      src = img[/src="([^"]+)"/, 1]
      alt = img[/alt="([^"]*)"/, 1] || ''
      %(<img src="#{src}" alt="#{alt}" loading="lazy">)
    end

    footnotes = {}
    html.scan(/<div class="footnote"[^>]*>\s*<a [^>]*class="footnote-number"[^>]*>(\d+)<\/a>\s*<div class="footnote-content">(.*?)<\/div>\s*<\/div>/m) do
      footnotes[$1] = $2.strip
    end

    html = html.gsub(/<div class="footnote"[^>]*>\s*<a [^>]*class="footnote-number"[^>]*>\d+<\/a>\s*<div class="footnote-content">.*?<\/div>\s*<\/div>/m, '')

    html = html.gsub(/<a class="footnote-anchor"[^>]*id="([^"]*)"[^>]*href="([^"]*)"[^>]*>(\d+)<\/a>/) do
      _id, _href, num = $1, $2, $3
      content = (footnotes[num] || '').gsub(/<\/?p>/, ' ').gsub(/<br\s*\/?>/, ' ').strip
      %(<span class="sidenote-wrapper"><a href="#fn-#{num}" class="sidenote-toggle"><sup>#{num}</sup></a><span class="sidenote"><strong>#{num}.</strong> #{content}</span></span>)
    end

    html = html.gsub(/ data-component-name="[^"]*"/, '')
    html = html.gsub(/<div class="pencraft[^"]*"[^>]*>.*?<\/div>/m, '')
    html = html.gsub(/<button[^>]*>.*?<\/button>/m, '')

    html = html.gsub(/<div>\s*<\/div>/, '')
    html = html.gsub(/\n{3,}/, "\n\n")

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

  def write_post(post, posts_dir)
    require 'time'
    pub = Time.parse(post['post_date']).utc
    date = pub.strftime('%Y-%m-%d')
    datetime = pub.strftime('%Y-%m-%d %H:%M:%S +0000')
    slug = post['slug']
    filename = "#{date}-#{slug}.md"
    filepath = File.join(posts_dir, filename)

    safe_title = post['title'].to_s.gsub('"', '\\"')
    canonical = post['canonical_url'] || "https://henryaj.substack.com/p/#{slug}"
    body = clean_html(post['body_html'].to_s)

    frontmatter = <<~YAML
      ---
      layout: post
      title: "#{safe_title}"
      date: #{datetime}
      canonical_url: #{canonical}
      source: substack
      ---
    YAML

    File.write(filepath, frontmatter + "\n" + body + "\n")
    filename
  end
end
