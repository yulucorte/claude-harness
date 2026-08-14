#!/usr/bin/env bash
# session-start.sh should surface two visible lines at startup:
#  - the active plugin version (read from .claude-plugin/plugin.json), so a
#    stale-cache install is obvious instead of silent.
#  - a warning line when docs/slate/progress/history.md exceeds the
#    documented rotation limit (docs/archiving.md: 40 entries), so a project
#    that never rotated (measured on a live project: 774/40 blocks) is visible
#    instead of silently growing forever.
set -e
trap 'echo "FAIL at line $LINENO"; rm -rf "$TMPDIR_PROJECT" "$TMPDIR_PLUGIN" "$TMPDIR_PROJECT2" "$TMPDIR_PROJECT3" 2>/dev/null || true' ERR

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/session-start.sh"

# Reads the WRAPPED envelope on purpose: the flat {"additionalContext": ...}
# form is discarded by Claude Code when several plugins wire SessionStart at
# once (see test-session-start-wrapped-output.sh).
decode_context() {
  python3 -c "import sys,json; print(json.load(sys.stdin)['hookSpecificOutput']['additionalContext'])"
}

setup_project() {
  local dir="$1"
  mkdir -p "$dir/docs/slate/progress" "$dir/docs/slate/features"
  touch "$dir/docs/slate/progress/current.md" "$dir/docs/slate/features/in-progress.md"
}

# --- Test 1: plugin.json with a known version -> "slate X.Y.Z" line present ---
TMPDIR_PROJECT=$(mktemp -d)
setup_project "$TMPDIR_PROJECT"
touch "$TMPDIR_PROJECT/docs/slate/progress/history.md"

TMPDIR_PLUGIN=$(mktemp -d)
mkdir -p "$TMPDIR_PLUGIN/.claude-plugin"
printf '{"name": "slate", "version": "9.9.9"}' > "$TMPDIR_PLUGIN/.claude-plugin/plugin.json"

OUTPUT=$(echo '{"source":"startup"}' | CLAUDE_PROJECT_ROOT="$TMPDIR_PROJECT" CLAUDE_PLUGIN_ROOT="$TMPDIR_PLUGIN" bash "$HOOK")
CONTEXT=$(printf '%s' "$OUTPUT" | decode_context)
echo "$CONTEXT" | grep -qxF "slate 9.9.9" || { echo "FAIL: version line missing or malformed. Got: $CONTEXT"; exit 1; }
echo "PASS: active plugin version is injected as a visible line"
rm -rf "$TMPDIR_PROJECT" "$TMPDIR_PLUGIN"

# --- Test 2: plugin.json missing/unreadable -> hook does not error, no version line ---
TMPDIR_PROJECT2=$(mktemp -d)
setup_project "$TMPDIR_PROJECT2"
touch "$TMPDIR_PROJECT2/docs/slate/progress/history.md"

TMPDIR_PLUGIN2=$(mktemp -d)  # no .claude-plugin/plugin.json at all

ERRFILE=$(mktemp)
OUTPUT2=$(echo '{"source":"startup"}' | CLAUDE_PROJECT_ROOT="$TMPDIR_PROJECT2" CLAUDE_PLUGIN_ROOT="$TMPDIR_PLUGIN2" bash "$HOOK" 2>"$ERRFILE")
[ -s "$ERRFILE" ] && { echo "FAIL: missing plugin.json produced stderr output: $(cat "$ERRFILE")"; rm -f "$ERRFILE"; exit 1; }
rm -f "$ERRFILE"
CONTEXT2=$(printf '%s' "$OUTPUT2" | decode_context)
echo "$CONTEXT2" | grep -q '^slate [0-9]' && { echo "FAIL: a version line appeared despite no plugin.json. Got: $CONTEXT2"; exit 1; }
echo "PASS: missing plugin.json is silently skipped, hook does not error"
rm -rf "$TMPDIR_PROJECT2" "$TMPDIR_PLUGIN2"

