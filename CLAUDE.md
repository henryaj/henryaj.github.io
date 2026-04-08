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
- `public/` — CSS/static assets for the blog layout (Lanyon theme)

Old blog posts are still live at their URLs but not linked from the homepage.

## Design

Minimal "tilde page" aesthetic — plain monospace HTML, no frameworks, no layout system.
Dithered e-ink style headshot (ordered dither, o4x4 pattern via ImageMagick).

Blog posts use the Lanyon theme (`_layouts/default.html`) with Google Analytics (UA) and a nav bar.
The homepage uses GoatCounter analytics instead.

## Dithering the headshot

Source image: `~/Downloads/IMG_1507 (1).png`

```
magick <source> -resize 180x180 -brightness-contrast -20x20 -colorspace Gray -ordered-dither o4x4 images/headshot-dithered.png
```

Use `image-rendering: pixelated` in CSS and match the CSS display size to the source size (currently 180px) to avoid moiré.

## Deploy

Push to `master` triggers GitHub Actions build (`.github/workflows/jekyll-gh-pages.yml`).
Repo: `henryaj/henryaj.github.io`. Remote uses SSH: `git@github.com:henryaj/henryaj.github.io.git`.

## Hosting

Custom domain: `www.henrystanley.com` (CNAME file in repo root).

## Plugins

- `jekyll-redirect-from` — handles URL redirects for moved posts.
