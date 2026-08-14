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
list), `substack_stats.json` and `reader_favourites.json`. All of it is committed.

Run it locally only — Substack blocks the feed from GitHub Actions IPs, so in CI the
script silently fell through to its fallback branch, which rebuilds the index from post
front matter by regex. That divergence caused real bugs, so CI no longer runs it at all
and just builds what's in the repo.

Post front matter carries `subtitle:` (the Substack subtitle, taken from the RSS
`description`), which the homepage sets under each entry.

## Deploy

Push to `master` triggers a GitHub Actions build (`.github/workflows/pages.yml`), which
just runs `jekyll build` — no fetching, no commits, read-only token.
Repo: `henryaj/henryaj.github.io`. Remote uses SSH: `git@github.com:henryaj/henryaj.github.io.git`.

## Hosting

Custom domain: `www.henrystanley.com` (CNAME file in repo root).

## Plugins

- `jekyll-redirect-from` — handles URL redirects for moved posts.
