#!/usr/bin/env bash
# Cuando dos sesiones comparten carpeta y editan el MISMO archivo, el guardian
# avisa pero jamas bloquea: el choque de archivo es localizado y recuperable.
#
# Casos 2-5 llevan un CONTROL POSITIVO antes de cada aserto de silencio: primero
# se confirma que el aviso SI dispara con el setup base, y solo entonces se
# cambia UNA sola variable (archivo, carpeta, antiguedad, presencia del peer) y
# se confirma silencio. Sin el control positivo, un silencio no distingue "esta
# condicion correctamente no aplica" de "la regla nunca corre" (fix round 1,
# item 5: los 4 casos de silencio pasaban igual con el cuerpo de modo fichero
# vaciado a un 'sys.exit(0)').
set -e
trap 'echo "FAIL at line $LINENO"' ERR

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/session-guardian.sh"

setup_repo() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q
  git -C "$dir" config user.email "t@t.com"
  git -C "$dir" config user.name "t"
  git -C "$dir" commit --allow-empty -q -m init
  echo "$dir"
}

write_payload() {
  # $1=cwd $2=file_path
  python3 -c "import json,sys; print(json.dumps({'session_id':'yo','cwd':sys.argv[1],'tool_name':'Write','tool_input':{'file_path':sys.argv[2]}}))" "$1" "$2"
}

peer_with_file() {
  # $1=repo $2=lockname $3=cwd_del_peer $4=file_path $5=antiguedad_en_s_del_registro
  mkdir -p "$1/.git/slate-sessions"
  python3 -c "
import json, sys, time
peer_cwd, fp, age = sys.argv[2], sys.argv[3], float(sys.argv[4])
json.dump({'branch':'main','cwd':peer_cwd,'worktree':'','head':'',
           'started_at':'2026-01-01T00:00:00Z',
           'files':[{'path': fp, 'ts': int(time.time() - age)}]},
          open(sys.argv[1],'w'))
" "$1/.git/slate-sessions/$2.lock" "$3" "$4" "$5"
}

is_deny() { echo "$1" | grep -q '"permissionDecision"'; }
is_warn() { echo "$1" | grep -q '"additionalContext"'; }

# --- 1. mismo archivo, misma carpeta, reciente -> AVISA sin bloquear ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
peer_with_file "$REPO" "peer" "$REAL" "$REAL/shared.txt" 30
OUT=$(write_payload "$REAL" "$REAL/shared.txt" | bash "$HOOK")
is_warn "$OUT" || { echo "FAIL: no aviso del archivo compartido: $OUT"; exit 1; }
is_deny "$OUT" && { echo "FAIL: un choque de archivo NUNCA debe bloquear: $OUT"; exit 1; }
echo "PASS: archivo compartido avisa y no bloquea"
rm -rf "$REPO"

# --- 2. control positivo (mismo archivo -> avisa), luego SOLO el archivo cambia -> silencio ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
peer_with_file "$REPO" "peer" "$REAL" "$REAL/mio.txt" 30
OUT=$(write_payload "$REAL" "$REAL/mio.txt" | bash "$HOOK")
is_warn "$OUT" || { echo "FAIL: control positivo (mismo archivo) no aviso: $OUT"; exit 1; }
OUT=$(write_payload "$REAL" "$REAL/otro-nombre.txt" | bash "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: archivos distintos no deben producir output: $OUT"; exit 1; }
echo "PASS: archivos distintos no producen aviso (con control positivo)"
rm -rf "$REPO"

# --- 3. control positivo (misma carpeta -> avisa), luego SOLO la carpeta del peer cambia -> silencio ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
OTHER=$(mktemp -d)
OTHERREAL=$(cd "$OTHER" && pwd -P)
peer_with_file "$REPO" "peer" "$REAL" "$REAL/shared.txt" 30
OUT=$(write_payload "$REAL" "$REAL/shared.txt" | bash "$HOOK")
is_warn "$OUT" || { echo "FAIL: control positivo (misma carpeta) no aviso: $OUT"; exit 1; }
peer_with_file "$REPO" "peer" "$OTHERREAL" "$REAL/shared.txt" 30
OUT=$(write_payload "$REAL" "$REAL/shared.txt" | bash "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: peer en otra carpeta no debe avisar: $OUT"; exit 1; }
echo "PASS: peer en carpeta distinta no avisa (con control positivo)"
rm -rf "$REPO" "$OTHER"

