#!/usr/bin/env bash
# session-start.sh debe emitir el formato ENVUELTO
# ({"hookSpecificOutput": {"hookEventName": "SessionStart", ...}}), no el plano
# ({"additionalContext": ...}).
#
# Por que: el formato plano se ejecuta sin error pero Claude Code lo DESCARTA
# en silencio cuando varios plugins cablean SessionStart a la vez. Superpowers
# cablea SessionStart (matcher startup|clear|compact) y slate se define a si
# mismo como su companion, asi que la competencia es el caso normal, no el raro.
# Medido en una sesion real (transcript .jsonl): el bloque de superpowers
# (envuelto) llega como attachment; el de slate (plano) no aparece nunca.
# Mismo modo de fallo que pre-compact.sh: corre, no falla, nadie lo lee.
# session-lock.sh ya emitia el formato correcto desde FEAT-001.
set -e
trap 'echo "FAIL at line $LINENO"' ERR

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/session-start.sh"

setup_project() {
  local dir
  dir=$(mktemp -d)
  mkdir -p "$dir/docs/slate/progress" "$dir/docs/slate/features"
  printf '# Current work\n\n_(none in flight)_\n' > "$dir/docs/slate/progress/current.md"
  printf '# History\n' > "$dir/docs/slate/progress/history.md"
  printf '# In progress\n' > "$dir/docs/slate/features/in-progress.md"
  echo "$dir"
}

emit() {
  # $1=project_root $2=source
  printf '{"source":"%s","session_id":"sess-start-fmt"}' "$2" \
    | CLAUDE_PROJECT_ROOT="$1" bash "$HOOK" 2>/dev/null
}

# --- 1. startup: formato envuelto, con hookEventName correcto ---
PROJ=$(setup_project)
OUT=$(emit "$PROJ" "startup")
[ -n "$OUT" ] || { echo "FAIL: session-start.sh no emitio nada en startup"; exit 1; }

python3 - "$OUT" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert "hookSpecificOutput" in d, \
    "formato PLANO: Claude Code lo descarta cuando compiten varios SessionStart. Claves: %s" % list(d)
assert "additionalContext" not in d, \
    "additionalContext debe ir DENTRO de hookSpecificOutput, no en la raiz"
h = d["hookSpecificOutput"]
assert h.get("hookEventName") == "SessionStart", \
    "hookEventName debe ser 'SessionStart', es %r" % h.get("hookEventName")
assert isinstance(h.get("additionalContext"), str) and h["additionalContext"].strip(), \
    "additionalContext vacio o no es texto"
assert "Slate activo" in h["additionalContext"], \
    "el contexto perdio su encabezado: %r" % h["additionalContext"][:80]
PY
echo "  ok  startup emite formato envuelto"
rm -rf "$PROJ"

# --- 2. compact/resume: mismo contrato de formato, contenido mas corto ---
PROJ=$(setup_project)
OUT=$(emit "$PROJ" "compact")
[ -n "$OUT" ] || { echo "FAIL: session-start.sh no emitio nada en compact"; exit 1; }

python3 - "$OUT" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert "hookSpecificOutput" in d, "compact tambien debe emitir formato envuelto. Claves: %s" % list(d)
h = d["hookSpecificOutput"]
assert h.get("hookEventName") == "SessionStart", "hookEventName incorrecto en compact: %r" % h.get("hookEventName")
assert "In-progress" in h.get("additionalContext", ""), "compact perdio el indice de in-progress"
PY
echo "  ok  compact emite formato envuelto"
rm -rf "$PROJ"

# --- 3. proyecto sin slate: silencio total (no un JSON vacio) ---
BARE=$(mktemp -d)
OUT=$(emit "$BARE" "startup")
[ -z "$OUT" ] || { echo "FAIL: emitio algo en un proyecto sin docs/slate: $OUT"; exit 1; }
echo "  ok  proyecto sin slate: sin salida"
rm -rf "$BARE"

# --- 4. el formato plano no debe reaparecer en el fuente ---
if grep -qE "printf '\{\"additionalContext\"" "$HOOK"; then
  echo "FAIL: session-start.sh volvio al formato plano en el fuente"
  exit 1
fi
echo "  ok  el fuente no contiene el formato plano"

echo "PASS test-session-start-wrapped-output.sh"
