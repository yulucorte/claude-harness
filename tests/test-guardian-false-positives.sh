#!/usr/bin/env bash
# Guardian: comandos que NO deben denegarse aunque haya un peer vivo.
#
# Hasta 1.7.0 classify() buscaba el primer token literal 'git' en cualquier
# posicion del segmento, y trataba todo checkout/switch/restore como
# reescritura del arbol. Resultado medido: 'man git checkout', 'echo git ...',
# un comentario '# git checkout', 'git checkout -b rama-nueva' y
# 'git restore --staged f' se denegaban todos.
#
# La contraparte (lo que SI debe seguir denegandose) esta al final: un guardian
# que no bloquea nada no es una mejora, es un guardian apagado.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARDIAN="$PLUGIN_ROOT/hooks/session-guardian.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILED=0

REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q .
git -C "$REPO" config user.email t@t.co
git -C "$REPO" config user.name t
echo x > "$REPO/f.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm init

# Peer VIVO en la MISMA carpeta y la MISMA rama: el escenario mas severo.
mkdir -p "$REPO/.git/slate-sessions"
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
python3 - "$REPO" "$HEAD_SHA" <<'PY'
import json, sys
repo, head = sys.argv[1], sys.argv[2]
json.dump({"branch": "main", "worktree": "", "head": head,
           "started_at": "2026-07-26T00:00:00Z", "cwd": repo, "files": []},
          open(repo + "/.git/slate-sessions/peer.lock", "w"))
PY

decision() {
  local cmd="$1"
  local payload
  payload=$(python3 -c '
import json, sys
print(json.dumps({"session_id": "me", "cwd": sys.argv[1], "tool_name": "Bash",
                  "tool_input": {"command": sys.argv[2]}}))' "$REPO" "$cmd")
  printf '%s' "$payload" | (cd "$REPO" && bash "$GUARDIAN" 2>/dev/null) | python3 -c '
import sys, json
raw = sys.stdin.read().strip()
if not raw:
    print("allow"); sys.exit()
try:
    print(json.loads(raw).get("hookSpecificOutput", {}).get("permissionDecision", "allow"))
except Exception:
    print("allow")'
}

expect() {
  local want="$1" cmd="$2" got
  got=$(decision "$cmd")
  if [ "$got" = "$want" ]; then
    printf 'PASS: %-42s -> %s\n' "$cmd" "$got"
  else
    printf 'FAIL: %-42s -> %s (esperado %s)\n' "$cmd" "$got" "$want"
    FAILED=1
  fi
}

echo "--- No deben denegarse (falsos positivos de <= 1.7.0) ---"
expect allow "man git checkout"
expect allow "echo git checkout main"
expect allow "ls  # git checkout main"
expect allow "grep -r 'git reset --hard' ."
expect allow "git checkout -b rama-nueva"
expect allow "git switch -c otra-rama"
expect allow "git restore --staged f.txt"
expect allow "git clean -- -foo"
expect allow "git status"
expect allow "npm run git-clean"

echo
echo "--- Deben seguir denegandose (el guardian sigue guardando) ---"
expect deny "git checkout main"
expect deny "git checkout -b rama origin/main"
expect deny "git switch otra"
expect deny "git reset --hard HEAD~1"
expect deny "git clean -fd"
expect deny "git stash"
expect deny "git restore f.txt"
expect deny "git restore --staged --worktree f.txt"
expect deny "git pull"
expect deny "FOO=bar git checkout main"
expect deny "env LANG=C git checkout main"
expect deny "sudo git reset --hard"
expect deny "git checkout -B rama origin/main"
expect deny "git switch --create x origin/main"
expect allow "git switch --create x"

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All guardian false-positive tests passed."
  exit 0
fi
echo "Guardian false-positive tests FAILED."
exit 1
