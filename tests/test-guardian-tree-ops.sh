#!/usr/bin/env bash
# El guardian debe denegar las operaciones que reescriben el arbol de trabajo
# cuando un peer VIVO comparte la MISMA carpeta. En carpetas distintas no
# interfiere. Con un lock envejecido, avisa en vez de bloquear.
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

payload() {
  # $1=session_id $2=cwd $3=command
  python3 -c "import json,sys; print(json.dumps({'session_id': sys.argv[1], 'cwd': sys.argv[2], 'tool_name': 'Bash', 'tool_input': {'command': sys.argv[3]}}))" "$1" "$2" "$3"
}

write_peer_lock() {
  # $1=repo $2=lockname $3=cwd_del_peer
  mkdir -p "$1/.git/slate-sessions"
  python3 -c "import json,sys; json.dump({'branch':'main','cwd':sys.argv[2],'worktree':'','head':'','started_at':'2026-01-01T00:00:00Z','files':[]}, open(sys.argv[1],'w'))" \
    "$1/.git/slate-sessions/$2.lock" "$3"
}

age_lock() {
  # $1=ruta del lock  $2=segundos de antiguedad
  python3 -c "import os,sys,time; p=sys.argv[1]; t=time.time()-float(sys.argv[2]); os.utime(p,(t,t))" "$1" "$2"
}

write_peer_lock_rawcwd() {
  # $1=repo $2=lockname $3=JSON literal para el valor de "cwd" (p.ej. 12345, no string)
  mkdir -p "$1/.git/slate-sessions"
  python3 -c "
import json, sys
d = {'branch': 'main', 'worktree': '', 'head': '', 'started_at': '2026-01-01T00:00:00Z', 'files': []}
d['cwd'] = json.loads(sys.argv[2])
json.dump(d, open(sys.argv[1], 'w'))
" "$1/.git/slate-sessions/$2.lock" "$3"
}

is_deny() { echo "$1" | grep -q '"permissionDecision": "deny"'; }
is_warn() { echo "$1" | grep -q '"additionalContext"'; }

# --- 1. peer fresco en la MISMA carpeta -> checkout DENEGADO ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
write_peer_lock "$REPO" "peer" "$REAL"
OUT=$(payload "yo" "$REAL" "git checkout -b otra" | bash "$HOOK")
is_deny "$OUT" || { echo "FAIL: checkout con peer fresco en la misma carpeta no fue denegado: $OUT"; exit 1; }
echo "PASS: checkout denegado con peer vivo en la misma carpeta"
rm -rf "$REPO"

# --- 2. mismos verbos: switch y restore tambien denegados ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
write_peer_lock "$REPO" "peer" "$REAL"
for CMD in "git switch main" "git restore ."; do
  OUT=$(payload "yo" "$REAL" "$CMD" | bash "$HOOK")
  is_deny "$OUT" || { echo "FAIL: '$CMD' no fue denegado: $OUT"; exit 1; }
done
echo "PASS: switch y restore tambien denegados"
rm -rf "$REPO"

# --- 3. reset --hard denegado; reset --soft NO ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
write_peer_lock "$REPO" "peer" "$REAL"
OUT=$(payload "yo" "$REAL" "git reset --hard HEAD~1" | bash "$HOOK")
is_deny "$OUT" || { echo "FAIL: 'reset --hard' no fue denegado: $OUT"; exit 1; }
OUT=$(payload "yo" "$REAL" "git reset --soft HEAD~1" | bash "$HOOK")
is_deny "$OUT" && { echo "FAIL: 'reset --soft' no toca el arbol y no debe denegarse: $OUT"; exit 1; }
echo "PASS: reset --hard denegado, reset --soft permitido"
rm -rf "$REPO"

# --- 4. peer en OTRA carpeta -> no interfiere ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
OTHER=$(mktemp -d)
write_peer_lock "$REPO" "peer" "$(cd "$OTHER" && pwd -P)"
OUT=$(payload "yo" "$REAL" "git checkout -b otra" | bash "$HOOK")
is_deny "$OUT" && { echo "FAIL: peer en otra carpeta no debe bloquear: $OUT"; exit 1; }
echo "PASS: peer en carpeta distinta no interfiere"
rm -rf "$REPO" "$OTHER"

# --- 5. sesion sola -> nunca se bloquea ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
OUT=$(payload "yo" "$REAL" "git checkout -b otra" | bash "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: sesion sola produjo output: $OUT"; exit 1; }
echo "PASS: una sesion sola nunca se bloquea"
rm -rf "$REPO"

# --- 6. peer TIBIO (>300s, <900s) -> avisa, no bloquea ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
write_peer_lock "$REPO" "peer" "$REAL"
age_lock "$REPO/.git/slate-sessions/peer.lock" 600
OUT=$(payload "yo" "$REAL" "git checkout -b otra" | bash "$HOOK")
is_deny "$OUT" && { echo "FAIL: peer tibio (600s) no debe denegar: $OUT"; exit 1; }
is_warn "$OUT" || { echo "FAIL: peer tibio (600s) debe avisar: $OUT"; exit 1; }
echo "PASS: peer tibio avisa sin bloquear"
rm -rf "$REPO"

