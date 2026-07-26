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

# NOTA (1.8.0): el tree-op canonico de este fichero paso de
# 'git checkout -b X' a 'git checkout X'. Crear una rama sin punto de
# partida no reescribe el arbol de trabajo y desde 1.8.0 se permite; lo
# que aqui se prueba es la RESOLUCION DE CARPETAS, no el verbo.
# La cobertura de verbos vive en test-guardian-false-positives.sh.

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
OUT=$(payload "yo" "$REAL" "git checkout otra" | bash "$HOOK")
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
OUT=$(payload "yo" "$REAL" "git checkout otra" | bash "$HOOK")
is_deny "$OUT" && { echo "FAIL: peer en otra carpeta no debe bloquear: $OUT"; exit 1; }
echo "PASS: peer en carpeta distinta no interfiere"
rm -rf "$REPO" "$OTHER"

# --- 5. sesion sola -> nunca se bloquea ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
OUT=$(payload "yo" "$REAL" "git checkout otra" | bash "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: sesion sola produjo output: $OUT"; exit 1; }
echo "PASS: una sesion sola nunca se bloquea"
rm -rf "$REPO"

# --- 6. peer TIBIO (>300s, <900s) -> avisa, no bloquea ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
write_peer_lock "$REPO" "peer" "$REAL"
age_lock "$REPO/.git/slate-sessions/peer.lock" 600
OUT=$(payload "yo" "$REAL" "git checkout otra" | bash "$HOOK")
is_deny "$OUT" && { echo "FAIL: peer tibio (600s) no debe denegar: $OUT"; exit 1; }
is_warn "$OUT" || { echo "FAIL: peer tibio (600s) debe avisar: $OUT"; exit 1; }
echo "PASS: peer tibio avisa sin bloquear"
rm -rf "$REPO"

# --- 7. peer RANCIO (>900s) -> ignorado por completo ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
write_peer_lock "$REPO" "peer" "$REAL"
age_lock "$REPO/.git/slate-sessions/peer.lock" 1200
OUT=$(payload "yo" "$REAL" "git checkout otra" | bash "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: peer rancio (1200s) debe ignorarse: $OUT"; exit 1; }
echo "PASS: peer rancio se ignora"
rm -rf "$REPO"

# --- 8. lock legado sin cwd -> se ignora para esta regla, nunca rompe ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
mkdir -p "$REPO/.git/slate-sessions"
echo '{"branch": "main", "worktree": "", "started_at": "2026-01-01T00:00:00Z"}' \
  > "$REPO/.git/slate-sessions/legacy.lock"
OUT=$(payload "yo" "$REAL" "git checkout otra" | bash "$HOOK")
is_deny "$OUT" && { echo "FAIL: un lock sin cwd no debe denegar: $OUT"; exit 1; }
echo "PASS: lock legado sin cwd se ignora sin romper"
rm -rf "$REPO"

# --- 9. dos peers en la MISMA carpeta: el FRESCO decide, no el primero en orden ---
# Independiente del filesystem: se prueban las DOS asignaciones de edad posibles
# entre estos dos nombres. glob.glob() puede devolver "peer-z.lock" antes que
# "peer-a.lock" o al reves segun la maquina (verificado no-alfabetico y estable
# en esta, pero NO se asume ese orden aqui) -- probando ambas asignaciones, al
# menos una de las dos ejercita de verdad "el fresco NO es el primero en orden
# de archivos" sin importar que orden devuelva glob.glob() en cualquier maquina.
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
write_peer_lock "$REPO" "peer-z" "$REAL"
write_peer_lock "$REPO" "peer-a" "$REAL"
age_lock "$REPO/.git/slate-sessions/peer-z.lock" 600
age_lock "$REPO/.git/slate-sessions/peer-a.lock" 10
OUT=$(payload "yo" "$REAL" "git checkout otra" | bash "$HOOK")
is_deny "$OUT" || { echo "FAIL: (peer-z tibio 600s, peer-a fresco 10s) debe denegar sin importar el orden de archivos: $OUT"; exit 1; }
rm -rf "$REPO"

REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
write_peer_lock "$REPO" "peer-z" "$REAL"
write_peer_lock "$REPO" "peer-a" "$REAL"
age_lock "$REPO/.git/slate-sessions/peer-z.lock" 10
age_lock "$REPO/.git/slate-sessions/peer-a.lock" 600
OUT=$(payload "yo" "$REAL" "git checkout otra" | bash "$HOOK")
is_deny "$OUT" || { echo "FAIL: (peer-z fresco 10s, peer-a tibio 600s) debe denegar sin importar el orden de archivos: $OUT"; exit 1; }
echo "PASS: el peer mas fresco decide el veredicto bajo las dos asignaciones de edad posibles (no depende del orden de archivos de ningun filesystem)"
rm -rf "$REPO"

# --- 10. cwd de tipo no-string en el lock -> se ignora, nunca rompe ni deniega ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
write_peer_lock_rawcwd "$REPO" "peer" "12345"
ERRFILE=$(mktemp)
OUT=$(payload "yo" "$REAL" "git checkout otra" | bash "$HOOK" 2>"$ERRFILE")
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
OUT=$(payload "yo" "$REAL" "git -C $OTHER checkout otra" | bash "$HOOK")
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

# --- 13. git -C <subcarpeta-de-ESTE-repo> checkout con peer en la RAIZ -> DENEGADO ---
# checkout/switch reescriben el arbol de trabajo COMPLETO sin importar la
# subcarpeta desde la que se invoquen (-C solo cambia donde git busca el repo,
# no el alcance de lo que toca). Un peer vivo en la raiz del repo sigue en
# riesgo aunque el comando se invoque via -C hacia una subcarpeta.
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
mkdir -p "$REPO/sub"
write_peer_lock "$REPO" "peer" "$REAL"
OUT=$(payload "yo" "$REAL" "git -C sub checkout otra" | bash "$HOOK")
is_deny "$OUT" || { echo "FAIL: 'git -C sub checkout' con un peer vivo en la RAIZ de este mismo repo no fue denegado: $OUT"; exit 1; }
echo "PASS: 'git -C <subcarpeta-de-este-repo> checkout' denegado con un peer en la raiz"
rm -rf "$REPO"

# --- 14. comando compuesto: el primer tree-op apunta a OTRO repo, el segundo es LOCAL -> DENEGADO ---
# El -C de un tree-op no debe decidir el objetivo de OTRO tree-op en el mismo
# comando. El primer operando tiene que ser un repo de verdad (no solo "/tmp"):
# en Linux 'mktemp -d' crea carpetas DENTRO de /tmp (p.ej. /tmp/tmp.XXXX), asi
# que "/tmp" contendria a $REPO y el caso pasaria por contencion sin ejercitar
# nada. Un segundo repo real de 'setup_repo' no puede contener a $REPO en
# NINGUNA plataforma. El segundo 'checkout' es local (sin -C) y SI colisiona.
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
OTHER=$(setup_repo)
write_peer_lock "$REPO" "peer" "$REAL"
OUT=$(payload "yo" "$REAL" "git -C $OTHER checkout x && git checkout y" | bash "$HOOK")
is_deny "$OUT" || { echo "FAIL: el segundo tree-op (local, sin -C) no fue denegado aunque el primero apuntara a otro repo: $OUT"; exit 1; }
echo "PASS: un tree-op local en un comando compuesto se denega aunque otro tree-op del mismo comando apunte a otro repo"
rm -rf "$REPO" "$OTHER"

# --- 15. peer en un worktree ENLAZADO anidado dentro del repo -> no interfiere (ninguna direccion) ---
# 'git worktree add' comparte .git/slate-sessions (mismo git-common-dir), asi
# que ese peer es visible para la regla -- pero tiene su PROPIA raiz de arbol
# de trabajo, distinta de la del repo principal aunque este anidado
# FISICAMENTE debajo (probado: un 'git checkout -b x' en la raiz deja
# intactos los archivos del worktree enlazado, y viceversa). Comparar por
# contencion de carpetas (ronda 2) los confundia con el mismo arbol y
# denegaba sin una colision real; comparar raices resueltas por igualdad
# ('rev-parse --show-toplevel') los distingue.
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
git -C "$REPO" worktree add -q -b wtbranch-15a wt
WT=$(cd "$REAL/wt" && pwd -P)

