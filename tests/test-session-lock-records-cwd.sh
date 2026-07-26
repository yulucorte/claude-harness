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

# --- 4. el lock preserva 'files' acumulado entre disparos del mismo session_id
#        (SessionStart se re-dispara en compact/clear/resume con el mismo id) ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
echo '{"session_id":"sess-repeat"}' | CLAUDE_PROJECT_ROOT="$REPO" bash "$HOOK" >/dev/null

LOCK="$REAL/.git/slate-sessions/sess-repeat.lock"
[ -f "$LOCK" ] || { echo "FAIL: no se creo el lock en $LOCK"; exit 1; }

python3 -c "import json
d = json.load(open('$LOCK'))
d['files'] = ['src/foo.py', 'src/bar.py']
json.dump(d, open('$LOCK', 'w'))
"

echo '{"session_id":"sess-repeat"}' | CLAUDE_PROJECT_ROOT="$REPO" bash "$HOOK" >/dev/null

FILES=$(python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get('files','MISSING')))" "$LOCK")
[ "$FILES" = '["src/foo.py", "src/bar.py"]' ] || { echo "FAIL: 'files' esperado acumulado tras 2do disparo, obtenido $FILES"; exit 1; }
echo "PASS: el lock preserva 'files' acumulado entre disparos del mismo session_id"
rm -rf "$REPO"

# --- 5. un valor de 'files' que NO es una lista degrada a [] sin error ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
mkdir -p "$REAL/.git/slate-sessions"
cat > "$REAL/.git/slate-sessions/sess-badfiles.lock" <<EOF
{"branch": "main", "cwd": "$REAL", "worktree": "", "started_at": "2026-01-01T00:00:00Z", "files": "not-a-list"}
EOF

echo '{"session_id":"sess-badfiles"}' | CLAUDE_PROJECT_ROOT="$REPO" bash "$HOOK" >/dev/null
RC5=$?
[ "$RC5" -eq 0 ] || { echo "FAIL: el hook no salio con codigo 0 ante 'files' no-lista"; exit 1; }

FILES=$(python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get('files','MISSING')))" "$REAL/.git/slate-sessions/sess-badfiles.lock")
[ "$FILES" = "[]" ] || { echo "FAIL: 'files' no-lista deberia degradar a [], obtenido $FILES"; exit 1; }
echo "PASS: un valor de 'files' no-lista degrada a [] sin error"
rm -rf "$REPO"

# --- 6. un lock con JSON corrupto no rompe el hook y 'files' arranca en [] ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
mkdir -p "$REAL/.git/slate-sessions"
printf '{not valid json at all' > "$REAL/.git/slate-sessions/sess-corrupt.lock"

echo '{"session_id":"sess-corrupt"}' | CLAUDE_PROJECT_ROOT="$REPO" bash "$HOOK" >/dev/null
RC6=$?
[ "$RC6" -eq 0 ] || { echo "FAIL: el hook no salio con codigo 0 ante lock corrupto"; exit 1; }

GOT=$(lock_field "$REAL/.git/slate-sessions/sess-corrupt.lock" cwd)
[ "$GOT" = "$REAL" ] || { echo "FAIL: el hook no reescribio un lock valido sobre uno corrupto. cwd obtenido: $GOT"; exit 1; }
FILES=$(python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get('files','MISSING')))" "$REAL/.git/slate-sessions/sess-corrupt.lock")
[ "$FILES" = "[]" ] || { echo "FAIL: 'files' deberia arrancar en [] tras lock corrupto, obtenido $FILES"; exit 1; }
echo "PASS: un lock con JSON corrupto no rompe el hook y 'files' arranca en []"
rm -rf "$REPO"

# --- 7. la escritura del lock es ATOMICA: temporal + rename, nunca truncado
#        en sitio. Truncar el lock propio abre una ventana en la que el
#        guardian lo lee a medias, lo descarta por ilegible y deja de ver a un
#        peer VIVO — justo la senal que decide una denegacion. SessionStart se
#        re-dispara en startup|resume|clear|compact, asi que la ventana vuelve
#        una y otra vez durante la sesion. ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)

# 7a. una corrida normal no deja restos .tmp y deja un JSON completo
echo '{"session_id":"sess-atomic"}' | CLAUDE_PROJECT_ROOT="$REPO" bash "$HOOK" >/dev/null
LOCK="$REAL/.git/slate-sessions/sess-atomic.lock"
[ -f "$LOCK" ] || { echo "FAIL: no se creo el lock en $LOCK"; exit 1; }
LEFTOVERS=$(ls "$REAL/.git/slate-sessions/" | grep -c '\.tmp$' || true)
[ "$LEFTOVERS" -eq 0 ] || { echo "FAIL: la escritura dejo $LEFTOVERS temporal(es) .tmp sin limpiar"; exit 1; }
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$LOCK" \
  || { echo "FAIL: el lock no es JSON valido tras una corrida normal"; exit 1; }
echo "PASS: la escritura normal del lock no deja temporales y produce JSON valido"

# 7b. si la escritura falla a medias, el lock ANTERIOR sobrevive intacto.
#     El fallo se fuerza creando <lock>.tmp como DIRECTORIO: la escritura
#     atomica no puede abrir su temporal y aborta ANTES de tocar el lock real;
#     una escritura truncante habria destruido el contenido previo antes de
#     saber siquiera si podia completarse.
python3 -c "import json,sys; json.dump({'branch':'main','cwd':sys.argv[2],'worktree':'','head':'MARCA-PREVIA','started_at':'2026-01-01T00:00:00Z','files':[]}, open(sys.argv[1],'w'))" \
  "$LOCK" "$REAL"
mkdir "$LOCK.tmp"

RC7=0
echo '{"session_id":"sess-atomic"}' | CLAUDE_PROJECT_ROOT="$REPO" bash "$HOOK" >/dev/null || RC7=$?
[ "$RC7" -eq 0 ] || { echo "FAIL: el hook no salio con codigo 0 cuando la escritura del lock fallo"; exit 1; }

python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$LOCK" \
  || { echo "FAIL: una escritura fallida dejo el lock ilegible (se trunco en sitio)"; exit 1; }
GOT=$(lock_field "$LOCK" head)
[ "$GOT" = "MARCA-PREVIA" ] || { echo "FAIL: una escritura fallida destruyo el lock previo (head esperado 'MARCA-PREVIA', obtenido '$GOT'): la escritura no es atomica"; exit 1; }
echo "PASS: una escritura fallida deja intacto el lock anterior (temporal + rename, no truncado en sitio)"
rm -rf "$REPO"

echo "All session-lock cwd tests passed."
