# Blog / Personal Site

Jekyll 4.2 site deployed to GitHub Pages via GitHub Actions. Ruby 3.4.

## Local dev

```
bundle install
bundle exec jekyll serve
```

## Structure

- `index.html` — homepage, uses `layout: none` (self-contained HTML, no Jekyll templates)
- `_layouts/` — `default.html` and `post.html`; everything else is self-contained
- `_includes/` — shared fragments: `typography.html`, `favicons.html`, `analytics.html`,
  `meta.html` (description/OG/Twitter card), `post_stats.html` and the two stat icons
- `writing.html` — the full post index at `/writing/`, redirecting from `/archive/`
- `_posts/` — blog posts (permalink pattern: `/:title/`)
- `_drafts/` — unpublished drafts
- `_config.yml` — Jekyll config
- `images/` — static images
- `public/fonts/` — self-hosted woff2 subsets

Old blog posts are still live at their URLs but not linked from the homepage.

## Design

One type system, defined once in `_includes/typography.html` and included by both
`_layouts/default.html` and `index.html` — don't duplicate it into a third place.

- **Crimson Pro** — body copy, with oldstyle figures. The subsets are built from
  the upstream variable TTFs with `--layout-features+=onum` and the weight axis
  clipped to 400–800; Google's stock woff2 subsets strip `onum` entirely, so don't
  pull those. Replaced EB Garamond, which went thin and grey on a bright screen.
- **Frutiger 67 Bold Condensed** — headings, and the name on the homepage
- **Silkscreen** — nav, meta lines, section labels. Pixel bitmap, so integer px
  sizes only (8px grid — 11px and 13px visibly blur) and no subpixel tracking.
  Renders everything as capitals whatever case the source is in, which makes it
  fine for short labels and useless for prose.
- **Figtree** — links. Set at `--link-size` / `--link-weight` in the `--accent`
  vermilion with no underline; the change of face is what carries the link, so
  colour is never the only cue. Underline returns on hover. Subset from the
  upstream variable TTF with the axis clipped to 400–700 — the range has to run
  past the link weight or `<strong>` inside a link clamps instead of going bold.
  Replaced IBM Plex Sans, which was chosen to rhyme with Plex Mono below; that
  argument no longer holds, and Figtree's capitals run ~8% over Crimson Pro's
  cap height, which is a known and accepted trade.
  The italic is Figtree's own, subset the same way — links inside `_..._` are
  common enough in the archive (book and publication titles, mostly) that the
  browser's synthesised oblique was visible: shearing a geometric sans bulges the
  round letters at top-left and bottom-right and leaves the `g` leaning rather
  than curving. Not preloaded, unlike the roman: too rare to charge every visitor
  19KB for.
- **IBM Plex Mono** — code

The homepage and the post pages share a measure (`--measure`) and a gutter
(`--gutter-pull`): posts float sidenotes into the right margin, and the homepage
floats its offsite links into the same one. Below `--gutter-min` (70em) the margin
can't hold a float and both fall back inside the measure.

Each post closes with an asterism (U+2042). No text face the site has shipped
draws one — not Crimson Pro, not the old EB Garamond subsets, and not upstream
EB Garamond either — so for a long time the mark was left to whatever symbol font
the reader's platform supplied, and looked different on every one. It now comes
from a 620-byte single-glyph subset of Cardo (OFL, Bembo-derived, close enough to
Crimson Pro's contrast to pass), declared into the `Crimson Pro` family behind
`unicode-range: U+2042` so only post pages fetch it — with that codepoint cut out
of the two latin faces' ranges, so nothing else in the family claims it. The fleurons U+2766/7 still
have the original problem, in the unlikely event they come back — though upstream
EB Garamond does draw those, if it comes to it.

GoatCounter and Plausible analytics, both in `_includes/analytics.html`, included by
`index.html` and `_layouts/default.html`.

### Link favicons

Outbound links carry the destination's favicon, wired up by `_includes/favicons.html`
(included by both `index.html` and `_layouts/default.html`, same as `typography.html`).

The icons are **vendored locally** into `images/favicons/<host>.png` by
`_scripts/fetch_favicons.rb` (`just favicons`, and folded into `just sync`). An icon
service — Google's `s2/favicons`, DuckDuckGo's `ip3` — would need no build step at
all, but it also means a third-party request per outbound link on every page, which
is the one thing this site has consistently refused. The script scans `_posts/`,
`index.html`, `writing.html` and `404.html` for external hosts, pulls each icon from
DDG's aggregator (falling back to the host's own `/favicon.ico`), and normalises it
to a 32px PNG. Hosts already on disk are skipped, so re-running after new posts
reaches out for the new domains — plus a retry of every host that came back without
an icon last time, since a miss leaves nothing on disk to skip on.

