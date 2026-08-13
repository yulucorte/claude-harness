#!/usr/bin/env bash
# scripts/reserve-id.sh atomically reserves a FEAT-NNN/BUG-NNN candidate ID so
# two sessions on different (unmerged) branches computing the same "grep max +
# 1" can't both claim the same number. Uses mkdir's atomicity (fails if the
# target dir already exists) under .git's common dir, shared by every branch
# and worktree of the same repo -- NOT a worktree's own private .git file.
set -e
trap 'echo "FAIL at line $LINENO"; rm -rf "$REPO" "$WT" 2>/dev/null || true' ERR

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/reserve-id.sh"

setup_repo() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q
  git -C "$dir" config user.email "t@t.com"
  git -C "$dir" config user.name "t"
  git -C "$dir" commit --allow-empty -q -m init
  echo "$dir"
}

# --- 1. reserving a fresh ID succeeds ---
REPO=$(setup_repo)
( cd "$REPO" && bash "$SCRIPT" FEAT-144 )
RC=$?
[ "$RC" -eq 0 ] || { echo "FAIL: reserving a fresh ID exited $RC, expected 0"; exit 1; }
[ -d "$REPO/.git/slate-ids/FEAT/144" ] || { echo "FAIL: no reservation dir created for FEAT-144"; exit 1; }
echo "PASS: reserving a fresh ID succeeds (exit 0) and creates a marker under .git/slate-ids"

# --- 2. reserving the SAME ID again fails, with a stderr explanation ---
ERRFILE=$(mktemp)
set +e
( cd "$REPO" && bash "$SCRIPT" FEAT-144 ) 2>"$ERRFILE"
RC=$?
set -e
[ "$RC" -ne 0 ] || { echo "FAIL: reserving an already-reserved ID exited 0"; rm -f "$ERRFILE"; exit 1; }
[ -s "$ERRFILE" ] || { echo "FAIL: reserving an already-reserved ID produced no explanation on stderr"; rm -f "$ERRFILE"; exit 1; }
grep -qi "reserv" "$ERRFILE" || { echo "FAIL: stderr does not explain the ID is already reserved: $(cat "$ERRFILE")"; rm -f "$ERRFILE"; exit 1; }
rm -f "$ERRFILE"
echo "PASS: reserving an already-reserved ID fails with a non-zero exit and a stderr explanation"
rm -rf "$REPO"

# --- 3. FEAT-042 and BUG-042 don't collide (independent numbering, same as
#     the bug/feature ID spaces are independent per skills/tracking-bugs) ---
REPO=$(setup_repo)
( cd "$REPO" && bash "$SCRIPT" FEAT-042 )
( cd "$REPO" && bash "$SCRIPT" BUG-042 )
[ -d "$REPO/.git/slate-ids/FEAT/042" ] || { echo "FAIL: FEAT-042 reservation missing"; exit 1; }
[ -d "$REPO/.git/slate-ids/BUG/042" ] || { echo "FAIL: BUG-042 reservation missing"; exit 1; }
echo "PASS: FEAT-042 and BUG-042 reserve independently (no cross-prefix collision)"
rm -rf "$REPO"

# --- 4. missing argument -> non-zero exit, no crash ---
REPO=$(setup_repo)
set +e
( cd "$REPO" && bash "$SCRIPT" ) 2>/dev/null
RC=$?
set -e
[ "$RC" -ne 0 ] || { echo "FAIL: no argument should exit non-zero"; exit 1; }
echo "PASS: missing argument exits non-zero"
rm -rf "$REPO"

# --- 5. malformed ID (no PREFIX-NUMBER shape) -> non-zero exit, no crash ---
REPO=$(setup_repo)
set +e
( cd "$REPO" && bash "$SCRIPT" garbage ) 2>/dev/null
RC=$?
set -e
[ "$RC" -ne 0 ] || { echo "FAIL: a malformed ID should exit non-zero"; exit 1; }
echo "PASS: a malformed ID exits non-zero instead of crashing or silently reserving"
rm -rf "$REPO"

# --- 6. not a git repo -> non-zero exit, no crash ---
NOGIT=$(mktemp -d)
set +e
( cd "$NOGIT" && bash "$SCRIPT" FEAT-001 ) 2>/dev/null
RC=$?
set -e
[ "$RC" -ne 0 ] || { echo "FAIL: running outside a git repo should exit non-zero"; exit 1; }
[ -e "$NOGIT/.git" ] && { echo "FAIL: a .git dir should not have appeared outside a repo"; exit 1; }
echo "PASS: running outside a git repo exits non-zero without side effects"
rm -rf "$NOGIT"

# --- 7. reservation made from a LINKED WORKTREE is visible from the main
#     worktree (and vice versa) -- this is the entire point of the feature:
#     two branches / worktrees of the SAME repo must not both win the same ID. ---
REPO=$(setup_repo)
git -C "$REPO" worktree add -q -b wt-branch "$REPO-wt" >/dev/null
WT="$REPO-wt"

( cd "$WT" && bash "$SCRIPT" FEAT-777 )
RC=$?
[ "$RC" -eq 0 ] || { echo "FAIL: reserving from a linked worktree failed (exit $RC)"; exit 1; }

set +e
( cd "$REPO" && bash "$SCRIPT" FEAT-777 ) 2>/dev/null
RC=$?
set -e
[ "$RC" -ne 0 ] || { echo "FAIL: an ID reserved from a linked worktree was reservable again from the main worktree — reservations are not shared via git-common-dir"; exit 1; }
echo "PASS: a reservation made from a linked worktree blocks the same ID in the main worktree (shared via git-common-dir)"
rm -rf "$REPO" "$WT"

echo ""
echo "All reserve-id tests passed."
