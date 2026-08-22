#!/usr/bin/env ruby
# Cuts a 224x28 preview sliver from the image a post opens on, for the homepage's
# Writing list. Idempotent: a thumbnail already on disk, newer than its source and
# cut to the current target size is left alone, so re-running after a sync only cuts
# the new posts.
#
# The crop is the whole point, and 8:1 is a hard ratio to crop to. Almost every post
# opens on a painting in portrait format, so the sliver keeps a few percent of the
# frame. libvips' `attention` (saliency) is used over `entropy` (texture) and
# `centre`: `centre` loses the wanderer's head in the Friedrich outright, and while
# `entropy` is close at this ratio — it actually frames the carcass in Rembrandt's
# Slaughtered Ox, which `attention` misses — saliency degrades more gracefully on the
# screenshots and charts that also open posts. All three were cut and looked at; see
# CLAUDE.md for what each one did.
require 'json'
require 'set'
require 'fileutils'
require 'shellwords'

REPO_ROOT     = File.expand_path('..', __dir__)
POSTS_DIR     = File.join(REPO_ROOT, '_posts')
PREVIEWS_DIR  = File.join(REPO_ROOT, 'images', 'previews')
DATA_FILE     = File.join(REPO_ROOT, '_data', 'previews.json')
# The homepage list, written by fetch_substack.rb. Only those posts get a thumbnail:
# cutting all 50 that qualify would commit ten times the bytes to serve five of them.
SOURCE_LIST   = File.join(REPO_ROOT, '_data', 'substack.json')

# How far into the body an image still counts as the one the post opens on. Posts
# that lead with a figure put it at character ~13; the next-earliest image in the
# corpus is 1063 characters in, which is illustration rather than title art.
LEAD_WINDOW = 400
# Never invent pixels: a source narrower than the drawn width is being upscaled
# rather than merely under-dense. The lead-window test above is what separates title
# art from an inline illustration; this one only rejects sources too small to fill the
# rectangle honestly.
MIN_WIDTH   = 224
# The thumbnail as the homepage draws it.
DISPLAY_W   = 224
DISPLAY_H   = 28
# 2x for retina, but never upscaled past the source (see target_size).
MAX_W       = DISPLAY_W * 2

def body_of(path)
  text = File.read(path)
  # Front matter is the first two `---` fences; everything after is the body.
  parts = text.split(/^---\s*$/, 3)
  parts.length == 3 ? parts[2] : text
end

# The earliest image in the body, whether it was written as HTML or as markdown.
# Substack posts are all <img>; the eight WordPress-era ones use ![](), and a
# handful of posts mix the two, so both have to be scanned and the earlier taken.
def lead_image(body)
  candidates = []
  body.scan(%r{<img[^>]+src="([^"]+)"}i) { candidates << [Regexp.last_match.begin(0), $1] }
  body.scan(/!\[[^\]]*\]\(([^)\s]+)/) { candidates << [Regexp.last_match.begin(0), $1] }
  offset, src = candidates.min_by(&:first)
  return nil if src.nil? || offset > LEAD_WINDOW
  # Only local images: a post that still hotlinks its opener has nothing to cut from.
  return nil unless src.start_with?('/images/')
  src
end

def dimensions(path)
  w = `vipsheader -f width #{Shellwords.escape(path)} 2>/dev/null`.to_i
  h = `vipsheader -f height #{Shellwords.escape(path)} 2>/dev/null`.to_i
  w.positive? && h.positive? ? [w, h] : nil
end

# Fill the target rectangle at up to 2x, but never invent pixels: a small source
# yields a smaller strip of the same proportion rather than an upscaled one. The
# ratio has to be held on both axes or the strip stops being the same shape as its
# neighbours, which is why the height is derived rather than fixed — and why the
# source's *height* bounds the width too. MIN_WIDTH only guards the horizontal, so a
# wide, short source (a banner, a screenshot strip) clears it and would then be
# scaled up vertically to cover the 8:1 crop.
def target_size(source_width, source_height)
  w = [MAX_W, source_width, (source_height * DISPLAY_W.to_f / DISPLAY_H).floor].min
  [w, (w * DISPLAY_H.to_f / DISPLAY_W).round]
end

def cut(source, dest, width, height)
  system('vips', 'thumbnail', source, dest, width.to_s,
         "--height=#{height}", '--crop=attention',
         out: File::NULL, err: File::NULL)
end

# An empty list means the sync failed, not that there is nothing to show — the same
# reasoning as the stats guard in fetch_substack.rb. Regenerating from nothing would
# delete every thumbnail, and `just sync` would commit the result.
listed = File.exist?(SOURCE_LIST) ? JSON.parse(File.read(SOURCE_LIST)) : []
if listed.empty?
  warn "#{File.basename(SOURCE_LIST)} is missing or empty — leaving thumbnails alone"
  exit 0
