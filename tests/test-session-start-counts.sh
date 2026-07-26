#!/usr/bin/env bash
set -e
trap 'echo "FAIL at line $LINENO"; rm -rf "$TMPDIR_PROJECT" 2>/dev/null || true' ERR

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/session-start.sh"

TMPDIR_PROJECT=$(mktemp -d)
mkdir -p "$TMPDIR_PROJECT/docs/slate/progress" "$TMPDIR_PROJECT/docs/slate/features" "$TMPDIR_PROJECT/docs/slate/bugs" "$TMPDIR_PROJECT/docs/slate/ideas"
touch "$TMPDIR_PROJECT/docs/slate/progress/history.md" "$TMPDIR_PROJECT/docs/slate/progress/current.md"
touch "$TMPDIR_PROJECT/docs/slate/features/in-progress.md"

cat > "$TMPDIR_PROJECT/docs/slate/bugs/open.md" <<'EOF'
# Open bugs

## BUG-001: Login button unresponsive
- **Status**: open

## BUG-002: Pagination off by one
- **Status**: open
EOF

cat > "$TMPDIR_PROJECT/docs/slate/ideas/inbox.md" <<'EOF'
# Ideas inbox

- 2026-07-01 10:00 — Add PDF export
EOF

OUTPUT=$(echo '{"source":"startup"}' | CLAUDE_PROJECT_ROOT="$TMPDIR_PROJECT" bash "$HOOK")

echo "$OUTPUT" | grep -q "Bugs abiertos: 2 (BUG-001,BUG-002)" || { echo "FAIL: bug count/IDs missing from output. Got: $OUTPUT"; exit 1; }
echo "PASS: bug count injected correctly"

# 1.8.0: el buzon de ideas es un DEPOSITO, no una cola. Una sola idea no se
# anuncia — el aviso solo aparece al superar SLATE_IDEAS_NAG_AT (def. 40).
# El umbral en si se prueba en test-hygiene-1.8.0.sh (28 -> silencio, 41 -> aviso).
echo "$OUTPUT" | grep -q "Ideas" && { echo "FAIL: 1 idea no debe generar aviso. Got: $OUTPUT"; exit 1; }
echo "PASS: 1 idea no genera aviso (buzon = deposito, no cola)"

OUTPUT_NAG=$(echo '{"source":"startup"}' | SLATE_IDEAS_NAG_AT=1 CLAUDE_PROJECT_ROOT="$TMPDIR_PROJECT" bash "$HOOK")
echo "$OUTPUT_NAG" | grep -q "Ideas acumuladas: 1" || { echo "FAIL: con el umbral en 1 deberia avisar. Got: $OUTPUT_NAG"; exit 1; }
echo "PASS: SLATE_IDEAS_NAG_AT ajusta el umbral del aviso"

# --- Test: no bugs/ideas dirs -> hook does not error, no bug/idea lines ---
TMPDIR_PROJECT2=$(mktemp -d)
mkdir -p "$TMPDIR_PROJECT2/docs/slate/progress" "$TMPDIR_PROJECT2/docs/slate/features"
touch "$TMPDIR_PROJECT2/docs/slate/progress/history.md" "$TMPDIR_PROJECT2/docs/slate/progress/current.md" "$TMPDIR_PROJECT2/docs/slate/features/in-progress.md"

OUTPUT2=$(echo '{"source":"startup"}' | CLAUDE_PROJECT_ROOT="$TMPDIR_PROJECT2" bash "$HOOK")
echo "$OUTPUT2" | grep -q "Bugs abiertos" && { echo "FAIL: bug line present when bugs/ absent"; exit 1; }
echo "$OUTPUT2" | grep -q "Ideas" && { echo "FAIL: idea line present when ideas/ absent"; exit 1; }
echo "PASS: no bug/idea lines when directories absent, hook did not error"

# --- Test: bugs/open.md and ideas/inbox.md exist with template-only content
# (freshly installed, no real bugs/ideas yet) -> no count lines emitted ---
TMPDIR_PROJECT3=$(mktemp -d)
mkdir -p "$TMPDIR_PROJECT3/docs/slate/progress" "$TMPDIR_PROJECT3/docs/slate/features" "$TMPDIR_PROJECT3/docs/slate/bugs" "$TMPDIR_PROJECT3/docs/slate/ideas"
touch "$TMPDIR_PROJECT3/docs/slate/progress/history.md" "$TMPDIR_PROJECT3/docs/slate/progress/current.md" "$TMPDIR_PROJECT3/docs/slate/features/in-progress.md"

cp "$PLUGIN_ROOT/templates/bugs/open.md" "$TMPDIR_PROJECT3/docs/slate/bugs/open.md"
cp "$PLUGIN_ROOT/templates/ideas/inbox.md" "$TMPDIR_PROJECT3/docs/slate/ideas/inbox.md"

OUTPUT3=$(echo '{"source":"startup"}' | CLAUDE_PROJECT_ROOT="$TMPDIR_PROJECT3" bash "$HOOK")
echo "$OUTPUT3" | grep -q "Bugs abiertos" && { echo "FAIL: bug line present for template-only bugs/open.md. Got: $OUTPUT3"; exit 1; }
echo "$OUTPUT3" | grep -q "Ideas" && { echo "FAIL: idea line present for template-only ideas/inbox.md. Got: $OUTPUT3"; exit 1; }
echo "PASS: no bug/idea lines when files contain only template content"

rm -rf "$TMPDIR_PROJECT" "$TMPDIR_PROJECT2" "$TMPDIR_PROJECT3"
echo ""
echo "All session-start count tests passed."
