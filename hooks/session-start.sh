#!/usr/bin/env bash
# SessionStart hook: injects LIGHTWEIGHT harness state into Claude's session.
# Emits JSON with additionalContext. Never exits non-zero.
#
# Design notes:
#  - Does NOT dump the SKILL.md (the protocol loads via the Skill tool on demand).
#  - Does NOT dump docs/slate/features/backlog.md (read on demand via managing-feature-list).
#  - in-progress is injected as an INDEX (one line per FEAT), not full blocks.
#  - history is capped to the last line(s), not tail -30.
#  - Behaviour differs by session source (startup|clear vs compact|resume).
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}"
PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-$(pwd)}"

# Since slate 1.6.0 all state lives under docs/slate/. Auto-migrate projects
# still using the old repo-root layout (progress/ features/ bugs/ ideas/).
# Idempotent: only moves a dir when the old one exists and the new one doesn't.
slate_migrate_layout() {
  local d
  [ -d "$PROJECT_ROOT/docs/slate/progress" ] && \
  [ -d "$PROJECT_ROOT/docs/slate/features" ] && return 0  # already migrated
  local moved=0
  for d in progress features bugs ideas; do
    if [ -d "$PROJECT_ROOT/$d" ] && [ ! -e "$PROJECT_ROOT/docs/slate/$d" ]; then
      mkdir -p "$PROJECT_ROOT/docs/slate" 2>/dev/null || true
      if git -C "$PROJECT_ROOT" rev-parse >/dev/null 2>&1; then
        git -C "$PROJECT_ROOT" mv "$d" "docs/slate/$d" 2>/dev/null \
          || mv "$PROJECT_ROOT/$d" "$PROJECT_ROOT/docs/slate/$d" 2>/dev/null || true
      else
        mv "$PROJECT_ROOT/$d" "$PROJECT_ROOT/docs/slate/$d" 2>/dev/null || true
      fi
      [ -d "$PROJECT_ROOT/docs/slate/$d" ] && moved=1
    fi
  done
  [ "$moved" -eq 1 ] && printf 'slate: migrated state to docs/slate/\n' >&2 || true
}
slate_migrate_layout

# Single source of truth for where slate state lives (since 1.6.0).
STATE="$PROJECT_ROOT/docs/slate"

# Claude Code passes the SessionStart payload as JSON on stdin; the "source"
# field is one of: startup | clear | resume | compact. Read it so we can inject
# less on compact/resume (the agent already internalized the protocol).
STDIN_JSON=""
if [ ! -t 0 ]; then
  STDIN_JSON=$(cat 2>/dev/null || true)
