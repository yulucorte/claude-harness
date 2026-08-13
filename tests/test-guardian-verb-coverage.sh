#!/usr/bin/env bash
# Tabla de veredictos del conjunto de verbos destructivos del guardian.
#
# Fija QUE se vigila y QUE no, en un solo sitio y de forma legible. La revision
# final de la rama encontro que 'pull', 'clean -f' y 'stash' pasaban en silencio
# (o solo con aviso) con un peer vivo en la MISMA carpeta, pese a ser los unicos
# comandos que git NO protege por si mismo: git se niega a un checkout/merge que
# pisaria archivos modificados, pero 'clean -f' y 'stash' destruyen sin
# preguntar. Y un agente al que se le acaba de denegar un checkout tira de
# 'git stash'.
#
# Los casos SILENCIOSOS de esta tabla ('revert', 'am', 'apply', 'rm -r') no son
# un olvido: son el limite conocido documentado en CHANGELOG.md y en la spec.
# Estan aqui para que dejen de ser invisibles y para que cambiarlos sea una
# decision, no un accidente.
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
  python3 -c "import os,sys,time; p=sys.argv[1]; t=time.time()-float(sys.argv[2]); os.utime(p,(t,t))" "$1" "$2"
}

is_deny() { echo "$1" | grep -q '"permissionDecision": "deny"'; }
is_warn() { echo "$1" | grep -q '"additionalContext"'; }

# check <cwd> <comando> <veredicto esperado: deny|warn|quiet> [subcadena obligatoria]
#   deny  = permissionDecision deny
#   warn  = additionalContext y NO deny
#   quiet = sin salida alguna
# La subcadena opcional se exige dentro del mensaje: un veredicto correcto con el
# motivo equivocado deja al agente sin ruta a un comando valido, que es la mitad
# del trabajo de una denegacion.
check() {
  local cwd="$1" cmd="$2" want="$3" needle="${4:-}" out errfile
  errfile=$(mktemp)
  out=$(payload "yo" "$cwd" "$cmd" | bash "$HOOK" 2>"$errfile")
  if [ -s "$errfile" ]; then
    echo "FAIL: '$cmd' escribio en stderr (excepcion): $(cat "$errfile")"; rm -f "$errfile"; exit 1
  fi
  rm -f "$errfile"
  case "$want" in
    deny)
      is_deny "$out" || { echo "FAIL: '$cmd' esperaba DENY, obtuvo: '${out:-<vacio>}'"; exit 1; } ;;
    warn)
      is_deny "$out" && { echo "FAIL: '$cmd' esperaba AVISO, obtuvo DENY: $out"; exit 1; }
      is_warn "$out" || { echo "FAIL: '$cmd' esperaba AVISO, obtuvo: '${out:-<vacio>}'"; exit 1; } ;;
    quiet)
      [ -z "$out" ] || { echo "FAIL: '$cmd' esperaba SILENCIO, obtuvo: $out"; exit 1; } ;;
    *) echo "FAIL: veredicto desconocido '$want'"; exit 1 ;;
  esac
  if [ -n "$needle" ]; then
    echo "$out" | grep -qF "$needle" \
      || { echo "FAIL: '$cmd' dio el veredicto correcto pero el motivo no menciona '$needle': $out"; exit 1; }
  fi
  echo "  ok  $want  <- $cmd${needle:+  (motivo menciona: $needle)}"
}

# =====================================================================
# Bloque A — peer VIVO (fresco) en la MISMA carpeta
# =====================================================================
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
write_peer_lock "$REPO" "peer" "$REAL"

