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

pre_group_matchers = [g.get('matcher') for g in h.get('PreToolUse', [])]
assert 'Bash' in pre_group_matchers, 'PreToolUse for session-guardian.sh must matcher Bash'

pre_compact_cmds = cmds('PreCompact')
assert any('pre-compact.sh' in c for c in pre_compact_cmds), 'existing pre-compact.sh must stay untouched'

print('OK')
"
echo "PASS: all 4 session-lock hooks (incl. session-heartbeat.sh on both PostToolUse and UserPromptSubmit) are wired into hooks.json without disturbing existing entries"
