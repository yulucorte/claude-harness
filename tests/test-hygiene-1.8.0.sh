#!/usr/bin/env bash
# Regression tests for the 1.8.0 hygiene pass.
#
# Every assertion here corresponds to a defect measured on a live project
# (phlou-app, 1244 commits) before the fix. They are pinned so the behaviour
# cannot silently come back.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILED=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=1; }

# --- 1. SessionStart must not feed its own history tail --------------------
# Before: session-start.sh appended init.sh's output to history.md and then
# injected the tail of that same file, so every session started with
# "[init.sh] OK" as its "History (reciente)". 1437 of 6265 lines were this.
setup_project() {
  local d="$1"
  mkdir -p "$d/docs/slate/progress" "$d/docs/slate/features"
  printf '# In progress\n' > "$d/docs/slate/features/in-progress.md"
  printf '# Current work\n\n_(none in flight)_\n' > "$d/docs/slate/progress/current.md"
  cat > "$d/init.sh" <<'EOF'
#!/usr/bin/env bash
echo "[init.sh] starting..."
echo "[init.sh] OK"
EOF
  chmod +x "$d/init.sh"
}

P="$TMP/p1"
setup_project "$P"
printf '# Session history\n\n## 2026-07-01 — trabajo real\n- FEAT-999 terminada y verificada\n' \
  > "$P/docs/slate/progress/history.md"

OUT=$(cd "$P" && printf '{"source":"startup"}' \
  | CLAUDE_PROJECT_ROOT="$P" bash "$PLUGIN_ROOT/hooks/session-start.sh" 2>/dev/null)

if printf '%s' "$OUT" | grep -q 'init\.sh'; then
  fail "el contexto inyectado contiene salida de init.sh"
else
  pass "el contexto inyectado no contiene salida de init.sh"
fi

if printf '%s' "$OUT" | grep -q 'FEAT-999 terminada'; then
  pass "el contexto inyectado trae la ultima linea de trabajo real"
else
  fail "el contexto inyectado perdio el trabajo real (obtenido: $OUT)"
fi

if grep -q 'init\.sh' "$P/docs/slate/progress/history.md"; then
  fail "history.md fue contaminado con la salida de init.sh"
else
  pass "history.md no fue contaminado por init.sh"
fi

# --- 2. history_tail ignora el ruido heredado ------------------------------
# Proyectos que ya corrieron slate < 1.8.0 tienen el historial sucio. El
# filtro debe saltarselo sin reescribir el fichero.
P2="$TMP/p2"
setup_project "$P2"
cat > "$P2/docs/slate/progress/history.md" <<'EOF'
# Session history

## 2026-07-01 — trabajo real
- FEAT-888 desplegada en produccion

## 2026-07-02 12:00:00 — SessionStart init.sh
[init.sh] starting...
[init.sh] OK

## 2026-07-02 13:00:00 — Session end
# Current work

_(none in flight)_

<!-- This file is auto-managed by slate:tracking-progress.
     Entries here represent IN-FLIGHT work for the current session.
     At session end, completed entries are moved to history.md;
     orphaned entries become CARRY-OVER. -->

## 2026-07-02 14:00:00 — PreCompact triggered (matcher: manual) — no transcript available
EOF

OUT2=$(cd "$P2" && printf '{"source":"startup"}' \
  | CLAUDE_PROJECT_ROOT="$P2" bash "$PLUGIN_ROOT/hooks/session-start.sh" 2>/dev/null)

if printf '%s' "$OUT2" | grep -q 'FEAT-888 desplegada'; then
  pass "el filtro rescata trabajo real enterrado bajo ruido heredado"
else
  fail "el filtro no rescato el trabajo real (obtenido: $OUT2)"
fi

# --- 3. El buzon de ideas no se anuncia por debajo del umbral --------------
P3="$TMP/p3"
setup_project "$P3"
mkdir -p "$P3/docs/slate/ideas"
printf '# Session history\n' > "$P3/docs/slate/progress/history.md"
{ echo "# Ideas inbox"; for i in $(seq 1 28); do echo "- 2026-07-20 10:00 — idea $i"; done; } \
  > "$P3/docs/slate/ideas/inbox.md"