fi
SOURCE=$(printf '%s' "$STDIN_JSON" | python3 -c "import sys,json
try:
    print((json.load(sys.stdin).get('source') or '').strip())
except Exception:
    print('')" 2>/dev/null || true)
[ -z "$SOURCE" ] && SOURCE="startup"

# Only operate if this project has been initialized with slate
if [ ! -d "$STATE/progress" ] || [ ! -d "$STATE/features" ]; then
  exit 0
fi

# Run init.sh if present. Its output is DISCARDED on success and only surfaces
# on stderr when init.sh fails.
#
# Until 1.8.0 this appended init.sh's output to history.md — and history_tail()
# below reads the tail of that same file. The hook fed itself: every session
# injected "[init.sh] OK" as "History (reciente)", and real work was buried.
# Measured on a live project: 1437 of 6265 history lines were init.sh noise.
if [ -f "$PROJECT_ROOT/init.sh" ]; then
  INIT_OUT=$(bash "$PROJECT_ROOT/init.sh" 2>&1) \
    || printf 'slate: init.sh failed:\n%s\n' "$INIT_OUT" >&2
fi

# in-progress as an INDEX: one line per FEAT (ID + title + status). Full
# descriptions, criteria and subtasks stay in the file; the agent opens it when
# it actually works that feature.
INPROGRESS_INDEX=""
if [ -f "$STATE/features/in-progress.md" ]; then
  INPROGRESS_INDEX=$(awk '
    function flush(){ if(id!=""){ printf "- %s%s\n", id, (st!=""?" ["st"]":"") } }
    /^## FEAT-/ { flush(); id=substr($0,4); st=""; next }
    /^- \*\*Status\*\*:/ { s=$0; sub(/^- \*\*Status\*\*:[ ]*/,"",s); st=s }
    END { flush() }
  ' "$STATE/features/in-progress.md" 2>/dev/null || true)
fi
[ -z "$INPROGRESS_INDEX" ] && INPROGRESS_INDEX="(ninguna feature en progreso)"

# Bugs open + ideas pending: counts and IDs only, never full entry bodies —
# same "index, not dump" principle as INPROGRESS_INDEX above. Skip cleanly
# if bugs/ or ideas/ don't exist (projects installed before this feature).
BUGS_LINE=""
if [ -f "$STATE/bugs/open.md" ]; then
  BUG_IDS=$(grep -o '^## BUG-[0-9]\{3\}' "$STATE/bugs/open.md" 2>/dev/null | sed 's/^## //' | paste -sd, - || true)
  BUG_COUNT=$(printf '%s' "$BUG_IDS" | tr ',' '\n' | grep -c . || true)
  [ "${BUG_COUNT:-0}" -gt 0 ] 2>/dev/null && BUGS_LINE="## Bugs abiertos: ${BUG_COUNT} (${BUG_IDS})"
fi

# The ideas inbox is a DEPOSIT, not a queue. Nagging "run /ideas-triage" every
# single session trains the reader to skip that whole region of the startup
# message — measured: 28 ideas, 0 triages, the line ignored 28 times. Surface it
# only once the inbox is genuinely oversized (override with SLATE_IDEAS_NAG_AT).
IDEAS_LINE=""
if [ -f "$STATE/ideas/inbox.md" ]; then
  IDEA_COUNT=$(grep -c '^- ' "$STATE/ideas/inbox.md" 2>/dev/null || true)
  NAG_AT="${SLATE_IDEAS_NAG_AT:-40}"
  [ "${IDEA_COUNT:-0}" -ge "$NAG_AT" ] 2>/dev/null \
    && IDEAS_LINE="## Ideas acumuladas: ${IDEA_COUNT} (buzón grande; /ideas-triage cuando convenga)"
fi

# Last N lines of history.md that carry actual work.
#
# Projects that ran slate < 1.8.0 have history files where most lines are hook
# exhaust: init.sh output, PreCompact stubs, and empty session-end blocks that
# only copied the current.md template. Filtering here fixes those files without
# rewriting them — nothing is deleted, it just stops being injected.
history_tail() {
  local n="$1"
  [ -f "$STATE/progress/history.md" ] || return 0
  grep -v '^[[:space:]]*$' "$STATE/progress/history.md" 2>/dev/null \
    | grep -vE '^\[init\.sh\]|^## .* — SessionStart init\.sh$|^## .* — PreCompact triggered|^# Current work$|^_\(none in flight\)_$|^[[:space:]]*<!-- This file is auto-managed by slate|^[[:space:]]*(Entries here represent IN-FLIGHT|At session end, completed entries|orphaned entries become CARRY-OVER)|^[[:space:]]*-->[[:space:]]*$' \
    | tail -n "$n" || true
}

case "$SOURCE" in
  compact|resume)
    # The agent already has the protocol in context. Inject the bare minimum:
    # in-progress index + the single most recent history line. No header.
    CONTEXT="## In-progress (índice)
${INPROGRESS_INDEX}

## History (última)
$(history_tail 1)"
    [ -n "$BUGS_LINE" ] && CONTEXT="${CONTEXT}
${BUGS_LINE}"
    [ -n "$IDEAS_LINE" ] && CONTEXT="${CONTEXT}
${IDEAS_LINE}"
    ;;
  *)  # startup | clear (and any unknown source, treated as a cold start)
    CURRENT_WORK=""
    if [ -f "$STATE/progress/current.md" ]; then
      CURRENT_WORK=$(cat "$STATE/progress/current.md" 2>/dev/null || true)
    fi
    CONTEXT="Slate activo — estado abajo. Protocolo completo en la skill using-slate si lo necesitas.

## In-progress (índice)
${INPROGRESS_INDEX}

## En vuelo
${CURRENT_WORK}

## History (reciente)
$(history_tail 2)"
    [ -n "$BUGS_LINE" ] && CONTEXT="${CONTEXT}
${BUGS_LINE}"
    [ -n "$IDEAS_LINE" ] && CONTEXT="${CONTEXT}
${IDEAS_LINE}"
    ;;
esac

CONTEXT_JSON=$(printf '%s' "$CONTEXT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null \
  || printf '"%s"' "$(printf '%s' "$CONTEXT" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')")
printf '{"additionalContext": %s}\n' "$CONTEXT_JSON" 2>/dev/null || exit 0
