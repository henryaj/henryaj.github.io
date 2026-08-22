#!/usr/bin/env ruby
# Cuts a 224x32 preview sliver from the image a post opens on, for the homepage's
# Writing list. Idempotent: a thumbnail already on disk, newer than its source and
# cut to the current target size is left alone, so re-running after a sync only cuts
# the new posts.
#
# The crop is the whole point, and 7:1 is a hard ratio to crop to. Almost
# every post opens on a painting in portrait format, so the sliver keeps a few
# percent of the frame. libvips' `attention` (saliency) is used over `entropy` (texture) and
# `centre`: `centre` loses the wanderer's head in the Friedrich outright, and while
# `entropy` is close at this ratio — it actually frames the carcass in Rembrandt's
# Slaughtered Ox, which `attention` misses — saliency degrades more gracefully on the
# screenshots and charts that also open posts. All three were cut and looked at; see
# CLAUDE.md for what each one did.
require 'json'
require 'set'
require 'yaml'
require 'fileutils'
require 'shellwords'
require 'tmpdir'

REPO_ROOT     = File.expand_path('..', __dir__)
POSTS_DIR     = File.join(REPO_ROOT, '_posts')
PREVIEWS_DIR  = File.join(REPO_ROOT, 'images', 'previews')
DATA_FILE     = File.join(REPO_ROOT, '_data', 'previews.json')
# The homepage list, written by fetch_substack.rb. Only those posts get a thumbnail:
# cutting all 50 that qualify would commit ten times the bytes to serve five of them.
SOURCE_LIST   = File.join(REPO_ROOT, '_data', 'substack.json')
# `pinned_post:` in _config.yml swaps the fifth most recent entry for a fixed one, so
# the script has to read the same switch the homepage does or it cuts a thumbnail for
# a post that is no longer on show and none for the one that is.
CONFIG_FILE   = File.join(REPO_ROOT, '_config.yml')

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
DISPLAY_H   = 32
# 2x for retina, but never upscaled past the source (see target_size).
MAX_W       = DISPLAY_W * 2

def split_post(path)
  text = File.read(path)
  # Front matter is the first two `---` fences; everything after is the body.
  parts = text.split(/^---\s*$/, 3)
  parts.length == 3 ? [parts[1], parts[2]] : ['', text]
end

