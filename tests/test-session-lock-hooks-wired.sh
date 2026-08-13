#!/usr/bin/env bash
set -e
trap 'echo "FAIL at line $LINENO"' ERR

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"

python3 -c "
import json
d = json.load(open('$HOOKS_JSON'))
h = d['hooks']

def cmds(event):
    out = []
    for group in h.get(event, []):
        for entry in group.get('hooks', []):
            out.append(entry['command'])
    return out

session_start_cmds = cmds('SessionStart')
assert any('session-start.sh' in c for c in session_start_cmds), 'existing session-start.sh missing from SessionStart'
assert any('session-lock.sh' in c for c in session_start_cmds), 'session-lock.sh not wired into SessionStart'

session_end_cmds = cmds('SessionEnd')
assert any('session-end.sh' in c for c in session_end_cmds), 'existing session-end.sh missing from SessionEnd'
assert any('session-lock-cleanup.sh' in c for c in session_end_cmds), 'session-lock-cleanup.sh not wired into SessionEnd'

post_cmds = cmds('PostToolUse')
assert any('session-heartbeat.sh' in c for c in post_cmds), 'session-heartbeat.sh not wired into PostToolUse'

prompt_cmds = cmds('UserPromptSubmit')
assert any('session-heartbeat.sh' in c for c in prompt_cmds), 'session-heartbeat.sh not wired into UserPromptSubmit'

pre_cmds = cmds('PreToolUse')
assert any('session-guardian.sh' in c for c in pre_cmds), 'session-guardian.sh not wired into PreToolUse'

pre_groups = h.get('PreToolUse', [])
pre_group_matchers = [g.get('matcher') for g in pre_groups]
assert 'Bash' in pre_group_matchers, 'PreToolUse for session-guardian.sh must matcher Bash'
assert 'Write|Edit|NotebookEdit' in pre_group_matchers, 'PreToolUse for session-guardian.sh (file mode) must matcher Write|Edit|NotebookEdit'

file_mode_cmds = [entry['command'] for g in pre_groups if g.get('matcher') == 'Write|Edit|NotebookEdit' for entry in g.get('hooks', [])]
assert any('session-guardian.sh' in c for c in file_mode_cmds), 'session-guardian.sh not wired into the Write|Edit|NotebookEdit PreToolUse matcher'

# pre-compact.sh was removed in 1.8.0: it read CLAUDE_TRANSCRIPT_PATH, which the
# harness never sets, so all 58 firings on a live project logged
# 'no transcript available' and snapshotted nothing. Assert it stays gone.
assert 'PreCompact' not in h, 'PreCompact hook was removed in 1.8.0; do not reintroduce it'
allcmds = [e['command'] for g in h.values() for grp in [g] for gg in grp for e in gg.get('hooks', [])]
assert not any('pre-compact.sh' in c for c in allcmds), 'pre-compact.sh must not be wired anywhere'

print('OK')
"
echo "PASS: all 4 session-lock hooks (incl. session-heartbeat.sh on both PostToolUse and UserPromptSubmit) are wired into hooks.json without disturbing existing entries"

if [ -e "$PLUGIN_ROOT/hooks/pre-compact.sh" ]; then
  echo "FAIL: hooks/pre-compact.sh reaparecio; se elimino en 1.8.0 (nunca capturo un transcript)"
  exit 1
fi
echo "PASS: pre-compact.sh sigue eliminado"

# --- Ningun hook puede emitir permissionDecision "allow" -------------------
# Un "allow" salta la confirmacion del usuario y las reglas de permisos del
# proyecto para TODA la llamada. Los hooks de slate solo pueden denegar o
# avisar; que nadie lo introduzca por descuido en el futuro.
if grep -rn 'permissionDecision"[[:space:]]*:[[:space:]]*"allow"' "$PLUGIN_ROOT/hooks/" ; then
  echo "FAIL: un hook emite permissionDecision \"allow\"; los hooks de slate solo deniegan o avisan"
  exit 1
fi
if grep -rn "permissionDecision'[[:space:]]*:[[:space:]]*'allow'" "$PLUGIN_ROOT/hooks/" ; then
  echo "FAIL: un hook emite permissionDecision 'allow'; los hooks de slate solo deniegan o avisan"
  exit 1
fi
echo "PASS: ningun hook emite permissionDecision \"allow\""

# --- Las tres listas de herramientas de escritura deben coincidir ----------
# session-guardian.sh (modo fichero), session-heartbeat.sh (registro de
# 'files') y el matcher de hooks.json describen el MISMO conjunto. Si se
# desincronizan, el guardian avisa de archivos que el heartbeat nunca anota,
# o el hook ni siquiera se dispara para una herramienta que si vigila.
python3 -c "
import json, re, sys

def tool_tuple(path):
    src = open(path).read()
    m = re.search(r'tool in \(([^)]*)\)', src)
    assert m, 'no se encontro la lista de herramientas de escritura en ' + path
    return [t.strip().strip('\"').strip(\"'\") for t in m.group(1).split(',') if t.strip()]

g = tool_tuple('$PLUGIN_ROOT/hooks/session-guardian.sh')
h = tool_tuple('$PLUGIN_ROOT/hooks/session-heartbeat.sh')

d = json.load(open('$HOOKS_JSON'))
matchers = [grp.get('matcher') for grp in d['hooks'].get('PreToolUse', [])]
write_matcher = [m for m in matchers if m and 'Write' in m]
assert len(write_matcher) == 1, 'se esperaba exactamente un matcher de escritura, hay: %r' % matchers
j = write_matcher[0].split('|')

assert g == h, 'guardian %r != heartbeat %r' % (g, h)
assert g == j, 'hooks (%r) != matcher de hooks.json (%r)' % (g, j)
print('write-tool list:', g)

# --- TTL compartido: guardian y session-lock deben cadudar los locks igual --
gsrc = open('$PLUGIN_ROOT/hooks/session-guardian.sh').read()
lsrc = open('$PLUGIN_ROOT/hooks/session-lock.sh').read()
gttl = re.search(r'^\s*TTL\s*=\s*(\d+)', gsrc, re.M)
lttl = re.search(r'^\s*TTL_SECONDS=(\d+)', lsrc, re.M)
assert gttl, 'session-guardian.sh no define TTL'
assert lttl, 'session-lock.sh no define TTL_SECONDS'
assert gttl.group(1) == lttl.group(1), 'TTL desincronizado: guardian %s vs lock %s' % (gttl.group(1), lttl.group(1))
gfresh = re.search(r'^\s*FRESH\s*=\s*(\d+)', gsrc, re.M)
assert gfresh, 'session-guardian.sh no define FRESH'
# 1.9.0: FRESH se igualo al TTL a proposito (elimina la banda tibia de
# deny->warn de 300-900s). El invariante ya no es FRESH < TTL, es FRESH == TTL.
assert int(gfresh.group(1)) == int(gttl.group(1)), 'FRESH debe ser igual al TTL (banda tibia eliminada en 1.9.0)'
print('TTL:', gttl.group(1), 'FRESH:', gfresh.group(1))
"
echo "PASS: la lista de herramientas de escritura coincide en guardian, heartbeat y hooks.json; TTL/FRESH coherentes"
