#!/usr/bin/env bash
# Una sesion con HEAD desprendido (detached HEAD) DEBE registrarse igual.
#
# Hasta 1.7.0 session-lock.sh salia antes de escribir el lock cuando no habia
# rama actual ("detached HEAD: nothing to protect"). Eso era cierto con el
# modelo viejo (el lock reclamaba una RAMA); con el modelo por CARPETA es
# falso: el arbol de trabajo de una sesion desprendida se destruye igual que
# cualquier otro. Sin lock, esa sesion es INVISIBLE para el guardian y el
# checkout de un peer se permitia en silencio por encima de ella.
set -e
trap 'echo "FAIL at line $LINENO"' ERR

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK_HOOK="$PLUGIN_ROOT/hooks/session-lock.sh"
GUARDIAN="$PLUGIN_ROOT/hooks/session-guardian.sh"

setup_repo() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q
  git -C "$dir" config user.email "t@t.com"
  git -C "$dir" config user.name "t"
  git -C "$dir" commit --allow-empty -q -m init
  git -C "$dir" commit --allow-empty -q -m second
  echo "$dir"
}

lock_field() {
  python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],'MISSING'))" "$1" "$2"
}

payload() {
  # $1=session_id $2=cwd $3=command
  python3 -c "import json,sys; print(json.dumps({'session_id': sys.argv[1], 'cwd': sys.argv[2], 'tool_name': 'Bash', 'tool_input': {'command': sys.argv[3]}}))" "$1" "$2" "$3"
}

is_deny() { echo "$1" | grep -q '"permissionDecision": "deny"'; }

# --- 1. una sesion desprendida ESCRIBE su lock, con branch vacio y cwd fisico ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
git -C "$REPO" checkout -q --detach HEAD
[ -z "$(git -C "$REPO" branch --show-current)" ] || { echo "FAIL: el repo de prueba no quedo en detached HEAD"; exit 1; }

echo '{"session_id":"sess-detached"}' | CLAUDE_PROJECT_ROOT="$REPO" bash "$LOCK_HOOK" >/dev/null
LOCK="$REAL/.git/slate-sessions/sess-detached.lock"
[ -f "$LOCK" ] || { echo "FAIL: una sesion en detached HEAD no escribio lock (es invisible para el guardian)"; exit 1; }

GOT_BR=$(lock_field "$LOCK" branch)
[ "$GOT_BR" = "" ] || { echo "FAIL: branch esperado '' en detached HEAD, obtenido '$GOT_BR'"; exit 1; }
GOT_CWD=$(lock_field "$LOCK" cwd)
[ "$GOT_CWD" = "$REAL" ] || { echo "FAIL: cwd esperado '$REAL', obtenido '$GOT_CWD'"; exit 1; }
GOT_HEAD=$(lock_field "$LOCK" head)
[ "$GOT_HEAD" = "$(git -C "$REPO" rev-parse HEAD)" ] || { echo "FAIL: head no registrado en detached HEAD: '$GOT_HEAD'"; exit 1; }
echo "PASS: una sesion en detached HEAD registra su lock (branch vacio, cwd fisico, head)"

# --- 2. END TO END: con ese lock vivo, el checkout de un peer de la misma
#        carpeta se DENIEGA. Es la consecuencia real del caso 1. ---
OUT=$(payload "otra-sesion" "$REAL" "git checkout main" | bash "$GUARDIAN")
is_deny "$OUT" || { echo "FAIL: el checkout de un peer NO fue denegado sobre una sesion en detached HEAD: '${OUT:-<vacio>}'"; exit 1; }
echo "PASS: el checkout de un peer se deniega sobre una sesion viva en detached HEAD (end to end)"
rm -rf "$REPO"

# --- 3. dos sesiones desprendidas NO colisionan entre si por branch=='' ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
git -C "$REPO" checkout -q --detach HEAD
mkdir -p "$REAL/.git/slate-sessions"
python3 -c "import json,sys; json.dump({'branch':'','cwd':sys.argv[2],'worktree':'','head':'','started_at':'2026-01-01T00:00:00Z','files':[]}, open(sys.argv[1],'w'))" \
  "$REAL/.git/slate-sessions/peer-detached.lock" "$REAL"

OUT=$(echo '{"session_id":"sess-det2"}' | CLAUDE_PROJECT_ROOT="$REPO" bash "$LOCK_HOOK")
echo "$OUT" | grep -q additionalContext && { echo "FAIL: dos sesiones en detached HEAD no deben colisionar por rama vacia: $OUT"; exit 1; }
[ -f "$REAL/.git/slate-sessions/sess-det2.lock" ] || { echo "FAIL: la segunda sesion desprendida no escribio lock"; exit 1; }
echo "PASS: dos sesiones en detached HEAD no colisionan por 'branch' vacio"

# --- 3b. control positivo: sobre una RAMA, la colision por rama sigue avisando ---
git -C "$REPO" checkout -q -B rama-viva
python3 -c "import json,sys; json.dump({'branch':'rama-viva','cwd':sys.argv[2],'worktree':'','head':'','started_at':'2026-01-01T00:00:00Z','files':[]}, open(sys.argv[1],'w'))" \
  "$REAL/.git/slate-sessions/peer-branch.lock" "$REAL"
OUT=$(echo '{"session_id":"sess-det3"}' | CLAUDE_PROJECT_ROOT="$REPO" bash "$LOCK_HOOK")
echo "$OUT" | grep -q additionalContext || { echo "FAIL: control positivo — una colision de rama real debe seguir avisando: '${OUT:-<vacio>}'"; exit 1; }
echo "PASS: control positivo — la colision por rama real sigue avisando"
rm -rf "$REPO"

# --- 4. el guardian tampoco inventa una colision de rama entre dos locks con
#        branch vacio (regla 1, verbos de integracion) ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
git -C "$REPO" checkout -q --detach HEAD
mkdir -p "$REAL/.git/slate-sessions"
python3 -c "import json,sys; json.dump({'branch':'','cwd':'/carpeta/que/no/existe','worktree':'','head':'','started_at':'2026-01-01T00:00:00Z','files':[]}, open(sys.argv[1],'w'))" \
  "$REAL/.git/slate-sessions/peer-detached.lock"
OUT=$(payload "yo" "$REAL" "git commit -m x" | bash "$GUARDIAN")
is_deny "$OUT" && { echo "FAIL: dos locks con branch vacio no son una colision de rama: $OUT"; exit 1; }
echo "PASS: el guardian no confunde dos 'branch' vacios con una colision de rama"
rm -rf "$REPO"

echo "All detached-HEAD session-lock tests passed."