# 15a. sesion en la RAIZ, peer en el worktree enlazado anidado -> no interfiere
write_peer_lock "$REPO" "peer" "$WT"
OUT=$(payload "yo" "$REAL" "git checkout brandnew" | bash "$HOOK")
is_deny "$OUT" && { echo "FAIL: un peer en un worktree enlazado ANIDADO no debe bloquear un checkout en la raiz: $OUT"; exit 1; }
rm -f "$REPO/.git/slate-sessions/peer.lock"

# 15b. sesion en el worktree enlazado anidado, peer en la RAIZ -> tampoco interfiere
write_peer_lock "$REPO" "peer" "$REAL"
OUT=$(payload "yo" "$WT" "git checkout otramas" | bash "$HOOK")
is_deny "$OUT" && { echo "FAIL: un peer en la RAIZ no debe bloquear un checkout en un worktree enlazado ANIDADO: $OUT"; exit 1; }
echo "PASS: un peer en un worktree enlazado anidado no interfiere en ninguna direccion"
rm -rf "$REPO"

# --- 16. lock del PEER vacio / truncado / 'null' -> se ignora, nunca revienta ---
# El caso existente de "lock corrupto" (test-session-lock-records-cwd.sh) cubre
# el lock PROPIO en SessionStart, que es la ruta de codigo CONTRARIA: alli el
# hook REESCRIBE el lock; aqui el guardian LEE el de otro. Cada variante va
# precedida del mismo control positivo (lock intacto -> deny), para que el
# silencio signifique "el peer ilegible se descarta" y no "la regla no corre".
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
LOCKP="$REPO/.git/slate-sessions/peer.lock"
for VARIANT in vacio truncado null lista texto; do
  write_peer_lock "$REPO" "peer" "$REAL"
  OUT=$(payload "yo" "$REAL" "git checkout otra" | bash "$HOOK")
  is_deny "$OUT" || { echo "FAIL: control positivo (lock intacto) no denego antes de la variante '$VARIANT': $OUT"; exit 1; }

  case "$VARIANT" in
    vacio)    : > "$LOCKP" ;;
    truncado) printf '{"branch": "main", "cwd": "%s", "fil' "$REAL" > "$LOCKP" ;;
    null)     printf 'null' > "$LOCKP" ;;
    lista)    printf '[{"cwd": "%s"}]' "$REAL" > "$LOCKP" ;;
    texto)    printf 'no soy json' > "$LOCKP" ;;
  esac

  ERRFILE=$(mktemp)
  OUT=$(payload "yo" "$REAL" "git checkout otra" | bash "$HOOK" 2>"$ERRFILE")
  is_deny "$OUT" && { echo "FAIL: un lock de peer '$VARIANT' no debe denegar (nunca se deniega por falta de datos): $OUT"; rm -f "$ERRFILE"; exit 1; }
  [ -s "$ERRFILE" ] && { echo "FAIL: un lock de peer '$VARIANT' no debe lanzar excepcion (stderr no vacio): $(cat "$ERRFILE")"; rm -f "$ERRFILE"; exit 1; }
  rm -f "$ERRFILE"
done
echo "PASS: un lock de PEER vacio, truncado, null, lista o basura se descarta sin romper ni denegar (con control positivo antes de cada variante)"
rm -rf "$REPO"

# --- 17. un cwd de peer RELATIVO se descarta: resolverlo contra el directorio
#         del proceso del hook (no el del peer) puede inventar una colision ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
write_peer_lock "$REPO" "peer" "$REAL"
OUT=$(payload "yo" "$REAL" "git checkout otra" | bash "$HOOK")
is_deny "$OUT" || { echo "FAIL: control positivo (cwd absoluto) no denego: $OUT"; exit 1; }
write_peer_lock "$REPO" "peer" "."
ERRFILE=$(mktemp)
OUT=$(cd "$REAL" && payload "yo" "$REAL" "git checkout otra" | bash "$HOOK" 2>"$ERRFILE")
is_deny "$OUT" && { echo "FAIL: un cwd de peer relativo ('.') no debe denegar: $OUT"; rm -f "$ERRFILE"; exit 1; }
[ -s "$ERRFILE" ] && { echo "FAIL: un cwd de peer relativo no debe lanzar excepcion: $(cat "$ERRFILE")"; rm -f "$ERRFILE"; exit 1; }
rm -f "$ERRFILE"
echo "PASS: un cwd de peer relativo se descarta en vez de resolverse contra el proceso del hook (con control positivo)"
rm -rf "$REPO"

echo "All guardian tree-op tests passed."
