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

# Ensure docs/slate/progress/.gitattributes marks history.md as merge=union,
# so concurrent append-only writes from different branches stop producing a
# conflict marker every time two sessions both appended a session block.
#
# Delivered HERE, not just by install-into-project.sh: the installer only
# runs once at install time and never overwrites a .gitattributes the user
# already has there (copy-if-missing) — almost any mature repo already has
# one, so an already-installed project would never receive this line through
# the installer alone. Same class of bug as codebase-map.md regenerating in
# already-installed projects (see CHANGELOG 1.8.0). session-start.sh runs on
# every session, so it reaches those projects too. Idempotent: only appends
# the line when missing, never replaces a user's own file.
GITATTRIBUTES="$STATE/progress/.gitattributes"
UNION_LINE="history.md merge=union"
if [ ! -e "$GITATTRIBUTES" ]; then
  printf '%s\n' "$UNION_LINE" > "$GITATTRIBUTES" 2>/dev/null || true
elif ! grep -qxF "$UNION_LINE" "$GITATTRIBUTES" 2>/dev/null; then
  printf '\n%s\n' "$UNION_LINE" >> "$GITATTRIBUTES" 2>/dev/null || true
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

# history.md with the hook exhaust (init.sh output, PreCompact stubs, empty
# session-end blocks) stripped out. Shared by history_tail() (last N lines)
# and the block-count check below (must agree on what counts as a real
# entry, or the count and the tail it's measuring drift apart).
#
# Projects that ran slate < 1.8.0 have history files where most lines are hook
# exhaust: init.sh output, PreCompact stubs, and empty session-end blocks that
# only copied the current.md template. Filtering here fixes those files without
# rewriting them — nothing is deleted, it just stops being injected.
history_clean() {
  [ -f "$STATE/progress/history.md" ] || return 0
  grep -v '^[[:space:]]*$' "$STATE/progress/history.md" 2>/dev/null \
    | grep -vE '^\[init\.sh\]|^## .* — SessionStart init\.sh$|^## .* — PreCompact triggered|^# Current work$|^_\(none in flight\)_$|^[[:space:]]*<!-- This file is auto-managed by slate|^[[:space:]]*(Entries here represent IN-FLIGHT|At session end, completed entries|orphaned entries become CARRY-OVER)|^[[:space:]]*-->[[:space:]]*$' \
    || true
}

history_tail() {
  history_clean | tail -n "$1"
}

# Active plugin version, so a stale-cache install (hooks/skills edited but the
# plugin.json version never bumped, so Claude Code keeps serving the cached
# old version) is visible instead of silent. Never blocks startup: any failure
# to read it just skips the line.
VERSION_LINE=""
if [ -f "$PLUGIN_ROOT/.claude-plugin/plugin.json" ]; then
  SLATE_VERSION=$(python3 -c "import json,sys
try:
    v = json.load(open(sys.argv[1])).get('version')
    print(v if isinstance(v, str) and v else '')
except Exception:
    print('')" "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null || true)
  [ -n "$SLATE_VERSION" ] && VERSION_LINE="slate ${SLATE_VERSION}"
fi

# history.md rotation warning. docs/archiving.md sets the limit at 40 entries;
# an entry is one '## YYYY-MM-DD — <summary>' session block, counted the same
# way history_tail() decides what is real (raw '## ' counts hook exhaust as
# entries too — measured on this repo: 53 raw vs 27 real). Silent when under
# the limit, so the common case stays quiet.
HISTORY_COUNT_LINE=""
if [ -f "$STATE/progress/history.md" ]; then
  HIST_LIMIT=40
  HIST_COUNT=$(history_clean | grep -c '^## ' || true)
  [ "${HIST_COUNT:-0}" -gt "$HIST_LIMIT" ] 2>/dev/null \
    && HISTORY_COUNT_LINE="history.md: ${HIST_COUNT}/${HIST_LIMIT} bloques — rota con tracking-progress"
fi

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
    [ -n "$HISTORY_COUNT_LINE" ] && CONTEXT="${CONTEXT}
${HISTORY_COUNT_LINE}"
    [ -n "$VERSION_LINE" ] && CONTEXT="${CONTEXT}
${VERSION_LINE}"
    ;;
  *)  # startup | clear (and any unknown source, treated as a cold start)
    # current.md is injected in full unless it exceeds ~100 lines. Measured on
    # a live project: an unbounded current.md reached 31.6 KB (~9000 tokens)
    # of dead weight in every single startup message.
    CURRENT_WORK=""
    if [ -f "$STATE/progress/current.md" ]; then
      CUR_LINES=$(wc -l < "$STATE/progress/current.md" 2>/dev/null | tr -d ' ')
      if [ "${CUR_LINES:-0}" -gt 100 ] 2>/dev/null; then
        CURRENT_WORK="(truncado — abre docs/slate/progress/current.md si necesitas el resto)
$(tail -n 100 "$STATE/progress/current.md" 2>/dev/null || true)"
      else
        CURRENT_WORK=$(cat "$STATE/progress/current.md" 2>/dev/null || true)
      fi
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
    [ -n "$HISTORY_COUNT_LINE" ] && CONTEXT="${CONTEXT}
${HISTORY_COUNT_LINE}"
    [ -n "$VERSION_LINE" ] && CONTEXT="${CONTEXT}
${VERSION_LINE}"
    ;;
esac

# El formato ENVUELTO no es cosmetico. El plano ({"additionalContext": ...})
# se ejecuta sin error pero Claude Code lo DESCARTA en silencio cuando varios
# plugins cablean SessionStart a la vez — y ese es el caso normal, no el raro:
# Superpowers cablea SessionStart (matcher startup|clear|compact) y slate se
# define en plugin.json como su companion. Medido en una sesion real leyendo el
# transcript .jsonl: el bloque de Superpowers (envuelto) llega como attachment,
# el de slate (plano) no aparece jamas. Todo lo de aqui abajo — indice de
# in-progress, estado en vuelo, historial, bugs, version, contadores — se
# perdia. Mismo modo de fallo que pre-compact.sh (corre, no falla, nadie lee),
# que 1.8.0 borro por eso mismo. session-lock.sh ya emitia envuelto desde
# FEAT-001, donde se documento el bug sin corregirlo aqui por alcance.
CONTEXT_JSON=$(printf '%s' "$CONTEXT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null \
  || printf '"%s"' "$(printf '%s' "$CONTEXT" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')")
printf '{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": %s}}\n' \
  "$CONTEXT_JSON" 2>/dev/null || exit 0
