#!/usr/bin/env bash
# Cuando dos sesiones comparten carpeta y editan el MISMO archivo, el guardian
# avisa pero jamas bloquea: el choque de archivo es localizado y recuperable.
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
  # $1=repo $2=cwd_del_peer $3=file_path $4=antiguedad_en_s_del_registro
  mkdir -p "$1/.git/slate-sessions"
  python3 -c "
import json, sys, time
peer_cwd, fp, age = sys.argv[2], sys.argv[3], float(sys.argv[4])
json.dump({'branch':'main','cwd':peer_cwd,'worktree':'','head':'',
           'started_at':'2026-01-01T00:00:00Z',
           'files':[{'path': fp, 'ts': int(time.time() - age)}]},
          open(sys.argv[1],'w'))
" "$1/.git/slate-sessions/peer.lock" "$2" "$3" "$4"
}

is_deny() { echo "$1" | grep -q '"permissionDecision"'; }
is_warn() { echo "$1" | grep -q '"additionalContext"'; }

# --- 1. mismo archivo, misma carpeta, reciente -> AVISA sin bloquear ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
peer_with_file "$REPO" "$REAL" "$REAL/shared.txt" 30
OUT=$(write_payload "$REAL" "$REAL/shared.txt" | bash "$HOOK")
is_warn "$OUT" || { echo "FAIL: no aviso del archivo compartido: $OUT"; exit 1; }
is_deny "$OUT" && { echo "FAIL: un choque de archivo NUNCA debe bloquear: $OUT"; exit 1; }
echo "PASS: archivo compartido avisa y no bloquea"
rm -rf "$REPO"

# --- 2. archivo distinto -> silencio ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
peer_with_file "$REPO" "$REAL" "$REAL/otro.txt" 30
OUT=$(write_payload "$REAL" "$REAL/mio.txt" | bash "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: archivos distintos no deben producir output: $OUT"; exit 1; }
echo "PASS: archivos distintos no producen aviso"
rm -rf "$REPO"

# --- 3. mismo archivo pero peer en OTRA carpeta -> silencio ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
OTHER=$(mktemp -d)
peer_with_file "$REPO" "$(cd "$OTHER" && pwd -P)" "$REAL/shared.txt" 30
OUT=$(write_payload "$REAL" "$REAL/shared.txt" | bash "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: peer en otra carpeta no debe avisar: $OUT"; exit 1; }
echo "PASS: peer en carpeta distinta no avisa"
rm -rf "$REPO" "$OTHER"

# --- 4. registro del archivo viejo (>900s) -> silencio ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
peer_with_file "$REPO" "$REAL" "$REAL/shared.txt" 1200
OUT=$(write_payload "$REAL" "$REAL/shared.txt" | bash "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: un registro de archivo viejo no debe avisar: $OUT"; exit 1; }
echo "PASS: registro de archivo viejo se ignora"
rm -rf "$REPO"

# --- 5. sesion sola -> silencio ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
OUT=$(write_payload "$REAL" "$REAL/shared.txt" | bash "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: sesion sola no debe producir output: $OUT"; exit 1; }
echo "PASS: sesion sola no avisa"
rm -rf "$REPO"

echo "All guardian shared-file tests passed."