# --- 4. control positivo (registro reciente -> avisa); luego SOLO la antiguedad
#        cambia -> silencio, tanto para un registro VIEJO (>900s) como para uno
#        con 'ts' en el FUTURO (reloj adelantado; 'ago' seria negativo). Las dos
#        variantes de silencio cuelgan del MISMO control positivo: un silencio
#        aislado sin control (como el de la version anterior de este archivo)
#        no distingue "correctamente silencioso" de "la regla no corre".
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
peer_with_file "$REPO" "peer" "$REAL" "$REAL/shared.txt" 30
OUT=$(write_payload "$REAL" "$REAL/shared.txt" | bash "$HOOK")
is_warn "$OUT" || { echo "FAIL: control positivo (registro reciente) no aviso: $OUT"; exit 1; }
peer_with_file "$REPO" "peer" "$REAL" "$REAL/shared.txt" 1200
OUT=$(write_payload "$REAL" "$REAL/shared.txt" | bash "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: un registro de archivo viejo no debe avisar: $OUT"; exit 1; }
peer_with_file "$REPO" "peer" "$REAL" "$REAL/shared.txt" -600
OUT=$(write_payload "$REAL" "$REAL/shared.txt" | bash "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: un registro con ts futuro no debe avisar (ago negativo): $OUT"; exit 1; }
echo "PASS: registro de archivo viejo o con ts futuro se ignora (con control positivo)"
rm -rf "$REPO"

# --- 5. control positivo (peer presente -> avisa), luego SOLO se quita el peer -> silencio ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
peer_with_file "$REPO" "peer" "$REAL" "$REAL/shared.txt" 30
OUT=$(write_payload "$REAL" "$REAL/shared.txt" | bash "$HOOK")
is_warn "$OUT" || { echo "FAIL: control positivo (peer presente) no aviso: $OUT"; exit 1; }
rm -f "$REPO/.git/slate-sessions/peer.lock"
OUT=$(write_payload "$REAL" "$REAL/shared.txt" | bash "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: sesion sola no debe producir output: $OUT"; exit 1; }
echo "PASS: sesion sola no avisa (con control positivo)"
rm -rf "$REPO"

# --- 6. dos peers coinciden en el MISMO archivo: el FRESCO decide a quien nombrar ---
# Analogo a la prueba 9 de test-guardian-tree-ops.sh (fix round 1, item 2): se
# prueban las DOS asignaciones de edad posibles entre estos dos nombres para no
# depender del orden que devuelva glob.glob() en ninguna maquina. Antes ganaba
# el primer peer en orden de archivo, no el mas reciente -- invertia la senal
# de urgencia que es la razon de ser del aviso.
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
peer_with_file "$REPO" "aaaaaaaa1111" "$REAL" "$REAL/shared.txt" 800
peer_with_file "$REPO" "zzzzzzzz9999" "$REAL" "$REAL/shared.txt" 5
OUT=$(write_payload "$REAL" "$REAL/shared.txt" | bash "$HOOK")
echo "$OUT" | grep -q "candado zzzzzzzz" || { echo "FAIL: (aaaaaaaa1111 800s, zzzzzzzz9999 5s) debio nombrar al fresco zzzzzzzz9999: $OUT"; exit 1; }
rm -rf "$REPO"

REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
peer_with_file "$REPO" "aaaaaaaa1111" "$REAL" "$REAL/shared.txt" 5
peer_with_file "$REPO" "zzzzzzzz9999" "$REAL" "$REAL/shared.txt" 800
OUT=$(write_payload "$REAL" "$REAL/shared.txt" | bash "$HOOK")
echo "$OUT" | grep -q "candado aaaaaaaa" || { echo "FAIL: (aaaaaaaa1111 5s, zzzzzzzz9999 800s) debio nombrar al fresco aaaaaaaa1111: $OUT"; exit 1; }
echo "PASS: el peer mas fresco es nombrado en el aviso bajo las dos asignaciones de edad posibles (no depende del orden de archivos)"
rm -rf "$REPO"

# --- 7. mismo archivo por ruta FISICA (symlink) aunque el string crudo difiera -> AVISA ---
# El peer registro su escritura via una ruta simbolica; esta sesion referencia
# el mismo archivo por la ruta real. Deben coincidir por realpath, no por texto.
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
mkdir -p "$REAL/real-dir"
ln -s "$REAL/real-dir" "$REAL/link-dir"
touch "$REAL/real-dir/shared.txt"
peer_with_file "$REPO" "peer" "$REAL" "$REAL/link-dir/shared.txt" 30
OUT=$(write_payload "$REAL" "$REAL/real-dir/shared.txt" | bash "$HOOK")
is_warn "$OUT" || { echo "FAIL: mismo archivo por ruta fisica (via symlink) no aviso: $OUT"; exit 1; }
echo "PASS: el mismo archivo por ruta fisica avisa aunque el string crudo difiera (symlink)"
rm -rf "$REPO"

echo "All guardian shared-file tests passed."
