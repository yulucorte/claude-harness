#!/usr/bin/env bash
set -e
trap 'echo "FAIL at line $LINENO"' ERR

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/session-heartbeat.sh"

REPO=$(mktemp -d)
git -C "$REPO" init -q
git -C "$REPO" config user.email "t@t.com"
git -C "$REPO" config user.name "t"
git -C "$REPO" commit --allow-empty -q -m init

mkdir -p "$REPO/.git/slate-sessions"
LOCK="$REPO/.git/slate-sessions/sess-hb.lock"
echo '{"branch": "main", "worktree": "", "started_at": "2020-01-01T00:00:00Z"}' > "$LOCK"
python3 -c "import os,time; t=time.time()-1000; os.utime('$LOCK',(t,t))"
OLD_MTIME=$(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK")

echo '{"session_id":"sess-hb"}' | CLAUDE_PROJECT_ROOT="$REPO" bash "$HOOK"
NEW_MTIME=$(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK")

[ "$NEW_MTIME" -gt "$OLD_MTIME" ] || { echo "FAIL: lock mtime not refreshed ($OLD_MTIME -> $NEW_MTIME)"; exit 1; }
echo "PASS: heartbeat refreshes lock mtime for an existing lock"

# --- Test: no lock file for this session -> no error, no file created ---
echo '{"session_id":"sess-none"}' | CLAUDE_PROJECT_ROOT="$REPO" bash "$HOOK"
[ -f "$REPO/.git/slate-sessions/sess-none.lock" ] && { echo "FAIL: heartbeat created a lock file it shouldn't have"; exit 1; }
echo "PASS: heartbeat is a no-op when this session has no lock"

# --- Test: heartbeat mirrors current branch + head into the lock ---
git -C "$REPO" checkout -qb mirror-branch
MHEAD=$(git -C "$REPO" rev-parse HEAD)
echo '{"branch": "stale", "worktree": "", "head": "deadbeef", "started_at": "2020-01-01T00:00:00Z"}' > "$REPO/.git/slate-sessions/sess-mir.lock"
printf '{"session_id":"sess-mir","cwd":"%s"}' "$REPO" | bash "$HOOK"
grep -q '"branch": "mirror-branch"' "$REPO/.git/slate-sessions/sess-mir.lock" \
  || { echo "FAIL: heartbeat did not mirror current branch. Content: $(cat "$REPO/.git/slate-sessions/sess-mir.lock")"; exit 1; }
grep -q "\"head\": \"$MHEAD\"" "$REPO/.git/slate-sessions/sess-mir.lock" \
  || { echo "FAIL: heartbeat did not mirror current head. Content: $(cat "$REPO/.git/slate-sessions/sess-mir.lock")"; exit 1; }
echo "PASS: heartbeat mirrors current branch and head into the lock"

# --- Test: a UserPromptSubmit-shaped payload (no tool_name/tool_input) still
#     refreshes mtime, branch, head and cwd, without erroring and without
#     touching 'files' -- NOT because heartbeat.sh never reads/writes that key
#     (it does, since the Task 4 file-tracking addition), but because THIS
#     payload carries no tool_name, so it never matches Write/Edit/NotebookEdit
#     and no file is ever considered "written". See
#     test-heartbeat-records-files.sh for the cases where a write tool IS
#     present and 'files' does change. ---
REAL=$(cd "$REPO" && pwd -P)
git -C "$REPO" checkout -qb prompt-branch
PHEAD=$(git -C "$REPO" rev-parse HEAD)
echo '{"branch": "stale", "worktree": "", "head": "deadbeef", "started_at": "2020-01-01T00:00:00Z"}' > "$REPO/.git/slate-sessions/sess-ups.lock"
python3 -c "import os,time; t=time.time()-1000; os.utime('$REPO/.git/slate-sessions/sess-ups.lock',(t,t))"
OLD_UPS_MTIME=$(stat -f %m "$REPO/.git/slate-sessions/sess-ups.lock" 2>/dev/null || stat -c %Y "$REPO/.git/slate-sessions/sess-ups.lock")

ERRFILE=$(mktemp)
python3 -c "import json,sys; print(json.dumps({'session_id':'sess-ups','cwd':sys.argv[1],'hook_event_name':'UserPromptSubmit','prompt':'hola'}))" "$REAL" \
  | bash "$HOOK" 2>"$ERRFILE"
[ -s "$ERRFILE" ] && { echo "FAIL: heartbeat raised an error on a UserPromptSubmit-shaped payload (no tool_name/tool_input): $(cat "$ERRFILE")"; rm -f "$ERRFILE"; exit 1; }
rm -f "$ERRFILE"

NEW_UPS_MTIME=$(stat -f %m "$REPO/.git/slate-sessions/sess-ups.lock" 2>/dev/null || stat -c %Y "$REPO/.git/slate-sessions/sess-ups.lock")
[ "$NEW_UPS_MTIME" -gt "$OLD_UPS_MTIME" ] || { echo "FAIL: heartbeat did not refresh mtime for a UserPromptSubmit-shaped payload"; exit 1; }
grep -q '"branch": "prompt-branch"' "$REPO/.git/slate-sessions/sess-ups.lock" \
  || { echo "FAIL: heartbeat did not mirror branch on a UserPromptSubmit-shaped payload. Content: $(cat "$REPO/.git/slate-sessions/sess-ups.lock")"; exit 1; }
grep -q "\"head\": \"$PHEAD\"" "$REPO/.git/slate-sessions/sess-ups.lock" \
  || { echo "FAIL: heartbeat did not mirror head on a UserPromptSubmit-shaped payload. Content: $(cat "$REPO/.git/slate-sessions/sess-ups.lock")"; exit 1; }
grep -q "\"cwd\": \"$REAL\"" "$REPO/.git/slate-sessions/sess-ups.lock" \
  || { echo "FAIL: heartbeat did not record cwd on a UserPromptSubmit-shaped payload. Content: $(cat "$REPO/.git/slate-sessions/sess-ups.lock")"; exit 1; }
grep -q '"files"' "$REPO/.git/slate-sessions/sess-ups.lock" \
  && { echo "FAIL: a payload with no tool_name must not record any file (it never matches Write/Edit/NotebookEdit, so the files-update block never runs)"; exit 1; }
echo "PASS: heartbeat handles a UserPromptSubmit-shaped payload (no tool_name/tool_input): refreshes mtime, branch, head and cwd, without touching 'files'"

rm -rf "$REPO"
echo ""
echo "All session-heartbeat tests passed."
