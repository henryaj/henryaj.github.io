# Sync Substack posts and stats, commit and push
sync:
    ruby _scripts/fetch_substack.rb
    git add _posts/ _data/substack_stats.json
    git diff --staged --quiet || (git commit -m "Sync Substack posts and stats" && git push)
