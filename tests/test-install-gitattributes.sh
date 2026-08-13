#!/usr/bin/env bash
# docs/slate/progress/.gitattributes must mark history.md as merge=union so
# concurrent append-only writes from different branches don't produce a
# conflict marker every time two sessions both appended a session block
# (measured: 17 merge conflicts on a live project's history.md before this).
#
# Never silently overwrites a user's own .gitattributes in that folder: if one
# already exists, the union-merge line is appended only when missing.
set -e
trap 'echo "FAIL at line $LINENO"; rm -rf "$TMPDIR_PROJECT" "$TMPDIR_PROJECT2" "$TMPDIR_PROJECT3" 2>/dev/null || true' ERR

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$PLUGIN_ROOT/scripts/install-into-project.sh"
LINE="history.md merge=union"
DST="docs/slate/progress/.gitattributes"

# --- Test 1: fresh install -> .gitattributes created with the union-merge line ---
TMPDIR_PROJECT=$(mktemp -d)
CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$INSTALLER" "$TMPDIR_PROJECT" > /dev/null

[ -f "$TMPDIR_PROJECT/$DST" ] || { echo "FAIL: $DST not created on fresh install"; exit 1; }
grep -qxF "$LINE" "$TMPDIR_PROJECT/$DST" || { echo "FAIL: $DST missing '$LINE' on fresh install"; exit 1; }
echo "PASS: fresh install creates $DST with the union-merge line"
rm -rf "$TMPDIR_PROJECT"

# --- Test 2: project already has its own .gitattributes without the line -> line is appended, existing content kept ---
TMPDIR_PROJECT2=$(mktemp -d)
mkdir -p "$TMPDIR_PROJECT2/docs/slate/progress"
printf '*.png binary\n' > "$TMPDIR_PROJECT2/$DST"
CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$INSTALLER" "$TMPDIR_PROJECT2" > /dev/null

grep -qxF '*.png binary' "$TMPDIR_PROJECT2/$DST" || { echo "FAIL: pre-existing .gitattributes content was lost"; exit 1; }
grep -qxF "$LINE" "$TMPDIR_PROJECT2/$DST" || { echo "FAIL: union-merge line was not appended to an existing .gitattributes"; exit 1; }
echo "PASS: existing .gitattributes content preserved, union-merge line appended"
rm -rf "$TMPDIR_PROJECT2"

# --- Test 3: project already has the line -> running install again does not duplicate it ---
TMPDIR_PROJECT3=$(mktemp -d)
mkdir -p "$TMPDIR_PROJECT3/docs/slate/progress"
printf '%s\n' "$LINE" > "$TMPDIR_PROJECT3/$DST"
CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$INSTALLER" "$TMPDIR_PROJECT3" > /dev/null

COUNT=$(grep -cxF "$LINE" "$TMPDIR_PROJECT3/$DST")
[ "$COUNT" -eq 1 ] || { echo "FAIL: union-merge line duplicated (count=$COUNT)"; exit 1; }
echo "PASS: re-running install does not duplicate an already-present union-merge line"

# Running it a second time (simulating an update on an existing installation) must stay idempotent too.
CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$INSTALLER" "$TMPDIR_PROJECT3" > /dev/null
COUNT2=$(grep -cxF "$LINE" "$TMPDIR_PROJECT3/$DST")
[ "$COUNT2" -eq 1 ] || { echo "FAIL: union-merge line duplicated on a second update run (count=$COUNT2)"; exit 1; }
echo "PASS: idempotent across repeated update runs"
rm -rf "$TMPDIR_PROJECT3"

echo ""
echo "All install .gitattributes tests passed."
