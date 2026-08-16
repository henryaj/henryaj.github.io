#!/usr/bin/env ruby
# Vendors a favicon for every external host the site links to, so link icons
# don't depend on a third-party icon service (and don't leak a request per link
# to one either). Idempotent: hosts already on disk are skipped, so re-running
# after new posts fetches the new domains — plus a retry of every host that had no
# icon last time, since a miss leaves nothing on disk to skip on.
require 'net/http'
require 'uri'
require 'fileutils'
require 'set'
require 'tmpdir'
require 'shellwords'

REPO_ROOT    = File.expand_path('..', __dir__)
FAVICONS_DIR = File.join(REPO_ROOT, 'images', 'favicons')
SOURCES      = Dir[File.join(REPO_ROOT, '_posts', '*.md')] +
               %w[index.html archive.html 404.html].map { |f| File.join(REPO_ROOT, f) }
# Own hosts get no icon — the point of the mark is "this leaves the site".
OWN_HOSTS  = %w[henrystanley.com henryaj.github.io localhost].freeze
USER_AGENT = 'Mozilla/5.0 (compatible; JekyllBuild/1.0)'
SIZE       = 32
THREADS    = 10

def normalise(host)
  host.downcase.sub(/\A(www|m|en-gb)\./, '').sub(/:\d+\z/, '')
end

def hosts
  found = Set.new
  SOURCES.each do |path|
    next unless File.exist?(path)
    File.read(path).scan(%r{https?://([a-z0-9.\-]+\.[a-z]{2,}(?::\d+)?)}i) do |(host)|
      h = normalise(host)
      next if OWN_HOSTS.any? { |own| h == own || h.end_with?(".#{own}") }
      found << h
    end
  end
  found.to_a.sort
end

def http_fetch(url, depth = 0)
  return nil if depth > 4
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == 'https'
  http.open_timeout = 6
  http.read_timeout = 10
  req = Net::HTTP::Get.new(uri)
  req['User-Agent'] = USER_AGENT
  res = http.request(req)
  # Location is allowed to be relative, and a bare URI() of one has no host — which
  # blows up inside Net::HTTP and gets swallowed by the rescue below, losing the icon.
  return http_fetch(URI.join(url, res['location']).to_s, depth + 1) if res.is_a?(Net::HTTPRedirection) && res['location']
  res.is_a?(Net::HTTPSuccess) ? res.body : nil
rescue StandardError
  nil
end

# DuckDuckGo's icon service aggregates what a crawler would have to do itself —
# /favicon.ico, the <link rel="icon"> in <head>, apple-touch-icon — and normalises
# the result. Falling back to the host's own /favicon.ico covers what it misses.
def fetch_icon(host)
  http_fetch("https://icons.duckduckgo.com/ip3/#{host}.ico") ||
    http_fetch("https://#{host}/favicon.ico")
end

# ImageMagick sniffs most formats from the blob, but not ICO — its header
# (00 00 01 00) is too weak to detect, so an .ico written to a extensionless
# temp file just fails to load. The extension is the hint, so it has to be right.
def extension_for(blob)
  case blob.byteslice(0, 4)
  when "\x89PNG".b then '.png'
  when "\x00\x00\x01\x00".b then '.ico'
  when "GIF8".b then '.gif'
  else
    return '.jpg' if blob.byteslice(0, 3) == "\xFF\xD8\xFF".b
    return '.svg' if blob[0, 300].to_s.include?('<svg')
    '.png'
  end
end

def write_png(host, blob)
  # DDG serves a 1x1 transparent placeholder for hosts it has nothing for.
  return false if blob.nil? || blob.bytesize < 100

  src = File.join(Dir.tmpdir, "favicon-#{host.gsub(/[^a-z0-9]/, '_')}#{extension_for(blob)}")
  File.binwrite(src, blob)
  out = File.join(FAVICONS_DIR, "#{host}.png")
  # [0] takes the first frame — .ico files are multi-resolution containers, and
  # without it ImageMagick writes one png per frame.
  # The resize has no `>`: plenty of hosts still serve a 16px icon, and shrink-only
  # leaves those at half size in the middle of a 32px canvas, which reads as a
  # different, smaller mark rather than as the same mark one host along. Upscaling
  # 16 to 32 is soft on a 2x screen, but one size for every host beats two.
  ok = system('magick', "#{src}[0]", '-background', 'none',
              '-resize', "#{SIZE}x#{SIZE}", '-gravity', 'center',
              '-extent', "#{SIZE}x#{SIZE}", out,
              out: File::NULL, err: File::NULL)
  File.delete(src) if File.exist?(src)
  # A blank result is worse than no icon: it reserves space in the line and paints
  # nothing, which reads as a typo rather than as an absent mark. Two ways to be
  # blank — a near-empty file, and a full-size icon that is white on white once its
  # transparency is flattened onto the page's own background.
  if ok && File.exist?(out) && (File.size(out) < 400 || blank_on_white?(out))
    File.delete(out)
    ok = false
  end
  ok && File.exist?(out)
end

def blank_on_white?(path)
  mean = `magick #{path.shellescape} -background white -alpha remove -alpha off -colorspace Gray -format "%[fx:mean]" info: 2>/dev/null`.to_f
  mean >= 0.995
end

# Without ImageMagick every host "fails" and the run reports a clean zero, which
# reads as an archive with no icons rather than as a machine missing a dependency.
unless system('magick', '-version', out: File::NULL, err: File::NULL)
  abort 'fetch_favicons: ImageMagick (`magick`) not found on PATH — install it first.'
end

FileUtils.mkdir_p(FAVICONS_DIR)

all = hosts
todo = all.reject { |h| File.exist?(File.join(FAVICONS_DIR, "#{h}.png")) }
puts "#{all.size} external hosts linked, #{todo.size} without an icon on disk"

got = Queue.new
missed = Queue.new
queue = Queue.new
todo.each { |h| queue << h }

workers = Array.new(THREADS) do
  Thread.new do
    while (host = (queue.pop(true) rescue nil))
      if write_png(host, fetch_icon(host))
        got << host
        print '.'
      else
        missed << host
        print 'x'
      end
    end
  end
end
workers.each(&:join)
puts

puts "fetched #{got.size}, no icon for #{missed.size}"
puts "missing: #{Array.new(missed.size) { missed.pop }.sort.join(', ')}" unless missed.empty?