end
wanted = listed.map { |post| post['url'].to_s.delete('/') }.to_set

FileUtils.mkdir_p(PREVIEWS_DIR)
FileUtils.mkdir_p(File.dirname(DATA_FILE))

previews = {}
skipped = 0

# Both extensions Jekyll accepts: the archive has one `.markdown` post left from 2016.
Dir[File.join(POSTS_DIR, '*.{md,markdown}')].sort.each do |post|
  # `2026-07-26-cached-identities.md` -> `cached-identities`, matching the permalink.
  slug = File.basename(post).sub(/\.(md|markdown)\z/, '').sub(/\A\d{4}-\d{2}-\d{2}-/, '')
  next unless wanted.include?(slug)

  src = lead_image(body_of(post))
  next skipped += 1 if src.nil?

  source = File.join(REPO_ROOT, src.sub(%r{\A/}, ''))
  next skipped += 1 unless File.exist?(source)

  dest = File.join(PREVIEWS_DIR, "#{slug}.webp")

  dims = dimensions(source)
  if dims.nil?
    # Failing to read the source is a tooling failure, not a post that stopped
    # qualifying — so keep referencing whatever is already on disk, for the same
    # reason the failed-re-cut branch below does: dropping the entry would hand the
    # file to the orphan sweep, and one vips hiccup would delete a good thumbnail.
    if (on_disk = File.exist?(dest) ? dimensions(dest) : nil)
      warn "  ! couldn't read #{src}, keeping the thumbnail already on disk"
      previews[slug] = { 'src' => "/images/previews/#{slug}.webp",
                         'width' => on_disk[0], 'height' => on_disk[1] }
    end
    next skipped += 1
  end
  next skipped += 1 if dims[0] < MIN_WIDTH

  width, height = target_size(dims[0], dims[1])

  # A thumbnail older than the image it was cut from is stale — the sweep in
  # fetch_substack.rb rewrites post bodies in place and can change the opener. So is
  # one that isn't the size we'd cut now: mtime alone can't see a change to the
  # target rectangle, so changing the constants above would otherwise leave every
  # existing file at the old size while the JSON advertised the new one.
  on_disk = File.exist?(dest) ? dimensions(dest) : nil
  if on_disk.nil? || File.mtime(dest) < File.mtime(source) || on_disk != [width, height]
    if cut(source, dest, width, height)
      puts "  + #{slug} (#{width}x#{height})"
    elsif File.exist?(dest)
      # A re-cut that fails leaves the previous thumbnail on disk. Keep referencing it:
      # dropping the entry here would hand the file to the orphan sweep below, so
      # one transient vips failure would delete a thumbnail that was perfectly good.
      warn "  ! failed to re-cut #{slug}, keeping the thumbnail already on disk"
    else
      warn "  ! failed to cut #{slug}"
      next skipped += 1
    end
  end

  # The file on disk is the authority on its own size. A thumbnail left alone was cut
  # under whatever the constants were at the time, and width/height attributes that
  # disagree with it cause exactly the layout shift they're there to prevent.
  width, height = dimensions(dest) || [width, height]

  previews[slug] = { 'src' => "/images/previews/#{slug}.webp", 'width' => width, 'height' => height }
end

existing = Dir[File.join(PREVIEWS_DIR, '*.webp')]

# Nothing qualifying while thumbnails sit on disk means the tooling failed, not that
# the archive changed: without libvips on PATH every post falls out at the dimensions
# check, silently and with a zero exit. The sweep below would then delete every
# thumbnail and the write blank the JSON — which `just sync` commits and pushes
# unattended. Same guard, same reasoning, as the empty-API-sweep one in
# fetch_substack.rb.
if previews.empty? && existing.any?
  # Loud, but a zero exit: this runs mid-`just sync`, and aborting here would take
  # the `git add`/commit down with it, leaving the posts and images the fetch just
  # pulled uncommitted. Leaving the thumbnails and the JSON untouched is the whole
  # point of the guard; the exit code isn't part of it. Same as the empty-list guard.
  warn "build_previews: #{existing.size} thumbnails on disk but no post produced one — " \
       'is libvips installed? Leaving the thumbnails and the JSON alone.'
  exit 0
end

# Thumbnails whose post no longer qualifies would otherwise sit on disk forever, and
# the JSON is regenerated whole, so nothing would reference them.
(existing - previews.keys.map { |s| File.join(PREVIEWS_DIR, "#{s}.webp") })
  .each do |orphan|
    puts "  - #{File.basename(orphan)} (no longer a lead image)"
    File.delete(orphan)
  end

File.write(DATA_FILE, JSON.pretty_generate(previews.sort.to_h) + "\n")
puts "#{previews.size} preview thumbnails, #{skipped} posts with no lead image"
