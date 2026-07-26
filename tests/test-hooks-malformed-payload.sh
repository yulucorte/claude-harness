#!/usr/bin/env bash
# Matriz de payloads malformados contra LOS DOS hooks que leen stdin en caliente
# (session-guardian.sh y session-heartbeat.sh).
#
# Por que stderr es la asercion que importa: el envoltorio bash de ambos hooks
# termina en 'exit 0' pase lo que pase, asi que una excepcion de Python NO
# cambia el codigo de salida ni escribe nada en stdout — el hook simplemente
# deja de hacer su trabajo, en silencio, incluida la denegacion. La unica huella
# observable es el traceback en stderr. Seis rondas de esta misma clase de bug
# sobrevivieron a la revision justamente porque nadie miraba ahi.
#
# Ademas de "no revienta", donde una guarda de tipo permite que el hook SIGA
# funcionando correctamente se afirma el comportamiento util (p.ej. un 'cwd' de
# tipo invalido debe caer en CLAUDE_PROJECT_ROOT y seguir denegando), para que
# el try/except no pueda degradar un bug real a un no-op silencioso.
set -e
trap 'echo "FAIL at line $LINENO"' ERR

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARDIAN="$PLUGIN_ROOT/hooks/session-guardian.sh"
HEARTBEAT="$PLUGIN_ROOT/hooks/session-heartbeat.sh"

setup_repo() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q
  git -C "$dir" config user.email "t@t.com"
  git -C "$dir" config user.name "t"
  git -C "$dir" commit --allow-empty -q -m init
  echo "$dir"
}

# mk <variante> <cwd> <sid> <comando>
mk() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, sys
v, cwd, sid, cmd = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
p = {"session_id": sid, "cwd": cwd, "tool_name": "Bash", "tool_input": {"command": cmd}}
if v == "control":            pass
elif v == "sid-int":          p["session_id"] = 12345
elif v == "sid-list":         p["session_id"] = ["yo"]
elif v == "sid-dict":         p["session_id"] = {"id": "yo"}
elif v == "sid-null":         p["session_id"] = None
elif v == "cwd-int":          p["cwd"] = 12345
elif v == "cwd-list":         p["cwd"] = [cwd]
elif v == "cwd-dict":         p["cwd"] = {"path": cwd}
elif v == "cwd-null":         p["cwd"] = None
elif v == "cmd-list":         p["tool_input"]["command"] = ["git", "checkout", "main"]
elif v == "cmd-int":          p["tool_input"]["command"] = 12345
elif v == "cmd-dict":         p["tool_input"]["command"] = {"cmd": cmd}
elif v == "toolinput-str":    p["tool_input"] = "git checkout main"
elif v == "toolinput-list":   p["tool_input"] = ["git", "checkout"]
elif v == "toolinput-null":   p["tool_input"] = None
elif v == "toolname-int":     p["tool_name"] = 12345
elif v == "toolname-list":    p["tool_name"] = ["Bash"]
elif v == "filepath-int":     p = {"session_id": sid, "cwd": cwd, "tool_name": "Write",
                                   "tool_input": {"file_path": 12345}}
elif v == "filepath-list":    p = {"session_id": sid, "cwd": cwd, "tool_name": "Write",
                                   "tool_input": {"file_path": [cwd]}}
elif v == "toplevel-array":   p = ["session_id", sid]
elif v == "toplevel-string":  p = "session_id=%s" % sid
elif v == "toplevel-number":  p = 12345
elif v == "toplevel-null":    p = None
elif v == "empty-object":     p = {}
else:
    sys.stderr.write("variante desconocida: %s\n" % v); sys.exit(2)
print(json.dumps(p))
PY
}

VARIANTS="control sid-int sid-list sid-dict sid-null cwd-int cwd-list cwd-dict cwd-null \
cmd-list cmd-int cmd-dict toolinput-str toolinput-list toolinput-null toolname-int \
toolname-list filepath-int filepath-list toplevel-array toplevel-string toplevel-number \
toplevel-null empty-object"

is_deny() { echo "$1" | grep -q '"permissionDecision": "deny"'; }

# =====================================================================
# 1. session-guardian.sh — ningun payload puede tumbar el hook
# =====================================================================
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
mkdir -p "$REPO/.git/slate-sessions"
python3 -c "import json,sys; json.dump({'branch':'main','cwd':sys.argv[2],'worktree':'','head':'','started_at':'2026-01-01T00:00:00Z','files':[]}, open(sys.argv[1],'w'))" \
  "$REPO/.git/slate-sessions/peer.lock" "$REAL"

# control: con este fixture el guardian DEBE denegar; si no, la matriz no prueba nada
CTRL=$(mk control "$REAL" "yo" "git checkout main" | CLAUDE_PROJECT_ROOT="$REAL" bash "$GUARDIAN")
is_deny "$CTRL" || { echo "FAIL: el control positivo del guardian no denego; la matriz no probaria nada: '${CTRL:-<vacio>}'"; exit 1; }
echo "PASS: control positivo del guardian (payload valido -> deny)"

