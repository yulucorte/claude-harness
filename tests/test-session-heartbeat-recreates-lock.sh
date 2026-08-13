#!/usr/bin/env bash
# session-heartbeat.sh must RECREATE this session's lock when it is missing,
# instead of silently doing nothing.
#
# Real failure mode reproduced: session-lock.sh (SessionStart) and
# session-lock-cleanup.sh (SessionEnd) both run
# `find slate-sessions -mmin +15 -delete` to reap dead locks. A session that
# is genuinely alive but has not called any tool in >15 minutes (thinking,
# waiting on the user, one long-running tool) has its OWN lock reaped by a
# PEER session merely starting or ending. Before this fix, the next heartbeat
# for that live session saw no lock file and did nothing
# (`if not os.path.isfile(lock): sys.exit(0)`), so the session stayed
# invisible to session-guardian.sh forever — a peer could then
# checkout/reset/stash on top of it with no deny and no warn.
set -e
trap 'echo "FAIL at line $LINENO"; rm -rf "$REPO" 2>/dev/null || true' ERR

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/session-heartbeat.sh"

setup_repo() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q
  git -C "$dir" config user.email "t@t.com"
  git -C "$dir" config user.name "t"
  git -C "$dir" commit --allow-empty -q -m init
  echo "$dir"
}

# --- 1. missing lock (never existed / reaped) -> heartbeat recreates it ---
REPO=$(setup_repo)
git -C "$REPO" checkout -qb reaped-branch
HEAD=$(git -C "$REPO" rev-parse HEAD)
LOCK="$REPO/.git/slate-sessions/sess-reaped.lock"
[ ! -e "$LOCK" ] || { echo "FAIL: test setup — lock should not exist yet"; exit 1; }

printf '{"session_id":"sess-reaped","cwd":"%s"}' "$REPO" | bash "$HOOK"

[ -f "$LOCK" ] || { echo "FAIL: heartbeat did not recreate a missing lock"; exit 1; }
echo "PASS: heartbeat recreates this session's lock when it is missing"

grep -q "\"branch\": \"reaped-branch\"" "$LOCK" || { echo "FAIL: recreated lock has wrong/missing branch. Content: $(cat "$LOCK")"; exit 1; }
grep -q "\"head\": \"$HEAD\"" "$LOCK" || { echo "FAIL: recreated lock has wrong/missing head. Content: $(cat "$LOCK")"; exit 1; }
echo "PASS: recreated lock carries the correct branch and head"

REAL=$(cd "$REPO" && pwd -P)
grep -q "\"cwd\": \"$REAL\"" "$LOCK" || { echo "FAIL: recreated lock has wrong/missing cwd. Content: $(cat "$LOCK")"; exit 1; }
echo "PASS: recreated lock carries the physical cwd"
rm -rf "$REPO"

# --- 2. the recreated lock makes the session visible to session-guardian.sh ---
# This is the actual bug: without recreation, session-guardian never sees a
# lock for a session whose lock was reaped, so a peer's tree-op sails through
# with no deny and no warn.
REPO=$(setup_repo)
GUARDIAN="$PLUGIN_ROOT/hooks/session-guardian.sh"
REAL=$(cd "$REPO" && pwd -P)

printf '{"session_id":"sess-live","cwd":"%s"}' "$REAL" | bash "$HOOK"
[ -f "$REAL/.git/slate-sessions/sess-live.lock" ] || { echo "FAIL: setup — heartbeat should have recreated sess-live's lock"; exit 1; }

PAYLOAD=$(python3 -c "import json,sys; print(json.dumps({'session_id': 'sess-peer', 'cwd': sys.argv[1], 'tool_name': 'Bash', 'tool_input': {'command': 'git checkout otra'}}))" "$REAL")
OUT=$(printf '%s' "$PAYLOAD" | bash "$GUARDIAN")
echo "$OUT" | grep -q '"permissionDecision": "deny"' \
  || { echo "FAIL: a peer's tree-op was not denied even though the reaped session's lock was recreated by its heartbeat. Output: $OUT"; exit 1; }
echo "PASS: a session whose lock was recreated by heartbeat is visible to session-guardian.sh (deny works again)"
rm -rf "$REPO"

# --- 3. a write-tool payload with no prior lock -> recreated lock records the file ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
PAYLOAD=$(python3 -c "import json,sys; print(json.dumps({'session_id': 'sess-write', 'cwd': sys.argv[1], 'tool_name': 'Write', 'tool_input': {'file_path': sys.argv[1] + '/a.txt'}}))" "$REAL")
printf '%s' "$PAYLOAD" | bash "$HOOK"
LOCK="$REAL/.git/slate-sessions/sess-write.lock"
[ -f "$LOCK" ] || { echo "FAIL: heartbeat did not recreate the lock for a write-tool payload"; exit 1; }
python3 -c "
import json
d = json.load(open('$LOCK'))
paths = [e.get('path') for e in d.get('files', [])]
assert '$REAL/a.txt' in paths, 'a.txt not recorded in recreated lock: %r' % paths
"
echo "PASS: a write-tool payload with no prior lock is recorded in the recreated lock's 'files'"
rm -rf "$REPO"

# --- 4. no git repo -> still a clean no-op, no lock created anywhere ---
REPO=$(mktemp -d)
printf '{"session_id":"sess-nogit","cwd":"%s"}' "$REPO" | bash "$HOOK"
[ -e "$REPO/.git" ] && { echo "FAIL: a .git dir should not have appeared in a non-git directory"; exit 1; }
echo "PASS: a non-git cwd stays a clean no-op (no lock, no error)"
rm -rf "$REPO"

echo ""
echo "All session-heartbeat lock-recreation tests passed."
