#!/usr/bin/env bash
# El heartbeat debe anotar en el lock los archivos que esta sesion escribe,
# deduplicados por ruta y acotados a 20 entradas.
set -e
trap 'echo "FAIL at line $LINENO"' ERR

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/session-heartbeat.sh"

setup_repo() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q
  git -C "$dir" config user.email "t@t.com"
  git -C "$dir" config user.name "t"
  git -C "$dir" commit --allow-empty -q -m init
  mkdir -p "$dir/.git/slate-sessions"
  printf '{"branch": "main", "cwd": "%s", "worktree": "", "head": "", "started_at": "2026-01-01T00:00:00Z", "files": []}' \
    "$(cd "$dir" && pwd -P)" > "$dir/.git/slate-sessions/sess-hb.lock"
  echo "$dir"
}

beat() {
  # $1=cwd $2=tool_name $3=file_path
  python3 -c "import json,sys; print(json.dumps({'session_id':'sess-hb','cwd':sys.argv[1],'tool_name':sys.argv[2],'tool_input':{'file_path':sys.argv[3]}}))" "$1" "$2" "$3" \
    | bash "$HOOK" >/dev/null
}

paths() {
  python3 -c "import json,sys; print(','.join(e['path'] for e in json.load(open(sys.argv[1])).get('files',[])))" "$1"
}
count() {
  python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('files',[])))" "$1"
}

# --- 1. un Write queda anotado con ruta y ts ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
LOCK="$REAL/.git/slate-sessions/sess-hb.lock"
beat "$REAL" "Write" "$REAL/a.txt"
[ "$(paths "$LOCK")" = "$REAL/a.txt" ] || { echo "FAIL: Write no quedo anotado: $(paths "$LOCK")"; exit 1; }
TS=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['files'][0].get('ts',0))" "$LOCK")
[ "$TS" -gt 0 ] || { echo "FAIL: la entrada no tiene ts valido: $TS"; exit 1; }
echo "PASS: un Write queda anotado con path y ts"

# --- 2. Edit tambien se anota; herramientas de lectura no ---
beat "$REAL" "Edit" "$REAL/b.txt"
beat "$REAL" "Read" "$REAL/c.txt"
[ "$(paths "$LOCK")" = "$REAL/a.txt,$REAL/b.txt" ] || { echo "FAIL: se esperaba a,b; hay: $(paths "$LOCK")"; exit 1; }
echo "PASS: Edit se anota y Read no"

# --- 3. reescribir el mismo archivo deduplica y lo mueve al final ---
beat "$REAL" "Write" "$REAL/a.txt"
[ "$(paths "$LOCK")" = "$REAL/b.txt,$REAL/a.txt" ] || { echo "FAIL: no deduplico por path: $(paths "$LOCK")"; exit 1; }
echo "PASS: deduplica por path conservando el mas reciente"
rm -rf "$REPO"

# --- 4. tope de 20 entradas ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
LOCK="$REAL/.git/slate-sessions/sess-hb.lock"
for i in $(seq 1 25); do beat "$REAL" "Write" "$REAL/f$i.txt"; done
[ "$(count "$LOCK")" = "20" ] || { echo "FAIL: se esperaban 20 entradas, hay $(count "$LOCK")"; exit 1; }
paths "$LOCK" | grep -q "f25.txt" || { echo "FAIL: falta la escritura mas reciente"; exit 1; }
paths "$LOCK" | grep -q "f1.txt" && { echo "FAIL: no se descarto la mas antigua"; exit 1; }
echo "PASS: la lista se acota a las 20 mas recientes"
rm -rf "$REPO"

# --- 5. sin lock propio no hace nada y no rompe ---
REPO=$(mktemp -d)
git -C "$REPO" init -q
REAL=$(cd "$REPO" && pwd -P)
beat "$REAL" "Write" "$REAL/x.txt"
echo "PASS: sin lock propio termina limpio"
rm -rf "$REPO"

# --- 6/7/8: un payload malformado degrada en silencio, no revienta el parseo ---
# El script bash siempre termina en 'exit 0' pase lo que pase adentro, asi que
# el codigo de salida por si solo NO detecta un traceback de python interno --
# hay que revisar stderr. Y si el traceback ocurre ANTES del os.utime() de
# liveness y del espejo de branch/head/cwd (que es donde vivian las lineas de
# tool_name/tool_input agregadas en la Task 4), esta funcion tambien lo
# detecta exigiendo que el mtime del lock avance igual.
assert_malformed_safe() {
  # $1=label $2=payload json (ya serializado) $3=lock path
  local label="$1" payload="$2" lock="$3" before after out err rc old_mtime new_mtime
  before=$(count "$lock")
  python3 -c "import os,time; t=time.time()-1000; os.utime('$lock',(t,t))"
  old_mtime=$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock")
  out=$(mktemp); err=$(mktemp)
  printf '%s' "$payload" | bash "$HOOK" >"$out" 2>"$err"
  rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL ($label): exit code $rc, se esperaba 0"; exit 1; }
  [ -s "$out" ] && { echo "FAIL ($label): stdout no vacio: $(cat "$out")"; exit 1; }
  [ -s "$err" ] && { echo "FAIL ($label): stderr no vacio (traceback fugado): $(cat "$err")"; exit 1; }
  after=$(count "$lock")
  [ "$after" = "$before" ] || { echo "FAIL ($label): 'files' cambio ($before -> $after): $(paths "$lock")"; exit 1; }
  new_mtime=$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock")
  [ "$new_mtime" -gt "$old_mtime" ] || { echo "FAIL ($label): el heartbeat no refresco el lock (se perdio la liveness)"; exit 1; }
  rm -f "$out" "$err"
  echo "PASS: $label"
}

REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
LOCK="$REAL/.git/slate-sessions/sess-hb.lock"

PAYLOAD6=$(python3 -c "import json,sys; print(json.dumps({'session_id':'sess-hb','cwd':sys.argv[1],'tool_name':12345,'tool_input':{'file_path':sys.argv[1]+'/bad6.txt'}}))" "$REAL")
assert_malformed_safe "tool_name no-string degrada a ausente sin romper el hook" "$PAYLOAD6" "$LOCK"

PAYLOAD7=$(python3 -c "import json,sys; print(json.dumps({'session_id':'sess-hb','cwd':sys.argv[1],'tool_name':'Write','tool_input':'not-a-dict'}))" "$REAL")
assert_malformed_safe "tool_input no-dict degrada a vacio sin romper el hook" "$PAYLOAD7" "$LOCK"

PAYLOAD8=$(python3 -c "import json,sys; print(json.dumps({'session_id':'sess-hb','cwd':sys.argv[1],'tool_name':'Write','tool_input':{'file_path':12345}}))" "$REAL")
assert_malformed_safe "file_path no-string degrada a ausente sin romper el hook" "$PAYLOAD8" "$LOCK"

rm -rf "$REPO"

echo "All heartbeat file-tracking tests passed."
