#!/usr/bin/env bash
# SessionEnd hook: drains current.md into history.md.
# SessionEnd does not support additionalContext output.

set -uo pipefail

PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-$(pwd)}"

CURRENT="$PROJECT_ROOT/docs/slate/progress/current.md"
HISTORY="$PROJECT_ROOT/docs/slate/progress/history.md"

if [ ! -f "$CURRENT" ]; then
  exit 0
fi

# Does current.md hold actual work?
#
# The old check was a line-anchored grep, so the INDENTED continuation lines of
# the template's HTML comment ("     Entries here represent...") read as real
# work and every session appended an empty block. Measured on a live project:
# 180 of 270 session-end blocks were nothing but the template.
#
# This drops whole <!-- ... --> blocks before judging, so multi-line comments
# no longer count as content.
has_work() {
  awk '
    function consider(l) {
      if (l ~ /^[[:space:]]*$/) return
      if (l ~ /^# /) return          # solo el H1 del titulo ("# Current work")
      if (l ~ /^_/)  return          # "_(none in flight)_"
      found = 1
    }
    {
      line = $0
      if (inc) {
        # Dentro de un <!-- ... -->: las lineas quedan EN DUDA, no descartadas.
        if (line ~ /-->/) { inc = 0; np = 0; sub(/^.*-->/, "", line); consider(line) }
        else pending[++np] = line
        next
      }
      if (line ~ /<!--/) {
        consider(substr(line, 1, index(line, "<!--") - 1))   # texto antes del comentario
        if (line ~ /-->/) next                               # comentario de una linea
        inc = 1; np = 0
        next
      }
      consider(line)
    }
    END {
      # Un <!-- que nunca cierra NO puede tragarse trabajo real: si el fichero
      # acaba con el comentario abierto, lo que quedo dentro vuelve a contar.
      if (inc) for (i = 1; i <= np; i++) consider(pending[i])
      exit(found ? 0 : 1)
    }
  ' "$1" 2>/dev/null
}

if ! has_work "$CURRENT"; then
  exit 0
fi

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)

{
  echo ""
  echo "## $TIMESTAMP — Session end"
  cat "$CURRENT"
} >> "$HISTORY" 2>/dev/null || true

# Reset current.md to empty state
cat > "$CURRENT" << 'EOF'
# Current work

_(none in flight)_

<!-- This file is auto-managed by slate:tracking-progress.
     Entries here represent IN-FLIGHT work for the current session.
     At session end, completed entries are moved to history.md;
     orphaned entries become CARRY-OVER. -->
EOF

# NO auto-commit. Until 1.8.0 this ran `git commit --allow-empty` on every
# session end; on a live project that produced 248 of 1244 commits — one in
# five — all titled "auto: session-end checkpoint", most of them empty. State
# files get committed alongside the work they describe, like any other file.