Two things the script has to get right, both of which failed silently first time:

- **ImageMagick can't sniff ICO.** Its header (`00 00 01 00`) is too weak, so an
  `.ico` written to an extensionless temp file just fails to load — which is why the
  first run lost github.com, wikipedia and every other ICO host while the PNG hosts
  came through fine. The temp file's extension is the format hint, so it has to be
  derived from the blob's magic bytes.
- **Blank icons are worse than none.** They reserve space in the line and paint
  nothing, which reads as a typo. Rejected two ways: files under 400 bytes, and
  icons that come out white-on-white once flattened onto the page background.

Of ~340 linked hosts about 270 have an icon; the rest are dead domains and plain-HTML
pages from 2011 that never had one. Rather than ship a manifest of which do, each link
probes its own icon client-side and stays bare if it 404s — the browser dedupes the
request, and the `<img>` the probe loads is the same cache entry the `background-image`
then reuses. With JS off you get no icons and no gaps — the links are just links.

A link can name an icon other than its destination's with `data-favicon="<host>"`.
The homepage's "Pivotal" points at the Wikipedia article, which by default draws
Wikipedia's W — the destination, but not what the link is about. It carries
`data-favicon="pivotal.io"` instead. That file is the one hand-built icon in the
directory: Pivotal is dead, so the only mark left is a 16px `favicon.ico` in a 2020
Wayback capture, too small to upscale. It was rebuilt at 32px by cutting the P out of
the vector wordmark on Wikimedia Commons and setting it white on the teal sampled off
the original — same letterform, same colour, actually sharp. The fetch script skips
hosts already on disk, so it won't be overwritten.

Chrome won't run a text-decoration through an atomic inline, so the hover underline
stops dead at the mark and restarts at the first letter. The pseudo-element draws the
missing segment itself with a `border-bottom`, declared transparent and only coloured
in on hover so the box never resizes mid-interaction. That's also why the gaps either
side of the mark are padding rather than margin, and why the element is `content-box`
against the site's global `border-box`: the border has to span the gaps for the rule
to arrive as one unbroken line. The 0.05em of `padding-bottom` and the `calc()` in
`vertical-align` are what put that border exactly on `text-underline-offset` without
moving the mark.

Not decorated: the site nav and post meta lines (chrome, not prose), the "Reply on
Substack" link that closes a comment thread (it closes the apparatus rather than
sitting in it, and the mark only repeats what the words say), and the whole
homepage rail — chrome too, whatever its links point at. It's a set of handles for
the same person set in a bitmap face on a hard 8px grid, and a column of resampled
brand marks down its left edge fights that rather than annotating it. The project
cards are out for a different reason: only three of the eight destinations have an
icon, and a grid where some cells are indented and some aren't reads as broken rather
than as annotated.

### Building the body-face subsets

`public/fonts/crimsonpro-*.woff2` are built by hand from the upstream variable
TTFs (`google/fonts/ofl/crimsonpro`), not downloaded from the Google Fonts CSS
API — that API's files have `onum` stripped, which silently turns the whole site's
figures into lining ones.

```
pip install fonttools brotli
fonttools varLib.instancer "CrimsonPro[wght].ttf" wght=400:800 -o cp-400-800.ttf
pyftsubset cp-400-800.ttf --output-file=public/fonts/crimsonpro-latin.woff2 \
  --unicodes="<the latin range from typography.html>" \
  --layout-features+=onum --flavor=woff2 --no-hinting
```