# --- Test 3: history.md with 41 real blocks (over the 40 limit) -> warning line shown ---
TMPDIR_PROJECT3=$(mktemp -d)
setup_project "$TMPDIR_PROJECT3"
for i in $(seq 1 41); do
  printf '## 2026-01-%02d — session %d\nsome work\n\n' "$((i % 28 + 1))" "$i" >> "$TMPDIR_PROJECT3/docs/slate/progress/history.md"
done

OUTPUT3=$(echo '{"source":"startup"}' | CLAUDE_PROJECT_ROOT="$TMPDIR_PROJECT3" bash "$HOOK")
CONTEXT3=$(printf '%s' "$OUTPUT3" | decode_context)
echo "$CONTEXT3" | grep -qF "history.md: 41/40 bloques" || { echo "FAIL: over-limit history.md did not surface the block-count warning. Got: $CONTEXT3"; exit 1; }
echo "PASS: history.md over the 40-block limit surfaces a visible warning line"
rm -rf "$TMPDIR_PROJECT3"

# --- Test 4: history.md with 5 real blocks (under the limit) -> no warning line ---
TMPDIR_PROJECT4=$(mktemp -d)
setup_project "$TMPDIR_PROJECT4"
for i in $(seq 1 5); do
  printf '## 2026-01-%02d — session %d\nsome work\n\n' "$i" "$i" >> "$TMPDIR_PROJECT4/docs/slate/progress/history.md"
done

OUTPUT4=$(echo '{"source":"startup"}' | CLAUDE_PROJECT_ROOT="$TMPDIR_PROJECT4" bash "$HOOK")
CONTEXT4=$(printf '%s' "$OUTPUT4" | decode_context)
echo "$CONTEXT4" | grep -q "bloques" && { echo "FAIL: under-limit history.md should not show the block-count line. Got: $CONTEXT4"; exit 1; }
echo "PASS: history.md under the 40-block limit shows no warning line"
rm -rf "$TMPDIR_PROJECT4"

# --- Test 5: the count must not be inflated by hook exhaust ('## ' lines that
# are not real session blocks: SessionStart init.sh stubs, PreCompact stubs).
# A naive raw '## ' count would read this file as 45 blocks (over the limit);
# the real count, after the same filtering history_tail() already applies, is
# 5 real blocks (under the limit) plus 40 noise lines that must not count. ---
TMPDIR_PROJECT5=$(mktemp -d)
setup_project "$TMPDIR_PROJECT5"
for i in $(seq 1 5); do
  printf '## 2026-01-%02d — session %d\nsome work\n\n' "$i" "$i" >> "$TMPDIR_PROJECT5/docs/slate/progress/history.md"
done
for i in $(seq 1 40); do
  printf '## 2026-01-01T00:00:%02dZ — SessionStart init.sh\n[init.sh] OK\n\n' "$((i % 60))" >> "$TMPDIR_PROJECT5/docs/slate/progress/history.md"
done
RAW_COUNT=$(grep -c '^## ' "$TMPDIR_PROJECT5/docs/slate/progress/history.md")
[ "$RAW_COUNT" -eq 45 ] || { echo "FAIL: test setup bug — expected 45 raw '## ' lines, got $RAW_COUNT"; exit 1; }

OUTPUT5=$(echo '{"source":"startup"}' | CLAUDE_PROJECT_ROOT="$TMPDIR_PROJECT5" bash "$HOOK")
CONTEXT5=$(printf '%s' "$OUTPUT5" | decode_context)
echo "$CONTEXT5" | grep -q "bloques" && { echo "FAIL: hook-exhaust '## ' lines inflated the count past the limit (raw=$RAW_COUNT, real=5). Got: $CONTEXT5"; exit 1; }
echo "PASS: the block count filters out hook exhaust, matching history_tail()'s notion of a real entry"
rm -rf "$TMPDIR_PROJECT5"

echo ""
echo "All session-start version/history-count tests passed."
