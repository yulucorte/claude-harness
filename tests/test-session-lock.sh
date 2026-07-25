#!/usr/bin/env bash
set -e
trap 'echo "FAIL at line $LINENO"' ERR

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/session-lock.sh"

setup_repo() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q
  git -C "$dir" config user.email "t@t.com"
  git -C "$dir" config user.name "t"
  git -C "$dir" commit --allow-empty -q -m init
  echo "$dir"
}

# --- Test: no existing locks -> claims current branch, no additionalContext ---
REPO=$(setup_repo)
OUTPUT=$(echo '{"session_id":"sess-aaa"}' | CLAUDE_PROJECT_ROOT="$REPO" bash "$HOOK")
LOCK_FILE="$REPO/.git/slate-sessions/sess-aaa.lock"

[ -f "$LOCK_FILE" ] || { echo "FAIL: lock file not created. Got output: $OUTPUT"; exit 1; }
grep -q '"branch": "master"' "$LOCK_FILE" 2>/dev/null || grep -q '"branch": "main"' "$LOCK_FILE" \
  || { echo "FAIL: lock does not record current branch. Content: $(cat "$LOCK_FILE")"; exit 1; }
LHEAD=$(git -C "$REPO" rev-parse HEAD)
grep -q "\"head\": \"$LHEAD\"" "$LOCK_FILE" \
  || { echo "FAIL: lock does not record the current head tip. Content: $(cat "$LOCK_FILE")"; exit 1; }
if printf '%s' "$OUTPUT" | grep -q additionalContext; then
  echo "FAIL: unexpected additionalContext on no-collision path: $OUTPUT"; exit 1
fi
echo "PASS: no-collision claim produced no additionalContext"
echo "PASS: lock file created with current branch"
rm -rf "$REPO"

# --- Test: existing lock on a DIFFERENT branch -> no collision, own claim proceeds ---
REPO=$(setup_repo)
BR=$(git -C "$REPO" branch --show-current)
git -C "$REPO" checkout -qb other-branch
git -C "$REPO" checkout -q "$BR"
mkdir -p "$REPO/.git/slate-sessions"
cat > "$REPO/.git/slate-sessions/sess-other.lock" <<EOF
{"branch": "other-branch", "worktree": "", "started_at": "2026-01-01T00:00:00Z"}
EOF

OUTPUT2=$(echo '{"session_id":"sess-bbb"}' | CLAUDE_PROJECT_ROOT="$REPO" bash "$HOOK")
[ -f "$REPO/.git/slate-sessions/sess-bbb.lock" ] || { echo "FAIL: own lock not created despite different-branch lock present"; exit 1; }
grep -q "\"branch\": \"$BR\"" "$REPO/.git/slate-sessions/sess-bbb.lock" \
  || { echo "FAIL: claimed wrong branch. Content: $(cat "$REPO/.git/slate-sessions/sess-bbb.lock")"; exit 1; }
echo "PASS: different-branch lock does not trigger collision"
rm -rf "$REPO"

# --- Test: existing SAME-branch lock but STALE (mtime > 900s old) -> ignored ---
REPO=$(setup_repo)
BR=$(git -C "$REPO" branch --show-current)
mkdir -p "$REPO/.git/slate-sessions"
cat > "$REPO/.git/slate-sessions/sess-stale.lock" <<EOF
{"branch": "$BR", "worktree": "", "started_at": "2020-01-01T00:00:00Z"}
EOF
python3 -c "import os,time; p='$REPO/.git/slate-sessions/sess-stale.lock'; t=time.time()-1000; os.utime(p,(t,t))"

OUTPUT3=$(echo '{"session_id":"sess-fresh"}' | CLAUDE_PROJECT_ROOT="$REPO" bash "$HOOK")
echo "$OUTPUT3" | grep -q additionalContext && { echo "FAIL: stale lock triggered isolation. Output: $OUTPUT3"; exit 1; }
[ -f "$REPO/.git/slate-sessions/sess-fresh.lock" ] || { echo "FAIL: own lock not created"; exit 1; }
[ -d "$REPO.slate-worktrees" ] && { echo "FAIL: worktree created despite stale lock"; exit 1; }
echo "PASS: stale lock (>900s) is ignored, no isolation triggered"
rm -rf "$REPO" "$REPO.slate-worktrees" 2>/dev/null

# --- Test: existing SAME-branch FRESH lock -> colision real, avisa SIN crear worktree ---
REPO=$(setup_repo)
BR=$(git -C "$REPO" branch --show-current)
mkdir -p "$REPO/.git/slate-sessions"
cat > "$REPO/.git/slate-sessions/sess-live.lock" <<EOF
{"branch": "$BR", "worktree": "", "started_at": "2026-01-01T00:00:00Z"}
EOF

OUTPUT4=$(echo '{"session_id":"sess-colliding"}' | CLAUDE_PROJECT_ROOT="$REPO" bash "$HOOK")
echo "$OUTPUT4" | grep -q additionalContext || { echo "FAIL: no additionalContext on real collision. Output: $OUTPUT4"; exit 1; }
echo "$OUTPUT4" | grep -q "checkout" || { echo "FAIL: el aviso de colision no nombra la operacion peligrosa. Output: $OUTPUT4"; exit 1; }

REPO_PARENT="$(dirname "$REPO")"
REPO_BASE="$(basename "$REPO")"
[ -d "${REPO_PARENT}/${REPO_BASE}.slate-worktrees" ] && { echo "FAIL: se creo un worktree; el aislamiento automatico fue eliminado"; exit 1; }

LOCK_FILE="$REPO/.git/slate-sessions/sess-colliding.lock"
grep -q "slate-session/" "$LOCK_FILE" && { echo "FAIL: el lock registra una rama slate-session/* inventada"; exit 1; }
echo "PASS: real branch collision warns without creating a worktree"

rm -rf "$REPO" 2>/dev/null

echo ""
echo "All session-lock tests passed."
