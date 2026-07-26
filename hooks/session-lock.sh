#!/usr/bin/env bash
# SessionStart hook: session-lock guardian, layer 1.
# Detects a live peer session already on this branch and emits an
# actionable warning (additionalContext) — it never creates a worktree or
# branch for isolation. Enforcement (denying the dangerous git ops) is
# session-guardian's job.
# Never blocks a session start — always exits 0.
set -uo pipefail

PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-$(pwd)}"
cd "$PROJECT_ROOT" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null)"
[ -z "$GIT_COMMON_DIR" ] && exit 0
case "$GIT_COMMON_DIR" in
  /*) : ;;
  *) GIT_COMMON_DIR="$PROJECT_ROOT/$GIT_COMMON_DIR" ;;
esac
# Resolve symlinks (e.g. macOS /var -> /private/var) so every worktree of
# the same repo computes the identical physical path to the shared lock dir.
GIT_COMMON_DIR="$(cd "$GIT_COMMON_DIR" 2>/dev/null && pwd -P)"
[ -z "$GIT_COMMON_DIR" ] && exit 0

LOCK_DIR="$GIT_COMMON_DIR/slate-sessions"
mkdir -p "$LOCK_DIR" 2>/dev/null || exit 0

STDIN_JSON=""
if [ ! -t 0 ]; then
  STDIN_JSON=$(cat 2>/dev/null || true)
fi
SESSION_ID=$(printf '%s' "$STDIN_JSON" | python3 -c "import sys,json
try:
    print((json.load(sys.stdin).get('session_id') or '').strip())
except Exception:
    print('')" 2>/dev/null || true)
[ -z "$SESSION_ID" ] && exit 0

# Puede venir VACIA (HEAD desprendido: 'git checkout <sha>', un rebase o un
# bisect en curso). Eso ya NO es motivo para no registrarse: desde 1.7.0 el
# candado identifica la CARPETA fisica de trabajo, no una rama, y el arbol de
# trabajo de una sesion desprendida se destruye igual que cualquier otro. Sin
# candado esa sesion es invisible para el guardian y el 'git checkout' de un
# peer se permitia en silencio por encima de ella. Se registra siempre, con
# branch:"" cuando no hay rama.
CURRENT_BRANCH="$(git branch --show-current 2>/dev/null)"

TTL_SECONDS=900
NOW=$(date +%s)

# Purge expired locks BEFORE looking for collisions. Sessions that die without
# SessionEnd (crash, closed window) used to leave their lock forever: readers
# skipped it via TTL but nobody deleted it, so the directory only grew. Reaping
# here also means a session that starts right after a crash sees a clean slate
# instead of announcing a peer that no longer exists.
find "$LOCK_DIR" -maxdepth 1 -name '*.lock' -type f -mmin +15 -delete 2>/dev/null || true

COLLISION=0
for lock in "$LOCK_DIR"/*.lock; do
  [ -e "$lock" ] || continue
  LOCK_SESSION_ID="$(basename "$lock" .lock)"
  [ "$LOCK_SESSION_ID" = "$SESSION_ID" ] && continue

  MTIME=$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo 0)
  AGE=$((NOW - MTIME))
  [ "$AGE" -gt "$TTL_SECONDS" ] && continue   # stale, ignore

  # La ruta va por argv, NO interpolada en el fuente: un repo cuya ruta lleve
  # un apostrofo ("/Users/x/O'Brien/repo") rompia el parseo de python.
  LOCK_BRANCH=$(python3 -c "import json,sys
try:
    print(json.load(open(sys.argv[1])).get('branch',''))
except Exception:
    print('')" "$lock" 2>/dev/null || true)

  # Dos ramas VACIAS no son la misma rama: son dos sesiones con HEAD
  # desprendido, que no comparten reclamacion alguna. Sin esta guarda
  # colisionarian entre si por "" == "".
  if [ -n "$CURRENT_BRANCH" ] && [ "$LOCK_BRANCH" = "$CURRENT_BRANCH" ]; then
    COLLISION=1
    break
  fi
done

CONTEXT=""
LOCK_BRANCH_OUT="$CURRENT_BRANCH"
WT_OUT=""
HEAD_OUT="$(git rev-parse HEAD 2>/dev/null || true)"

# Aviso informativo, sin efectos en disco.
#
# Hasta 1.6.1 este bloque creaba una worktree dedicada y le pedia al agente que
# se mudara. No funciona: un hook SessionStart no puede cambiar el directorio de
# trabajo de una sesion ya arrancada, y la peticion compite (y pierde) contra el
# resto del contexto del agente. Verificado en vivo: las worktrees generadas asi
# quedaron siempre vacias. El mecanismo pagaba el costo (carpetas acumuladas)
# sin dar el beneficio (aislamiento). La proteccion real la aplica ahora
# session-guardian, denegando las operaciones que reescriben el arbol.
if [ "$COLLISION" -eq 1 ]; then
  CONTEXT="Otra sesion de Claude Code ya esta activa en la rama '${CURRENT_BRANCH}' de esta misma carpeta:

  ${PROJECT_ROOT}

NO reescribas el arbol de trabajo mientras dure. session-guardian bloqueara estas operaciones, que reescriben o borran en disco los archivos que la otra sesion esta editando sin que su agente se entere:

  git checkout / git switch / git restore
  git reset --hard | --merge | --keep   ('--soft' y '--mixed' son seguros)
  git pull   (fetch + merge/rebase sobre el arbol de trabajo)
  git clean -f / -fd / -fdx   (borra archivos sin seguimiento del otro agente)
  git stash / git stash push / git stash -u   (guarda y REVIERTE el arbol)
  git stash pop / apply sin una referencia stash@{n} explicita

Editar archivos distintos sobre la rama actual es seguro. Si necesitas trabajar en OTRA rama en paralelo, abre una sesion de Claude Code NUEVA en otra carpeta: el aislamiento solo funciona si la sesion arranca alli, no si se le pide mudarse."
fi

# Ruta FISICA de la carpeta de trabajo. El hook ya hizo `cd "$PROJECT_ROOT"` al
# arrancar, asi que `pwd -P` es la raiz del proyecto con symlinks resueltos
# (en macOS /var -> /private/var). El guardian compara carpetas por esta ruta.
CWD_OUT="$(pwd -P)"

python3 -c "import json,sys
# SessionStart se re-dispara con el MISMO session_id en compact/clear/resume
# (ver hooks.json: matcher startup|resume|clear|compact). Si el lock ya existia
# y ya traia una lista 'files' (la va acumulando el heartbeat en la Task 4), la
# conservamos; si no existe, es ilegible, esta corrupto, o 'files' no es una
# lista, degradamos en silencio a [] (lock nuevo).
import os
files = []
try:
    prev = json.load(open(sys.argv[6]))
    if isinstance(prev, dict) and isinstance(prev.get('files'), list):
        files = prev['files']
except Exception:
    pass
data = {'branch': sys.argv[1], 'worktree': sys.argv[2], 'head': sys.argv[3],
        'started_at': sys.argv[4], 'cwd': sys.argv[5], 'files': files}
# Escritura ATOMICA (temporal + rename), identica a la de session-heartbeat.sh.
# Truncar el lock en sitio abria una ventana en la que el guardian lo leia a
# medias, lo descartaba por ilegible y dejaba de VER a esta sesion: un peer
# podia entonces hacer 'git checkout' encima sin ser bloqueado. Y SessionStart
# se re-dispara en startup|resume|clear|compact, asi que la ventana volvia una
# y otra vez. Con rename, o esta el lock viejo entero o el nuevo entero.
tmp = sys.argv[6] + '.tmp'
try:
    json.dump(data, open(tmp, 'w'))
    os.replace(tmp, sys.argv[6])
except Exception:
    try:
        os.remove(tmp)
    except OSError:
        pass
" "$LOCK_BRANCH_OUT" "$WT_OUT" "$HEAD_OUT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CWD_OUT" "$LOCK_DIR/$SESSION_ID.lock" 2>/dev/null || true

if [ -n "$CONTEXT" ]; then
  python3 -c "import json,sys
print(json.dumps({'hookSpecificOutput': {'hookEventName': 'SessionStart', 'additionalContext': sys.argv[1]}}))
" "$CONTEXT" 2>/dev/null
fi
exit 0
