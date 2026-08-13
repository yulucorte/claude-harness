#!/usr/bin/env bash
# docs/slate/progress/.gitattributes (history.md merge=union) must reach
# projects that were already installed before this line existed, not just
# fresh installs. install-into-project.sh only runs once, at install time,
# and never touches a project again — an established project (almost any
# mature repo already has SOME .gitattributes) would never receive this line
# through the installer alone. Same class of bug as codebase-map.md
# regenerating in already-installed projects (see CHANGELOG 1.8.0). This is
# delivered from session-start.sh instead, which runs on every session and
# does reach projects that installed slate long ago.
set -e
trap 'echo "FAIL at line $LINENO"; rm -rf "$TMPDIR_PROJECT" "$TMPDIR_PROJECT2" "$TMPDIR_PROJECT3" "$TMPDIR_PROJECT4" 2>/dev/null || true' ERR

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/session-start.sh"
LINE="history.md merge=union"
DST_REL="docs/slate/progress/.gitattributes"

setup_project() {
  local dir="$1"
  mkdir -p "$dir/docs/slate/progress" "$dir/docs/slate/features"
  touch "$dir/docs/slate/progress/current.md" "$dir/docs/slate/progress/history.md" "$dir/docs/slate/features/in-progress.md"
}

# --- Test 1: already-installed project (no .gitattributes yet) -> hook creates it ---
TMPDIR_PROJECT=$(mktemp -d)
setup_project "$TMPDIR_PROJECT"
[ ! -e "$TMPDIR_PROJECT/$DST_REL" ] || { echo "FAIL: test setup — .gitattributes should not exist yet"; exit 1; }

echo '{"source":"startup"}' | CLAUDE_PROJECT_ROOT="$TMPDIR_PROJECT" bash "$HOOK" > /dev/null

grep -qxF "$LINE" "$TMPDIR_PROJECT/$DST_REL" 2>/dev/null \
  || { echo "FAIL: session-start.sh did not create $DST_REL with the union-merge line for an already-installed project"; exit 1; }
echo "PASS: session-start.sh delivers the union-merge line to an already-installed project"
rm -rf "$TMPDIR_PROJECT"

# --- Test 2: project has its own .gitattributes without the line -> line appended, content kept ---
TMPDIR_PROJECT2=$(mktemp -d)
setup_project "$TMPDIR_PROJECT2"
printf '*.png binary\n' > "$TMPDIR_PROJECT2/$DST_REL"

echo '{"source":"startup"}' | CLAUDE_PROJECT_ROOT="$TMPDIR_PROJECT2" bash "$HOOK" > /dev/null

grep -qxF '*.png binary' "$TMPDIR_PROJECT2/$DST_REL" || { echo "FAIL: pre-existing .gitattributes content was lost"; exit 1; }
grep -qxF "$LINE" "$TMPDIR_PROJECT2/$DST_REL" || { echo "FAIL: union-merge line was not appended to an existing .gitattributes"; exit 1; }
echo "PASS: existing .gitattributes content preserved, union-merge line appended"
rm -rf "$TMPDIR_PROJECT2"

# --- Test 3: project already has the line -> repeated sessions don't duplicate it ---
TMPDIR_PROJECT3=$(mktemp -d)
setup_project "$TMPDIR_PROJECT3"
printf '%s\n' "$LINE" > "$TMPDIR_PROJECT3/$DST_REL"

echo '{"source":"startup"}' | CLAUDE_PROJECT_ROOT="$TMPDIR_PROJECT3" bash "$HOOK" > /dev/null
echo '{"source":"startup"}' | CLAUDE_PROJECT_ROOT="$TMPDIR_PROJECT3" bash "$HOOK" > /dev/null

COUNT=$(grep -cxF "$LINE" "$TMPDIR_PROJECT3/$DST_REL")
[ "$COUNT" -eq 1 ] || { echo "FAIL: union-merge line duplicated across sessions (count=$COUNT)"; exit 1; }
echo "PASS: repeated sessions do not duplicate an already-present union-merge line"
rm -rf "$TMPDIR_PROJECT3"

# --- Test 4: project not initialized with slate -> hook exits early, no .gitattributes created ---
TMPDIR_PROJECT4=$(mktemp -d)
echo '{"source":"startup"}' | CLAUDE_PROJECT_ROOT="$TMPDIR_PROJECT4" bash "$HOOK" > /dev/null
[ -e "$TMPDIR_PROJECT4/$DST_REL" ] && { echo "FAIL: .gitattributes created in a project without slate installed"; exit 1; }
echo "PASS: a project without slate installed is left untouched"
rm -rf "$TMPDIR_PROJECT4"

echo ""
echo "All session-start .gitattributes delivery tests passed."
