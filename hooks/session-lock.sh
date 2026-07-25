#!/usr/bin/env bash
# SessionStart hook: session-lock guardian, layer 1.
# Detects if another LIVE session already claims this branch; if so,
# isolates this session into a dedicated git worktree + branch.
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

CURRENT_BRANCH="$(git branch --show-current 2>/dev/null)"
[ -z "$CURRENT_BRANCH" ] && exit 0   # detached HEAD: nothing to protect

TTL_SECONDS=900
NOW=$(date +%s)

COLLISION=0
for lock in "$LOCK_DIR"/*.lock; do
  [ -e "$lock" ] || continue
  LOCK_SESSION_ID="$(basename "$lock" .lock)"
  [ "$LOCK_SESSION_ID" = "$SESSION_ID" ] && continue

  MTIME=$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo 0)
  AGE=$((NOW - MTIME))
  [ "$AGE" -gt "$TTL_SECONDS" ] && continue   # stale, ignore

  LOCK_BRANCH=$(python3 -c "import json
try:
    print(json.load(open('$lock')).get('branch',''))
except Exception:
    print('')" 2>/dev/null || true)

  if [ "$LOCK_BRANCH" = "$CURRENT_BRANCH" ]; then
    COLLISION=1
    break
  fi
done

CONTEXT=""
LOCK_BRANCH_OUT="$CURRENT_BRANCH"
WT_OUT=""
HEAD_OUT="$(git rev-parse HEAD 2>/dev/null || true)"

if [ "$COLLISION" -eq 1 ]; then
  SHORT_ID="${SESSION_ID:0:8}"
  NEW_BRANCH="slate-session/${SHORT_ID}"
  PARENT_DIR="$(dirname "$PROJECT_ROOT")"
  BASE_NAME="$(basename "$PROJECT_ROOT")"
  WT_PATH="${PARENT_DIR}/${BASE_NAME}.slate-worktrees/${SHORT_ID}"

  mkdir -p "$(dirname "$WT_PATH")" 2>/dev/null
  if git worktree add "$WT_PATH" -b "$NEW_BRANCH" "$CURRENT_BRANCH" >/dev/null 2>&1; then
    LOCK_BRANCH_OUT="$NEW_BRANCH"
    WT_OUT="$WT_PATH"
    HEAD_OUT="$(git -C "$WT_PATH" rev-parse HEAD 2>/dev/null || echo "$HEAD_OUT")"
    CONTEXT="Otra sesion de Claude Code ya esta activa en la rama '${CURRENT_BRANCH}' de este repo. Para no pisarle la rama, el indice de git, ni el stash, esta sesion quedo aislada en una copia separada del repo:

  ${WT_PATH}  (rama: ${NEW_BRANCH})

A partir de ahora, para CUALQUIER comando git (branch, commit, push, stash, etc.) usa esa carpeta: cd ${WT_PATH} && git ... No operes sobre ${PROJECT_ROOT} hasta que la otra sesion termine."
  else
    CONTEXT="AVISO: otra sesion ya esta activa en la rama '${CURRENT_BRANCH}' y no pude aislar esta sesion en un worktree separado (fallo 'git worktree add'). Tene cuidado: pueden pisarse la rama, el indice o el stash."
  fi
fi

# Ruta FISICA de la carpeta de trabajo. El hook ya hizo `cd "$PROJECT_ROOT"` al
# arrancar, asi que `pwd -P` es la raiz del proyecto con symlinks resueltos
# (en macOS /var -> /private/var). El guardian compara carpetas por esta ruta.
CWD_OUT="$(pwd -P)"

python3 -c "import json,sys
data = {'branch': sys.argv[1], 'worktree': sys.argv[2], 'head': sys.argv[3],
        'started_at': sys.argv[4], 'cwd': sys.argv[5], 'files': []}
json.dump(data, open(sys.argv[6], 'w'))
" "$LOCK_BRANCH_OUT" "$WT_OUT" "$HEAD_OUT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CWD_OUT" "$LOCK_DIR/$SESSION_ID.lock" 2>/dev/null || true

if [ -n "$CONTEXT" ]; then
  python3 -c "import json,sys
print(json.dumps({'hookSpecificOutput': {'hookEventName': 'SessionStart', 'additionalContext': sys.argv[1]}}))
" "$CONTEXT" 2>/dev/null
fi
exit 0
