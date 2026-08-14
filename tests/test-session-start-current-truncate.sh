#!/usr/bin/env bash
# session-start.sh injects docs/slate/progress/current.md in full on startup/clear.
# Measured on a live project: current.md reached 31.6 KB (~9000 tokens) because
# it was never capped. This caps the injection to the last ~100 lines, with a
# truncation note at the top of the trimmed block. Files of 100 lines or fewer
# are injected whole, no note.
set -e
trap 'echo "FAIL at line $LINENO"; rm -rf "$TMPDIR_PROJECT" "$TMPDIR_PROJECT2" 2>/dev/null || true' ERR

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/session-start.sh"
NOTE="(truncado — abre docs/slate/progress/current.md si necesitas el resto)"

# The hook JSON-escapes additionalContext (em-dash becomes —), so a raw
# grep -F for the literal note never matches. Decode first, like a real
# consumer of this hook's stdout would — which means reading the WRAPPED
# envelope: Claude Code discards the flat {"additionalContext": ...} form when
# several plugins wire SessionStart at once (see test-session-start-wrapped-output.sh).
decode_context() {
  python3 -c "import sys,json; print(json.load(sys.stdin)['hookSpecificOutput']['additionalContext'])"
}

# --- Test 1: current.md with 150 lines -> only last 100 injected, with note ---
TMPDIR_PROJECT=$(mktemp -d)
mkdir -p "$TMPDIR_PROJECT/docs/slate/progress" "$TMPDIR_PROJECT/docs/slate/features"
touch "$TMPDIR_PROJECT/docs/slate/progress/history.md" "$TMPDIR_PROJECT/docs/slate/features/in-progress.md"

for i in $(seq 1 150); do
  printf 'LINEMARKER:%03d:END\n' "$i" >> "$TMPDIR_PROJECT/docs/slate/progress/current.md"
done

OUTPUT=$(echo '{"source":"startup"}' | CLAUDE_PROJECT_ROOT="$TMPDIR_PROJECT" bash "$HOOK")
CONTEXT=$(printf '%s' "$OUTPUT" | decode_context)

echo "$CONTEXT" | grep -qF "$NOTE" || { echo "FAIL: truncation note missing for a 150-line current.md. Got: $CONTEXT"; exit 1; }
echo "PASS: truncation note present for a current.md over 100 lines"

echo "$CONTEXT" | grep -q "LINEMARKER:150:END" || { echo "FAIL: last line of current.md missing from injected context"; exit 1; }
echo "$CONTEXT" | grep -q "LINEMARKER:051:END" || { echo "FAIL: line 51 (first of the kept tail) missing from injected context"; exit 1; }
echo "PASS: last 100 lines of current.md are present"

echo "$CONTEXT" | grep -q "LINEMARKER:050:END" && { echo "FAIL: line 50 (should have been trimmed) is present in injected context"; exit 1; }
echo "$CONTEXT" | grep -q "LINEMARKER:001:END" && { echo "FAIL: line 1 (should have been trimmed) is present in injected context"; exit 1; }
echo "PASS: lines beyond the last 100 are trimmed out of the injected context"

rm -rf "$TMPDIR_PROJECT"

# --- Test 2: current.md with 50 lines (<= 100) -> injected whole, no note ---
TMPDIR_PROJECT2=$(mktemp -d)
mkdir -p "$TMPDIR_PROJECT2/docs/slate/progress" "$TMPDIR_PROJECT2/docs/slate/features"
touch "$TMPDIR_PROJECT2/docs/slate/progress/history.md" "$TMPDIR_PROJECT2/docs/slate/features/in-progress.md"

for i in $(seq 1 50); do
  printf 'LINEMARKER:%03d:END\n' "$i" >> "$TMPDIR_PROJECT2/docs/slate/progress/current.md"
done

OUTPUT2=$(echo '{"source":"startup"}' | CLAUDE_PROJECT_ROOT="$TMPDIR_PROJECT2" bash "$HOOK")
CONTEXT2=$(printf '%s' "$OUTPUT2" | decode_context)

echo "$CONTEXT2" | grep -qF "$NOTE" && { echo "FAIL: truncation note present for a 50-line current.md (should not be truncated). Got: $CONTEXT2"; exit 1; }
echo "PASS: no truncation note for a current.md at or under 100 lines"

echo "$CONTEXT2" | grep -q "LINEMARKER:001:END" || { echo "FAIL: first line missing from an untruncated current.md"; exit 1; }
echo "$CONTEXT2" | grep -q "LINEMARKER:050:END" || { echo "FAIL: last line missing from an untruncated current.md"; exit 1; }
echo "PASS: a current.md at or under 100 lines is injected whole"

rm -rf "$TMPDIR_PROJECT2"

echo ""
echo "All session-start current.md truncation tests passed."
