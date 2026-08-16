# Sync Substack posts and stats, commit and push
sync:
    ruby _scripts/fetch_substack.rb
    git add _posts/ images/substack/ _data/substack.json _data/substack_stats.json _data/reader_favourites.json
    git diff --staged --quiet || (git commit -m "Sync Substack posts and stats" && git push)
