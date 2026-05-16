#!/bin/bash
# Run daily by cron. Syncs Substack posts via `claude -p` and shows a macOS notification.

BLOG_DIR="/Users/henryaj/workspace/blog"
LOG="/tmp/substack-sync.log"

export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

cd "$BLOG_DIR" || {
  osascript -e 'display notification "could not cd to blog" with title "Substack sync" sound name "Basso"'
  exit 1
}

PROMPT="Run 'just sync' in this repo to sync Substack posts and push any changes. When finished, print EXACTLY ONE final line of the form 'OK: <short summary>' on success or 'ERROR: <reason>' on failure. No other trailing output."

{
  echo "=== $(date) ==="
  OUTPUT=$(claude -p "$PROMPT" --permission-mode bypassPermissions 2>&1)
  STATUS=$?
  echo "$OUTPUT"
  echo "exit=$STATUS"
} >> "$LOG" 2>&1

SUMMARY=$(printf '%s\n' "$OUTPUT" | grep -E '^(OK|ERROR):' | tail -n 1 | tr -d '"')
[ -z "$SUMMARY" ] && SUMMARY="(no summary — see $LOG)"

if [ $STATUS -eq 0 ] && [[ "$SUMMARY" == OK:* ]]; then
  osascript -e "display notification \"${SUMMARY#OK: }\" with title \"Substack sync\""
else
  osascript -e "display notification \"$SUMMARY\" with title \"Substack sync\" subtitle \"Failed\" sound name \"Basso\""
  exit 1
fi
