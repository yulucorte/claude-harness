#!/usr/bin/env bash
# El lock debe registrar SIEMPRE la carpeta fisica de trabajo (cwd), no solo al aislar.
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

lock_field() {
  # $1=ruta del lock  $2=campo
  python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],'MISSING'))" "$1" "$2"
}

# --- 1. sesion sola: el lock registra cwd fisico y files vacio ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
echo '{"session_id":"sess-solo"}' | CLAUDE_PROJECT_ROOT="$REPO" bash "$HOOK" >/dev/null

LOCK="$REAL/.git/slate-sessions/sess-solo.lock"
[ -f "$LOCK" ] || { echo "FAIL: no se creo el lock en $LOCK"; exit 1; }

GOT=$(lock_field "$LOCK" cwd)
[ "$GOT" = "$REAL" ] || { echo "FAIL: cwd esperado '$REAL', obtenido '$GOT'"; exit 1; }
echo "PASS: el lock de una sesion sola registra cwd fisico"

FILES=$(python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get('files','MISSING')))" "$LOCK")
[ "$FILES" = "[]" ] || { echo "FAIL: 'files' esperado [], obtenido $FILES"; exit 1; }
echo "PASS: el lock inicializa files como lista vacia"
rm -rf "$REPO"

# --- 2. segunda sesion en colision: tambien registra su cwd ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
BR=$(git -C "$REPO" branch --show-current)
mkdir -p "$REAL/.git/slate-sessions"
cat > "$REAL/.git/slate-sessions/sess-live.lock" <<EOF
{"branch": "$BR", "cwd": "$REAL", "worktree": "", "started_at": "2026-01-01T00:00:00Z", "files": []}
EOF

echo '{"session_id":"sess-second"}' | CLAUDE_PROJECT_ROOT="$REPO" bash "$HOOK" >/dev/null
GOT=$(lock_field "$REAL/.git/slate-sessions/sess-second.lock" cwd)
[ "$GOT" = "$REAL" ] || { echo "FAIL: en colision, cwd esperado '$REAL', obtenido '$GOT'"; exit 1; }
echo "PASS: el lock de una sesion en colision tambien registra cwd"
rm -rf "$REPO"

# --- 3. el heartbeat refresca cwd en un lock que no lo tenia (lock legado) ---
HB="$PLUGIN_ROOT/hooks/session-heartbeat.sh"
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
mkdir -p "$REAL/.git/slate-sessions"
cat > "$REAL/.git/slate-sessions/sess-legacy.lock" <<EOF
{"branch": "main", "worktree": "", "started_at": "2026-01-01T00:00:00Z"}
EOF

python3 -c "import json,sys; print(json.dumps({'session_id':'sess-legacy','cwd':sys.argv[1],'tool_name':'Bash','tool_input':{'command':'ls'}}))" "$REAL" \
  | bash "$HB" >/dev/null

GOT=$(lock_field "$REAL/.git/slate-sessions/sess-legacy.lock" cwd)
[ "$GOT" = "$REAL" ] || { echo "FAIL: el heartbeat no relleno cwd en lock legado: '$GOT'"; exit 1; }
echo "PASS: el heartbeat rellena cwd en locks legados"
rm -rf "$REPO"

echo "All session-lock cwd tests passed."
