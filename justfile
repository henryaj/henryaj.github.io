# Sync Substack posts and stats, vendor any new favicons, commit and push
sync:
    ruby _scripts/fetch_substack.rb
    ruby _scripts/fetch_favicons.rb
    ruby _scripts/build_previews.rb
    git add _posts/ images/substack/ images/favicons/ images/previews/ _data/substack.json _data/substack_stats.json _data/reader_favourites.json _data/substack_comments.json _data/previews.json
    git diff --staged --quiet || (git commit -m "Sync Substack posts and stats" && git push)

# Vendor favicons for outbound links. Idempotent: only fetches hosts not on disk
favicons:
    ruby _scripts/fetch_favicons.rb

# Cut the homepage Writing list's preview thumbnails. Idempotent: only re-cuts one
# whose source image is newer than it, or which is not the size the script now cuts to
previews:
    ruby _scripts/build_previews.rb