Four files, so the pair of commands above runs twice over two source faces:
`CrimsonPro[wght].ttf` for the roman and `CrimsonPro-Italic[wght].ttf` for the
italic, each subset once to the latin range and once to latin-ext. The unicode
ranges are the ones declared in `_includes/typography.html`; keep the two in sync.
Only the latin files come out carrying `onum` — latin-ext holds no digits, so
pyftsubset drops the feature as unreachable. That's expected, not a failed build.

The link face is built the same way, from `google/fonts/ofl/figtree`, with the
axis clipped to 400–700 and no extra layout features — latin only, no latin-ext,
so it's one file per style rather than two:

```
fonttools varLib.instancer "Figtree-Italic[wght].ttf" wght=400:700 -o fig-it.ttf
pyftsubset fig-it.ttf --output-file=public/fonts/figtree-italic-latin.woff2 \
  --unicodes="<the range from typography.html>" --flavor=woff2 --no-hinting
```

## The dithered headshot

No longer used on the site — `images/headshot-dithered.png` is still in the repo but
nothing references it. If it comes back:

Source image: `~/Downloads/IMG_1507 (1).png`

```
magick <source> -resize 180x180 -brightness-contrast -20x20 -colorspace Gray -ordered-dither o4x4 images/headshot-dithered.png
```

Use `image-rendering: pixelated` in CSS and match the CSS display size to the source size (currently 180px) to avoid moiré.

## Substack sync

`just sync` runs `_scripts/fetch_substack.rb`, which pulls the RSS feed, writes any new
posts into `_posts/`, and regenerates `_data/substack.json` (the homepage's Writing
list), `substack_stats.json`, `reader_favourites.json` and `substack_comments.json`.
All of it is committed.

Run it locally only — Substack blocks the feed from GitHub Actions IPs, so in CI the
script silently fell through to its fallback branch, which rebuilds the index from post
front matter by regex. That divergence caused real bugs, so CI no longer runs it at all
and just builds what's in the repo.

Post front matter carries `subtitle:` (the Substack subtitle, taken from the RSS
`description`), which the homepage sets under each entry.

### Images and embeds

After writing new posts the script sweeps **every** Substack post, not just the new
ones, and rewrites two things in place:

- **Images** are downloaded into `images/substack/<slug>/<n>.<ext>` and the `src`
  repointed at the local copy, so no post depends on Substack's CDN staying up. It
  fetches the CDN URL rather than the S3 original it wraps — the originals include
  HEICs that most browsers won't render, and the CDN transcodes on the way out. The
  extension comes from the response `Content-Type`, not the URL. A failed fetch warns
  and leaves the remote URL, so the next run retries it.
- **Embeds** (`embedded-post-wrap`, `digest-post-embed`, `image-gallery-embed`,
  `twitter-embed`, `native-video-embed`) become plain markup — `.post-embed` cards,
  `figure.gallery`, `blockquote.tweet-embed` — styled in `_layouts/default.html`.
  Substack ships these as a div carrying a `data-attrs` JSON payload; the gallery and
  digest ones carry no rendered markup at all, so before this they were empty divs
  that showed nothing. An embedded post that is one of Henry's own links to the local
  copy rather than back to Substack.

Both passes are idempotent — a rewritten post has no embeds or remote URLs left to
find — but they are also **one-way**: the original `data-attrs` payload is consumed.
Changing the card markup means `git checkout _posts/`, clearing `images/substack/`,
and re-running, not just re-running.

### Comments

Substack's comments are synced in read-only and set below the asterism on each post —
there's no comment backend here, so the thread ends in a link back to the Substack
thread, which is the one place a reader can actually answer.

`GET /api/v1/post/<id>/comments?all_comments=true&sort=oldest_first` needs no token;
the post id comes from the same `/api/v1/posts` sweep the stats do. The whole file is
regenerated every sync rather than appended to, which is what makes an edited or
deleted comment upstream actually disappear here — but a post whose fetch *fails*
keeps whatever was synced last time, so a network blip can't quietly empty a thread.

An empty `/api/v1/posts` sweep means the API failed, not that there's nothing to say, so
`substack_stats.json`, `reader_favourites.json` and `substack_comments.json` are all
left alone in that case rather than regenerated from nothing — otherwise a blocked
request blanks every count on the site and `just sync` commits and pushes the result.
The feed and the API are separate requests, so the script can get past the RSS
fallback branch above with no metadata at all.

