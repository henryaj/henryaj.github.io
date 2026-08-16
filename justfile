# Sync Substack posts and stats, vendor any new favicons, commit and push
sync:
    ruby _scripts/fetch_substack.rb
    ruby _scripts/fetch_favicons.rb
    git add _posts/ images/substack/ images/favicons/ _data/substack.json _data/substack_stats.json _data/reader_favourites.json
    git diff --staged --quiet || (git commit -m "Sync Substack posts and stats" && git push)

# Vendor favicons for outbound links. Idempotent: only fetches hosts not on disk
favicons:
    ruby _scripts/fetch_favicons.rb