OUT3=$(cd "$P3" && printf '{"source":"startup"}' \
  | CLAUDE_PROJECT_ROOT="$P3" bash "$PLUGIN_ROOT/hooks/session-start.sh" 2>/dev/null)
if printf '%s' "$OUT3" | grep -q 'Ideas'; then
  fail "28 ideas no deben generar aviso (umbral 40)"
else
  pass "28 ideas no generan aviso"
fi

{ echo "# Ideas inbox"; for i in $(seq 1 41); do echo "- 2026-07-20 10:00 — idea $i"; done; } \
  > "$P3/docs/slate/ideas/inbox.md"
OUT3B=$(cd "$P3" && printf '{"source":"startup"}' \
  | CLAUDE_PROJECT_ROOT="$P3" bash "$PLUGIN_ROOT/hooks/session-start.sh" 2>/dev/null)
if printf '%s' "$OUT3B" | grep -q 'Ideas acumuladas: 41'; then
  pass "41 ideas si superan el umbral y se anuncian"
else
  fail "41 ideas deberian anunciarse (obtenido: $OUT3B)"
fi

# --- 4. SessionEnd no escribe bloques vacios ni auto-commitea --------------
# Antes: el grep ancorado a linea dejaba pasar las lineas INDENTADAS del
# comentario de la plantilla. 180 de 270 bloques eran plantilla vacia.
P4="$TMP/p4"
mkdir -p "$P4/docs/slate/progress"
git -C "$P4" init -q . 2>/dev/null
git -C "$P4" config user.email t@t.co; git -C "$P4" config user.name t
cat > "$P4/docs/slate/progress/current.md" <<'EOF'
# Current work

_(none in flight)_

<!-- This file is auto-managed by slate:tracking-progress.
     Entries here represent IN-FLIGHT work for the current session.
     At session end, completed entries are moved to history.md;
     orphaned entries become CARRY-OVER. -->
EOF
printf '# Session history\n' > "$P4/docs/slate/progress/history.md"
BEFORE=$(wc -l < "$P4/docs/slate/progress/history.md")
CLAUDE_PROJECT_ROOT="$P4" bash "$PLUGIN_ROOT/hooks/session-end.sh" >/dev/null 2>&1
AFTER=$(wc -l < "$P4/docs/slate/progress/history.md")
if [ "$BEFORE" -eq "$AFTER" ]; then
  pass "current.md con solo la plantilla no genera bloque en history.md"
else
  fail "se escribio un bloque vacio en history.md ($BEFORE -> $AFTER lineas)"
fi

if [ -z "$(git -C "$P4" log --oneline 2>/dev/null)" ]; then
  pass "SessionEnd no crea commits automaticos"
else
  fail "SessionEnd creo un commit automatico: $(git -C "$P4" log --oneline)"
fi

# Con trabajo real SI debe drenar.
cat > "$P4/docs/slate/progress/current.md" <<'EOF'
# Current work

### 2026-07-26 — FEAT-006 en vuelo
- **Status**: in_progress

<!-- This file is auto-managed by slate:tracking-progress. -->
EOF
CLAUDE_PROJECT_ROOT="$P4" bash "$PLUGIN_ROOT/hooks/session-end.sh" >/dev/null 2>&1
if grep -q 'FEAT-006 en vuelo' "$P4/docs/slate/progress/history.md"; then
  pass "current.md con trabajo real si se drena a history.md"
else
  fail "current.md con trabajo real NO se drenó"
fi

# --- 4b. Casos borde de has_work(): nunca perder trabajo real --------------
# El filtro de comentarios no puede tragarse contenido. Un '<!--' sin cerrar
# (plantilla editada a mano) haria invisible todo lo que venga detras.
drain_check() {
  local desc="$1" body="$2" want="$3"   # want: drain | skip
  local d="$TMP/edge$RANDOM"
  mkdir -p "$d/docs/slate/progress"
  printf '%s' "$body" > "$d/docs/slate/progress/current.md"
  printf '# Session history\n' > "$d/docs/slate/progress/history.md"
  local before after
  before=$(wc -l < "$d/docs/slate/progress/history.md")
  CLAUDE_PROJECT_ROOT="$d" bash "$PLUGIN_ROOT/hooks/session-end.sh" >/dev/null 2>&1
  after=$(wc -l < "$d/docs/slate/progress/history.md")
  if [ "$want" = "drain" ]; then
    [ "$after" -gt "$before" ] && pass "$desc" || fail "$desc (no se drenó)"
  else
    [ "$after" -eq "$before" ] && pass "$desc" || fail "$desc (se drenó de más)"
  fi
}