# `preview_crop:` in a post's front matter overrides the saliency crop with a fixed
# vertical position, given as a fraction of the image's height: 0.5 takes the band
# from halfway down, 0 from the top edge, 1 from the bottom. It's there for the
# openers `attention` gets wrong — Rembrandt's Slaughtered Ox is dark enough that
# saliency picks the pale timber arch over the carcass, and no strategy libvips ships
# gets it at this ratio. Horizontal position is left to the crop, which is where it
# matters least: these are portrait sources, so the width is barely cropped at all.
# A `preview_crop:` that doesn't parse is a typo, not a request for the saliency
# crop — say so, or the post silently keeps the thumbnail the override was added to
# replace and the value looks like it did nothing.
# `preview_image:` in a post's front matter names the source outright, for a post
# whose title art isn't at the top — the pinned post's only image is 10,819 characters
# in, well past LEAD_WINDOW, so without this it draws the empty slot. It bypasses only
# the lead-window test: the path still has to be local, on disk and wide enough, since
# those are about whether a usable sliver can be cut at all.
def override_image(front_matter, slug)
  line = front_matter[/^preview_image:.*$/]
  return nil if line.nil?
  value = line[/^preview_image:\s*["']?([^"'\s#]+)["']?\s*(?:#.*)?$/, 1]
  if value.nil?
    warn "  ! #{slug}: ignoring unparseable `#{line.strip}` (want a path under /images/)"
    return nil
  end
  # Same local-only rule `lead_image` applies: a remote URL has nothing to cut from,
  # and anything else would be joined onto REPO_ROOT and read from outside `images/`.
  unless value.start_with?('/images/')
    warn "  ! #{slug}: ignoring preview_image #{value} (want a path under /images/)"
    return nil
  end
  value
end

def crop_fraction(front_matter, slug)
  line = front_matter[/^preview_crop:.*$/]
  return nil if line.nil?
  value = line[/^preview_crop:\s*([0-9.]+)\s*(?:#.*)?$/, 1]
  if value.nil?
    warn "  ! #{slug}: ignoring unparseable `#{line.strip}` (want a number between 0 and 1)"
    return nil
  end
  value.to_f.clamp(0.0, 1.0)
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
# scaled up vertically to cover the crop.
def target_size(source_width, source_height)
  w = [MAX_W, source_width, (source_height * DISPLAY_W.to_f / DISPLAY_H).floor].min
  [w, (w * DISPLAY_H.to_f / DISPLAY_W).round]
end

def vips(*args)
  system('vips', *args.map(&:to_s), out: File::NULL, err: File::NULL)
end

def cut(source, dest, width, height)
  vips('thumbnail', source, dest, width, "--height=#{height}", '--crop=attention')
end

# Scale to the target width, then take the band at the requested fraction. Two steps
# rather than one because `vips thumbnail --crop` only offers its own strategies, and
# none of them is "here". The scaled height is read back off the intermediate rather
# than trusted from the arithmetic: thumbnail rounds, and an off-by-one there would
# put `top` past the bottom of the image and fail the crop.
def cut_at(source, dest, width, height, fraction)
  Dir.mktmpdir do |dir|
    scaled = File.join(dir, 'scaled.v')
    return false unless vips('thumbnail', source, scaled, width, '--height=100000')
    scaled_height = dimensions(scaled)&.last
    return false if scaled_height.nil?
    # A source wider than the target ratio scales to a band shorter than the one we
    # need, so there is nothing to take a slice out of. Only reachable for a source
    # wider than the strip's own 7:1, which no painting is — but a banner or a
    # wide screenshot can be, and the ratio has widened once already, so this is not
    # a branch to assume away. Fall back to the saliency crop rather than emit no
    # thumbnail at all, and say which one lost its override.
    if scaled_height < height
      warn "  ! #{File.basename(dest, '.webp')} is wider than the strip; ignoring preview_crop"
      return cut(source, dest, width, height)
    end
    top = ((scaled_height * fraction) - (height / 2.0)).round.clamp(0, scaled_height - height)
    vips('crop', scaled, dest, 0, top, width, height)
  end
end

# An empty list means the sync failed, not that there is nothing to show — the same
# reasoning as the stats guard in fetch_substack.rb. Regenerating from nothing would
# delete every thumbnail, and `just sync` would commit the result.
listed = File.exist?(SOURCE_LIST) ? JSON.parse(File.read(SOURCE_LIST)) : []
if listed.empty?
  warn "#{File.basename(SOURCE_LIST)} is missing or empty — leaving thumbnails alone"
  exit 0
end
slugs = listed.map { |post| post['url'].to_s.delete('/') }

# YAML.safe_load rather than a regex: _config.yml is a real config file and the value
# is quoted. `aliases: true` because the config uses YAML anchors and Psych refuses
# them by default — without it every read raises and the pin silently never applies,
# which is a failure with no symptom other than the wrong post having a thumbnail.
# A genuinely unreadable config still leaves the pin off rather than raising.
pinned = begin
  YAML.safe_load(File.read(CONFIG_FILE), aliases: true)['pinned_post'].to_s.delete('/')
rescue StandardError => e
  warn "  ! couldn't read pinned_post from _config.yml (#{e.class}), assuming no pin"
  ''
end

# Four recent plus the pin, matching index.html — which drops the pin out of the
# recent list before taking four of them, so a pin that is also one of the most recent
# is moved to the foot of the list rather than listed twice. Subtract it here for the
# same reason: otherwise the fifth-most-recent post is on show with no thumbnail.
wanted = (pinned.empty? ? slugs : (slugs - [pinned]).first(4) + [pinned]).to_set

FileUtils.mkdir_p(PREVIEWS_DIR)
FileUtils.mkdir_p(File.dirname(DATA_FILE))

previews = {}
skipped = 0

# Both extensions Jekyll accepts: the archive has one `.markdown` post left from 2016.
Dir[File.join(POSTS_DIR, '*.{md,markdown}')].sort.each do |post|
  # `2026-07-26-cached-identities.md` -> `cached-identities`, matching the permalink.
  slug = File.basename(post).sub(/\.(md|markdown)\z/, '').sub(/\A\d{4}-\d{2}-\d{2}-/, '')
  next unless wanted.include?(slug)

  front_matter, body = split_post(post)
  override = override_image(front_matter, slug)
  src = override || lead_image(body)
  next skipped += 1 if src.nil?

  source = File.join(REPO_ROOT, src.sub(%r{\A/}, ''))
  unless File.exist?(source)
    # Silence is fine for a lead image the sweep never vendored, but an explicit
    # `preview_image:` pointing at nothing is a typo the author wants told about —
    # otherwise the post draws the empty slot and the override looks like it worked.
    warn "  ! #{slug}: preview_image #{src} is not on disk" if override
    next skipped += 1
  end

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
  # fetch_substack.rb rewrites post bodies in place and can change the opener — and so
  # is one older than the post, which is what makes adding or changing a
  # `preview_crop:` take effect. So is one that isn't the size we'd cut now: mtime
  # alone can't see a change to the target rectangle, so changing the constants above
  # would otherwise leave every existing file at the old size while the JSON
  # advertised the new one.
  newest_input = [File.mtime(source), File.mtime(post)].max
  on_disk = File.exist?(dest) ? dimensions(dest) : nil
  if on_disk.nil? || File.mtime(dest) < newest_input || on_disk != [width, height]
    fraction = crop_fraction(front_matter, slug)
    cut_ok = fraction ? cut_at(source, dest, width, height, fraction) : cut(source, dest, width, height)
    if cut_ok
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
