# Blog / Personal Site

Jekyll site deployed to GitHub Pages via GitHub Actions.

## Design

Minimal "tilde page" aesthetic — plain monospace HTML, no frameworks, no layout system.
Dithered e-ink style headshot (ordered dither, o4x4 pattern via ImageMagick).

The homepage (`index.html`) uses `layout: none` — it's self-contained HTML, no Jekyll templates.

Old blog posts are still live at their URLs but not linked from the homepage.

## Dithering the headshot

Source image: `~/Downloads/IMG_1507 (1).png`

```
magick <source> -resize 180x180 -brightness-contrast -20x20 -colorspace Gray -ordered-dither o4x4 images/headshot-dithered.png
```

Use `image-rendering: pixelated` in CSS and match the CSS display size to the source size (currently 180px) to avoid moiré.

## Deploy

Push to `master` triggers GitHub Actions build. Repo: `henryaj/henryaj.github.io`.
Remote uses SSH: `git@github.com:henryaj/henryaj.github.io.git`.

## Hosting

Custom domain: `www.henrystanley.com` (CNAME file in repo root).