for V in $VARIANTS; do
  ERRF=$(mktemp); OUTF=$(mktemp); RC=0
  mk "$V" "$REAL" "yo" "git checkout main" | CLAUDE_PROJECT_ROOT="$REAL" bash "$GUARDIAN" >"$OUTF" 2>"$ERRF" || RC=$?
  [ "$RC" -eq 0 ] || { echo "FAIL: guardian salio con codigo $RC ante '$V'"; cat "$ERRF"; exit 1; }
  [ -s "$ERRF" ] && { echo "FAIL: guardian escribio en stderr ante '$V' (excepcion, el hook dejo de aplicarse): $(cat "$ERRF")"; exit 1; }
  rm -f "$ERRF" "$OUTF"
  echo "  ok  guardian sobrevive a '$V'"
done
echo "PASS: session-guardian.sh sale 0 y con stderr vacio ante los $(echo $VARIANTS | wc -w | tr -d ' ') payloads de la matriz"

# Guarda de tipo, no solo supervivencia: un 'cwd' invalido debe caer en
# CLAUDE_PROJECT_ROOT y SEGUIR denegando. Si el try/except lo degradara a un
# no-op silencioso, la proteccion desapareceria sin dejar rastro.
for V in cwd-int cwd-list cwd-dict cwd-null; do
  OUT=$(mk "$V" "$REAL" "yo" "git checkout main" | CLAUDE_PROJECT_ROOT="$REAL" bash "$GUARDIAN")
  is_deny "$OUT" || { echo "FAIL: con '$V' y CLAUDE_PROJECT_ROOT valido el guardian debe seguir denegando, obtuvo: '${OUT:-<vacio>}'"; exit 1; }
done
echo "PASS: un 'cwd' de tipo invalido cae en CLAUDE_PROJECT_ROOT y el guardian sigue denegando"

# Un 'tool_name' de tipo invalido no debe impedir el modo bash (el comando si es valido)
OUT=$(mk toolname-int "$REAL" "yo" "git checkout main" | CLAUDE_PROJECT_ROOT="$REAL" bash "$GUARDIAN")
is_deny "$OUT" || { echo "FAIL: un tool_name no-string no debe impedir la denegacion del comando: '${OUT:-<vacio>}'"; exit 1; }
echo "PASS: un 'tool_name' de tipo invalido no impide la denegacion del comando"
rm -rf "$REPO"

# =====================================================================
# 2. session-heartbeat.sh — mismo contrato, MAS stdout vacio
#    (UserPromptSubmit inyecta el stdout del hook en el contexto del prompt)
# =====================================================================
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
mkdir -p "$REPO/.git/slate-sessions"
LOCK="$REPO/.git/slate-sessions/yo.lock"

reset_lock() {
  python3 -c "import json,sys,os,time; json.dump({'branch':'main','cwd':sys.argv[2],'worktree':'','head':'','started_at':'2026-01-01T00:00:00Z','files':[]}, open(sys.argv[1],'w')); t=time.time()-1000; os.utime(sys.argv[1],(t,t))" \
    "$LOCK" "$REAL"
}
lock_mtime() { stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK"; }

# control: un payload valido refresca el mtime del lock
reset_lock
OLD=$(lock_mtime)
mk control "$REAL" "yo" "ls" | CLAUDE_PROJECT_ROOT="$REAL" bash "$HEARTBEAT" >/dev/null
NEW=$(lock_mtime)
[ "$NEW" -gt "$OLD" ] || { echo "FAIL: el control positivo del heartbeat no refresco el lock; la matriz no probaria nada"; exit 1; }
echo "PASS: control positivo del heartbeat (payload valido -> refresca el lock)"

for V in $VARIANTS; do
  reset_lock
  ERRF=$(mktemp); OUTF=$(mktemp); RC=0
  mk "$V" "$REAL" "yo" "ls" | CLAUDE_PROJECT_ROOT="$REAL" bash "$HEARTBEAT" >"$OUTF" 2>"$ERRF" || RC=$?
  [ "$RC" -eq 0 ] || { echo "FAIL: heartbeat salio con codigo $RC ante '$V'"; cat "$ERRF"; exit 1; }
  [ -s "$ERRF" ] && { echo "FAIL: heartbeat escribio en stderr ante '$V' (excepcion, el latido dejo de aplicarse): $(cat "$ERRF")"; exit 1; }
  [ -s "$OUTF" ] && { echo "FAIL: heartbeat escribio en stdout ante '$V'; UserPromptSubmit inyecta ese stdout en el prompt: $(cat "$OUTF")"; exit 1; }
  rm -f "$ERRF" "$OUTF"
  echo "  ok  heartbeat sobrevive a '$V'"
done
echo "PASS: session-heartbeat.sh sale 0, con stderr Y stdout vacios, ante toda la matriz"

# Misma guarda de tipo que en el guardian: un 'cwd' invalido cae en
# CLAUDE_PROJECT_ROOT y el latido SIGUE refrescando el lock.
for V in cwd-int cwd-list cwd-dict cwd-null; do
  reset_lock
  OLD=$(lock_mtime)
  mk "$V" "$REAL" "yo" "ls" | CLAUDE_PROJECT_ROOT="$REAL" bash "$HEARTBEAT" >/dev/null
  NEW=$(lock_mtime)
  [ "$NEW" -gt "$OLD" ] || { echo "FAIL: con '$V' y CLAUDE_PROJECT_ROOT valido el heartbeat debe seguir refrescando el lock"; exit 1; }
done
echo "PASS: un 'cwd' de tipo invalido cae en CLAUDE_PROJECT_ROOT y el heartbeat sigue latiendo"
rm -rf "$REPO"

echo "All malformed-payload tests passed."