# --- 7. peer RANCIO (>900s) -> ignorado por completo ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
write_peer_lock "$REPO" "peer" "$REAL"
age_lock "$REPO/.git/slate-sessions/peer.lock" 1200
OUT=$(payload "yo" "$REAL" "git checkout -b otra" | bash "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: peer rancio (1200s) debe ignorarse: $OUT"; exit 1; }
echo "PASS: peer rancio se ignora"
rm -rf "$REPO"

# --- 8. lock legado sin cwd -> se ignora para esta regla, nunca rompe ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
mkdir -p "$REPO/.git/slate-sessions"
echo '{"branch": "main", "worktree": "", "started_at": "2026-01-01T00:00:00Z"}' \
  > "$REPO/.git/slate-sessions/legacy.lock"
OUT=$(payload "yo" "$REAL" "git checkout -b otra" | bash "$HOOK")
is_deny "$OUT" && { echo "FAIL: un lock sin cwd no debe denegar: $OUT"; exit 1; }
echo "PASS: lock legado sin cwd se ignora sin romper"
rm -rf "$REPO"

# --- 9. dos peers en la MISMA carpeta: el FRESCO decide, no el primero en orden ---
# Verificado empiricamente para este par de nombres dentro de .git/slate-sessions:
# glob.glob devuelve "peer-z.lock" ANTES que "peer-a.lock" en este filesystem
# (orden interno del directorio, no alfabetico). Por eso "peer-z" lleva la edad
# TIBIA y "peer-a" la FRESCA: un guardian que se quedara con el primer match
# (rompiendo el bucle ahi) encontraria a peer-z primero y avisaria en vez de
# denegar, aunque peer-a -verdaderamente vivo- este justo al lado. Confirmado
# contra el codigo previo a este arreglo: efectivamente solo avisaba.
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
write_peer_lock "$REPO" "peer-z" "$REAL"
write_peer_lock "$REPO" "peer-a" "$REAL"
age_lock "$REPO/.git/slate-sessions/peer-z.lock" 600
age_lock "$REPO/.git/slate-sessions/peer-a.lock" 10
OUT=$(payload "yo" "$REAL" "git checkout -b otra" | bash "$HOOK")
is_deny "$OUT" || { echo "FAIL: con un peer fresco (10s) y uno tibio (600s) en la misma carpeta, debe denegar sin importar el orden de archivos: $OUT"; exit 1; }
echo "PASS: el peer mas fresco decide el veredicto, no el primero en orden de archivos"
rm -rf "$REPO"

# --- 10. cwd de tipo no-string en el lock -> se ignora, nunca rompe ni deniega ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
write_peer_lock_rawcwd "$REPO" "peer" "12345"
ERRFILE=$(mktemp)
OUT=$(payload "yo" "$REAL" "git checkout -b otra" | bash "$HOOK" 2>"$ERRFILE")
is_deny "$OUT" && { echo "FAIL: un cwd no-string no debe denegar: $OUT"; rm -f "$ERRFILE"; exit 1; }
[ -s "$ERRFILE" ] && { echo "FAIL: un cwd no-string no debe lanzar una excepcion (stderr no vacio): $(cat "$ERRFILE")"; rm -f "$ERRFILE"; exit 1; }
rm -f "$ERRFILE"
echo "PASS: un cwd de tipo no-string se ignora sin romper el hook"
rm -rf "$REPO"

# --- 11. git -C <otro-repo> checkout con un peer en ESTA carpeta -> no interfiere ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
OTHER=$(mktemp -d)
write_peer_lock "$REPO" "peer" "$REAL"
OUT=$(payload "yo" "$REAL" "git -C $OTHER checkout -b otra" | bash "$HOOK")
is_deny "$OUT" && { echo "FAIL: un checkout con -C hacia OTRO repo no debe denegarse aunque haya un peer vivo en mi carpeta: $OUT"; exit 1; }
echo "PASS: 'git -C <otro-repo> checkout' no interfiere con un peer de esta carpeta"
rm -rf "$REPO" "$OTHER"

# --- 12. reset --merge y reset --keep tambien denegados; --mixed permitido ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
write_peer_lock "$REPO" "peer" "$REAL"
for CMD in "git reset --merge HEAD~1" "git reset --keep HEAD~1"; do
  OUT=$(payload "yo" "$REAL" "$CMD" | bash "$HOOK")
  is_deny "$OUT" || { echo "FAIL: '$CMD' no fue denegado: $OUT"; exit 1; }
done
OUT=$(payload "yo" "$REAL" "git reset --mixed HEAD~1" | bash "$HOOK")
is_deny "$OUT" && { echo "FAIL: 'reset --mixed' no toca el arbol y no debe denegarse: $OUT"; exit 1; }
echo "PASS: reset --merge y --keep denegados, --mixed permitido"
rm -rf "$REPO"

echo "All guardian tree-op tests passed."