echo "Bloque A: peer fresco en la misma carpeta"
# control positivo: si esto no deniega, el resto de la tabla no prueba nada
check "$REAL" "git checkout main"          deny
# --- reescriben el arbol y git NO los frena por si mismo ---
check "$REAL" "git pull"                   deny
check "$REAL" "git pull --rebase"          deny
check "$REAL" "git pull origin main"       deny
check "$REAL" "git clean -f"               deny
check "$REAL" "git clean -fd"              deny
check "$REAL" "git clean -fdx"             deny
check "$REAL" "git clean --force"          deny
check "$REAL" "git clean -xdf"             deny
# --- clean sin fuerza: git se niega por si mismo, no hay nada que vigilar ---
check "$REAL" "git clean -n"               quiet
check "$REAL" "git clean -nd"              quiet
check "$REAL" "git clean"                  quiet
# --- stash: las formas destructivas por la via graduada de los tree-ops ---
check "$REAL" "git stash"                  deny
check "$REAL" "git stash push -m x"        deny
check "$REAL" "git stash -u"               deny
check "$REAL" "git stash save wip"         deny
check "$REAL" "git stash pop"              deny
check "$REAL" "git stash apply"            deny
check "$REAL" "git stash drop"             deny
check "$REAL" "git stash clear"            deny
# --- stash de solo lectura y con referencia explicita: trato intacto ---
check "$REAL" "git stash list"             quiet
check "$REAL" "git stash show"             quiet
check "$REAL" "git stash pop stash@{0}"    quiet
check "$REAL" "git stash apply stash@{1}"  quiet
# --- limites conocidos declarados: NO se vigilan (ver CHANGELOG y spec) ---
check "$REAL" "git revert HEAD"            quiet
check "$REAL" "git am /tmp/x.patch"        quiet
check "$REAL" "git apply /tmp/x.patch"     quiet
check "$REAL" "git rm -r subdir"           quiet
rm -rf "$REPO"

# =====================================================================
# Bloque B — sesion SOLA: ningun verbo se bloquea nunca
# =====================================================================
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
echo "Bloque B: sesion sola"
for CMD in "git checkout main" "git pull" "git clean -fd" "git stash" "git stash pop"; do
  check "$REAL" "$CMD" quiet
done
rm -rf "$REPO"

# =====================================================================
# Bloque C — peer vivo en OTRA carpeta: la regla 0 no aplica,
#            pero la regla 3 (stash compartido por todo el repo) SI
# =====================================================================
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
OTHER=$(mktemp -d)
write_peer_lock "$REPO" "peer" "$(cd "$OTHER" && pwd -P)"
echo "Bloque C: peer vivo en otra carpeta"
check "$REAL" "git checkout main"   quiet
check "$REAL" "git pull"            quiet
check "$REAL" "git clean -fd"       quiet
# el stash es del REPO entero (incluidos los worktrees): trato previo intacto
check "$REAL" "git stash"           warn
check "$REAL" "git stash pop"       deny  "compartido por todo el repo"
check "$REAL" "git stash apply"     deny  "compartido por todo el repo"
check "$REAL" "git stash list"      quiet
rm -rf "$REPO" "$OTHER"

# =====================================================================
# Bloque D — peer envejecido pero dentro del TTL (900s) en la misma carpeta:
# desde 1.9.0 FRESH == TTL, asi que ya no hay banda tibia -- deniega igual
# que un peer recien creado (bloque A).
# =====================================================================
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
write_peer_lock "$REPO" "peer" "$REAL"
age_lock "$REPO/.git/slate-sessions/peer.lock" 600
echo "Bloque D: peer con 600s de antiguedad (dentro del TTL) en la misma carpeta"
check "$REAL" "git checkout main"  deny
check "$REAL" "git pull"           deny
check "$REAL" "git clean -fd"      deny
check "$REAL" "git stash"          deny
# pop/apply (sin ref explicita) son formas DESTRUCTIVAS del stash, asi que
# tambien cuentan como tree-op: la regla 0 ya deniega por reescritura del
# arbol y la regla 3 se calla para no duplicar el mensaje (mismo trato que
# el bloque A con un peer fresco). drop/clear NO son tree-op -- los deniega
# solo la regla 3, con su motivo propio de "cajon compartido".
check "$REAL" "git stash pop"      deny
check "$REAL" "git stash apply"    deny
check "$REAL" "git stash drop"     deny  "cajon compartido"
check "$REAL" "git stash clear"    deny  "cajon compartido"
# Y la banda tibia tampoco endurece lo que nunca se vigilo
check "$REAL" "git stash pop stash@{0}"   quiet
check "$REAL" "git stash apply stash@{1}" quiet
check "$REAL" "git stash list"     quiet
check "$REAL" "git stash show"     quiet
rm -rf "$REPO"

echo "All guardian verb-coverage tests passed."
