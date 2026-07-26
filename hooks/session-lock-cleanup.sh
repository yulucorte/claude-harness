#!/usr/bin/env bash
# SessionEnd hook: session-lock guardian, cleanup.
# Removes ONLY this session's lock file, releasing its branch claim. Never
# touches any worktree or branch it may have created — those stay on disk
# for manual review/merge/delete, by explicit product decision.
set -uo pipefail

PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-$(pwd)}"
cd "$PROJECT_ROOT" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null)"
[ -z "$GIT_COMMON_DIR" ] && exit 0
case "$GIT_COMMON_DIR" in
  /*) : ;;
  *) GIT_COMMON_DIR="$PROJECT_ROOT/$GIT_COMMON_DIR" ;;
esac
GIT_COMMON_DIR="$(cd "$GIT_COMMON_DIR" 2>/dev/null && pwd -P)"
[ -z "$GIT_COMMON_DIR" ] && exit 0

STDIN_JSON=""
if [ ! -t 0 ]; then
  STDIN_JSON=$(cat 2>/dev/null || true)
fi
SESSION_ID=$(printf '%s' "$STDIN_JSON" | python3 -c "import sys,json
try:
    print((json.load(sys.stdin).get('session_id') or '').strip())
except Exception:
    print('')" 2>/dev/null || true)
[ -z "$SESSION_ID" ] && exit 0

LOCK_DIR="$GIT_COMMON_DIR/slate-sessions"
rm -f "$LOCK_DIR/$SESSION_ID.lock" 2>/dev/null || true

# Reap locks left behind by sessions that never reached SessionEnd (crash, window
# closed, kill). Nothing removed them before: cleanup only ever deleted its own
# lock and the TTL merely made readers ignore the rest, so slate-sessions/ grew
# forever. Measured: 13 dead locks in one project, the oldest 6 days old, and a
# 51-minute-old ghost still announcing itself as "another active session".
# TTL here must match session-guardian.sh / session-lock.sh (900s).
find "$LOCK_DIR" -maxdepth 1 -name '*.lock' -type f -mmin +15 -delete 2>/dev/null || true
exit 0