drain_check "trabajo tras un <!-- SIN cerrar si se drena" \
'# Current work

<!-- comentario que alguien dejo sin cerrar
### FEAT-007 en vuelo, trabajo REAL que no se puede perder
' drain

drain_check "trabajo ANTES de un comentario en la misma linea si se drena" \
'# Current work

### FEAT-008 en vuelo <!-- nota al margen -->
' drain

drain_check "comentario de una sola linea, sin trabajo, no se drena" \
'# Current work

_(none in flight)_

<!-- nada que ver aqui -->
' skip

# --- 4c. history_tail no puede filtrar trabajo real ------------------------
# Los patrones deben estar anclados: una linea de trabajo que MENCIONE la
# plantilla no puede desaparecer del contexto inyectado.
P4C="$TMP/p4c"
setup_project "$P4C"
cat > "$P4C/docs/slate/progress/history.md" <<'EOF'
# Session history

## 2026-07-03 — trabajo real
- Arreglado el fichero auto-managed by slate:tracking-progress
- Cerrado el comentario que faltaba -->
EOF
OUT4C=$(cd "$P4C" && printf '{"source":"startup"}' \
  | CLAUDE_PROJECT_ROOT="$P4C" bash "$PLUGIN_ROOT/hooks/session-start.sh" 2>/dev/null)
if printf '%s' "$OUT4C" | grep -q 'Cerrado el comentario'; then
  pass "history_tail no filtra lineas de trabajo que terminan en '-->'"
else
  fail "history_tail filtro una linea de trabajo legitima (obtenido: $OUT4C)"
fi

# --- 5. init.sh ya no genera el mapa del codigo ----------------------------
P5="$TMP/p5"
mkdir -p "$P5"
cp "$PLUGIN_ROOT/templates/init.sh" "$P5/init.sh"
(cd "$P5" && bash init.sh >/dev/null 2>&1)
if [ -e "$P5/docs/slate/progress/codebase-map.md" ]; then
  fail "init.sh sigue generando codebase-map.md (nadie lo lee)"
else
  pass "init.sh ya no genera codebase-map.md"
fi

# --- 6. Los candados vencidos se recogen ----------------------------------
P6="$TMP/p6"
mkdir -p "$P6"
git -C "$P6" init -q .
git -C "$P6" config user.email t@t.co; git -C "$P6" config user.name t
mkdir -p "$P6/.git/slate-sessions"
printf '{"branch":"main"}' > "$P6/.git/slate-sessions/ghost.lock"
touch -t "$(date -v-2H '+%Y%m%d%H%M' 2>/dev/null || date -d '2 hours ago' '+%Y%m%d%H%M')" \
  "$P6/.git/slate-sessions/ghost.lock"
printf '{"branch":"main"}' > "$P6/.git/slate-sessions/alive.lock"

printf '{"session_id":"me"}' | (cd "$P6" && CLAUDE_PROJECT_ROOT="$P6" \
  bash "$PLUGIN_ROOT/hooks/session-lock.sh" >/dev/null 2>&1)

if [ -e "$P6/.git/slate-sessions/ghost.lock" ]; then
  fail "el candado vencido (2h) sobrevivio al arranque"
else
  pass "el candado vencido se recoge al arrancar"
fi
if [ -e "$P6/.git/slate-sessions/alive.lock" ]; then
  pass "el candado fresco de un peer NO se borra"
else
  fail "se borro el candado fresco de un peer"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All 1.8.0 hygiene tests passed."
  exit 0
fi
echo "1.8.0 hygiene tests FAILED."
exit 1