Two things the shape of the data forces:

- **The body comes from `body_json`, not `body`.** The plain text has lost the links.
  The ProseMirror document is walked node by node and every string escaped on the way
  out — this is text written by strangers, and none of it may reach the page as
  markup. Links are emitted `rel="nofollow ugc noopener"`, and an `href` that isn't
  plainly `http(s)` is dropped rather than sanitised. In practice the corpus is all
  paragraphs, text and links; the renderer also knows `strong`/`em`/`code`,
  blockquotes and hard breaks, and anything else degrades to its text.
- **Threads are flattened at fetch time.** They nest to four levels and Liquid can't
  recurse a template into itself, so the tree is written out in reading order with a
  `depth` on each comment (capped at 3) and the layout indents from that. A deleted
  comment is dropped but its replies are kept, pulled up to its depth rather than left
  indented under a parent that isn't there.

The count shown on a post and down the Writing index is the length of the synced
thread, not the API's `comment_count`: the two disagree as soon as a comment is
deleted, and a post that advertises three and then shows two reads as a bug.

**`_includes/post_stats.html` prefixes all of its locals `stat_`,** and `meta.html`
prefixes its `meta_`. A Liquid include shares the caller's scope, so a bare `comments`
in the include silently overwrote the post layout's variable of that name — and since
the clobbered value was an Integer, `.size` returned 8 (Ruby's byte width) instead of
the comment count. Any new include that assigns anything needs the same treatment.

## Meta tags

`_includes/meta.html` sets the description, Open Graph and Twitter card, and is
included by both `index.html` and `_layouts/default.html` — the same arrangement
`typography.html` and `favicons.html` use, for the same reason.

Description falls back from the post's `subtitle:` to its first `<p>`, and only then to
`site.description`. The middle step is doing most of the work: only 21 of the 151
posts carry a subtitle, so without it the other 130 would all ship one identical bio
as their description and card text. The first paragraph rather
than `page.excerpt` because a post that opens on a `<figure>` would otherwise be
described by its figure caption. Only posts get that fallback — a page's `page.content`
at this point is its own unrendered source, not converted HTML.

`og:url` is this site's URL for the page, not `page.canonical_url`: the canonical link
still points Substack-ward for syndicated posts, but a card should name where the
reader is about to land. The card image is the first `<img src>` under `/images/` in the
body, which the image sweep has already pulled into `images/substack/`. Every image is
tried, not just the first: a post can open on a remote image the sweep failed to vendor,
and the old first-only read dropped a card image the post did in fact have. Pages with
no local image declare a plain `summary` card rather than stretch the favicon into one.
The `/images/` test is what made the WordPress-era posts cardless until their images
were vendored too — see below.

## WordPress-era images

The eight posts that predate Substack hotlinked their images from
`henryaj.files.wordpress.com`. Those are vendored into `images/wordpress/` and the
markdown repointed at the local copy — same reasoning as the Substack sweep, one less
host the archive depends on. It was a one-off: nothing writes to that directory now,
and neither `_posts/` nor `_drafts/` references that host any more (its favicon went
with it).

Each file is named `<yyyy>-<mm>-<basename>` after its position in the old media
library, with the `-w<N>` suffix kept where the post asked for a resized variant — two
posts use the same photo at different widths, and the width is part of what the page
renders. Where a post linked the bare original the fetch asked WordPress for `?w=1456`,
the same cap the Substack sweep uses: it re-encodes on the way out, which took one
2047px phone photo from 392KB to 158KB and changed nothing at this measure. The one
PNG is the byte-for-byte original instead — WordPress's resizer quantises PNGs to a
256-colour palette on the way out, and for an 80KB screenshot that's a lossy round
trip bought for nothing.


## Deploy

Push to `master` triggers a GitHub Actions build (`.github/workflows/pages.yml`), which
just runs `jekyll build` — no fetching, no commits, read-only token.
Repo: `henryaj/henryaj.github.io`. Remote uses SSH: `git@github.com:henryaj/henryaj.github.io.git`.

## Hosting

Custom domain: `www.henrystanley.com` (CNAME file in repo root).

## Plugins

- `jekyll-redirect-from` — handles URL redirects for moved posts.
