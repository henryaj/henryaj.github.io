# Blog / Personal Site

Jekyll 4.2 site deployed to GitHub Pages via GitHub Actions. Ruby 3.4.

## Local dev

```
bundle install
bundle exec jekyll serve
```

## Structure

- `index.html` — homepage, uses `layout: none` (self-contained HTML, no Jekyll templates)
- `_layouts/` — `default.html`, `post.html`, `page.html` (used by blog posts and pages like `/now`)
- `_posts/` — blog posts (permalink pattern: `/:title/`)
- `_drafts/` — unpublished drafts
- `_config.yml` — Jekyll config
- `images/` — static images
- `public/fonts/` — self-hosted woff2 subsets

Old blog posts are still live at their URLs but not linked from the homepage.

Dead weight, left in place but wired to nothing: `_includes/head.html`, `sidebar.html`
and `author.html`, `_layouts/page.html`, and everything in `public/css/` (the old
Lanyon theme). No layout includes `head.html`, so none of that CSS is ever loaded.

## Design

One type system, defined once in `_includes/typography.html` and included by both
`_layouts/default.html` and `index.html` — don't duplicate it into a third place.

- **EB Garamond** — body copy, with oldstyle figures. The subsets are built with
  `--layout-features+=onum`; Google's stock woff2 subsets strip it.
- **Frutiger 67 Bold Condensed** — headings, and the name on the homepage
- **Silkscreen** — nav, meta lines, section labels. Pixel bitmap, so integer px
  sizes only (8px grid — 11px and 13px visibly blur) and no subpixel tracking.
  Renders everything as capitals whatever case the source is in, which makes it
  fine for short labels and useless for prose.
- **IBM Plex Sans** — links. Set at `--link-size` in the `--accent` sapphire with
  no underline; the change of face is what carries the link, so colour is never
  the only cue. Underline returns on hover.
- **IBM Plex Mono** — code

The homepage and the post pages share a measure (`--measure`) and a gutter
(`--gutter-pull`): posts float sidenotes into the right margin, and the homepage
floats its offsite links into the same one. Below `--gutter-min` (70em) the margin
can't hold a float and both fall back inside the measure.

Each post closes with an asterism (U+2042). It's one of the few ornaments EB
Garamond actually draws — the fleurons U+2766/7 fall back to a system symbol font
and render differently per platform.

GoatCounter analytics on both the homepage and the post layout.

## The dithered headshot

No longer used on the site — `images/headshot-dithered.png` is still in the repo but
nothing references it. If it comes back:

Source image: `~/Downloads/IMG_1507 (1).png`

```
magick <source> -resize 180x180 -brightness-contrast -20x20 -colorspace Gray -ordered-dither o4x4 images/headshot-dithered.png
```

Use `image-rendering: pixelated` in CSS and match the CSS display size to the source size (currently 180px) to avoid moiré.

## Deploy

Push to `master` triggers a GitHub Actions build (`.github/workflows/pages.yml`), which
runs `_scripts/fetch_substack.rb` before `jekyll build` — `_data/substack.json` is
gitignored and regenerated from the RSS feed on every deploy, so anything the homepage
reads out of it has to be written by that script, not just committed locally.
Repo: `henryaj/henryaj.github.io`. Remote uses SSH: `git@github.com:henryaj/henryaj.github.io.git`.

## Hosting

Custom domain: `www.henrystanley.com` (CNAME file in repo root).

## Plugins

- `jekyll-redirect-from` — handles URL redirects for moved posts.
