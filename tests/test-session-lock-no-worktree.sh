#!/usr/bin/env bash
# Una colision de rama NO debe crear worktrees ni ramas: el aislamiento por
# worktree es inefectivo (un hook SessionStart no puede reubicar una sesion ya
# arrancada). Debe emitir un aviso accionable y nada mas.
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

REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
BR=$(git -C "$REPO" branch --show-current)
mkdir -p "$REAL/.git/slate-sessions"
cat > "$REAL/.git/slate-sessions/sess-live.lock" <<EOF
{"branch": "$BR", "cwd": "$REAL", "worktree": "", "started_at": "2026-01-01T00:00:00Z", "files": []}
EOF

OUT=$(echo '{"session_id":"sess-colliding"}' | CLAUDE_PROJECT_ROOT="$REPO" bash "$HOOK")

# 1. avisa de la colision
echo "$OUT" | grep -q additionalContext \
  || { echo "FAIL: no hubo additionalContext en una colision real. Output: $OUT"; exit 1; }
echo "PASS: la colision emite additionalContext"

# 2. el aviso nombra la operacion peligrosa
echo "$OUT" | grep -q "checkout" \
  || { echo "FAIL: el aviso no menciona checkout. Output: $OUT"; exit 1; }
echo "PASS: el aviso nombra la operacion peligrosa"

# 3. NO crea worktrees en disco
[ -d "${REPO}.slate-worktrees" ] && { echo "FAIL: se creo el directorio de worktrees"; exit 1; }
WT_COUNT=$(git -C "$REPO" worktree list | wc -l | tr -d ' ')
[ "$WT_COUNT" = "1" ] || { echo "FAIL: se esperaba 1 worktree (el principal), hay $WT_COUNT"; exit 1; }
echo "PASS: la colision no crea worktrees"

# 4. NO crea ramas slate-session/*
git -C "$REPO" branch --list 'slate-session/*' | grep -q . \
  && { echo "FAIL: se creo una rama slate-session/*"; exit 1; }
echo "PASS: la colision no crea ramas slate-session/*"

# 5. el lock propio queda en la rama real, no en una inventada
LOCK_BR=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('branch',''))" \
  "$REAL/.git/slate-sessions/sess-colliding.lock")
[ "$LOCK_BR" = "$BR" ] || { echo "FAIL: el lock registra rama '$LOCK_BR', se esperaba '$BR'"; exit 1; }
echo "PASS: el lock registra la rama real"

rm -rf "$REPO"
echo "All no-worktree tests passed."
