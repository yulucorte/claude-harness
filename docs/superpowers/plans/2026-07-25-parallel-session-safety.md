# Seguridad real entre sesiones paralelas — plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que Slate deje de simular aislamiento entre sesiones paralelas y pase a impedir, mediante denegación en `PreToolUse`, las operaciones que destruyen el trabajo de otra sesión viva en la misma carpeta.

**Architecture:** Cada sesión persiste su carpeta física (`cwd`) y los archivos que escribe en su lock compartido (`$GIT_COMMON_DIR/slate-sessions/<sid>.lock`). El guardián compara esos locks contra el `cwd` propio: si un peer vivo comparte carpeta, deniega las operaciones git que reescriben el árbol de trabajo (`checkout`, `switch`, `restore`, `reset --hard`) y avisa —sin bloquear— cuando ambos editan el mismo archivo. La creación automática de worktrees se elimina por inefectiva.

**Tech Stack:** Bash + Python 3 embebido (heredoc `PY`), hooks de Claude Code (`SessionStart`, `PostToolUse`, `PreToolUse`), git. Tests en bash puro bajo `tests/`.

**Spec:** `docs/superpowers/specs/2026-07-25-parallel-session-safety-design.md`

## Global Constraints

- **Los hooks nunca rompen una sesión.** Todo fallo (git ausente, lock ilegible, JSON corrupto, payload inesperado) termina en `sys.exit(0)` / `exit 0`. Nunca se propaga una excepción.
- **Degradación silenciosa ante locks antiguos.** Un lock sin `cwd` o sin `files` (escrito por una versión anterior) se ignora para las reglas nuevas; nunca provoca error ni denegación.
- **El guardián nunca deniega por falta de datos**, sólo por colisión confirmada.
- **TTL de lock vivo: `900` segundos.** Ya definido en `session-guardian.sh` y `session-lock.sh`. No se cambia.
- **Umbral de frescura: `300` segundos.** Peer con lock de edad ≤ 300 s → `deny`. Edad entre 300 s y 900 s → `warn`. Edad > 900 s → ignorado.
- **Tope de `files` en el lock: `20` entradas**, deduplicadas por `path`, conservando el `ts` más reciente.
- **Rutas siempre comparadas por ruta física** (`os.path.realpath` en Python, `pwd -P` en bash). En macOS `/var` es symlink de `/private/var` y sin esto la comparación de carpetas falla.
- **Los avisos usan `additionalContext`, nunca `permissionDecision`.** Un `permissionDecision: "allow"` saltaría el flujo normal de permisos; está prohibido en este plan.
- **Versión objetivo del plugin: `1.7.0`** en `.claude-plugin/plugin.json`.
- **Suite completa:** `bash scripts/self-test.sh` (autodescubre `tests/test-*.sh`).

## Nota sobre los ficheros de test

La spec enumera siete ficheros de prueba. Este plan consolida los tres que
ejercitan la misma regla del guardián en un único fichero con casos numerados,
porque comparten repo de prueba y helpers; separarlos sólo duplicaría el andamiaje.
El mapeo es:

| Test en la spec | Fichero en este plan |
| --- | --- |
| `test-session-lock-records-cwd.sh` | igual (Task 1) |
| `test-session-lock-no-worktree.sh` | igual (Task 2) |
| `test-guardian-blocks-checkout.sh` | `test-guardian-tree-ops.sh`, casos 1-2 y 4-5 (Task 3) |
| `test-guardian-graduated-staleness.sh` | `test-guardian-tree-ops.sh`, casos 6-7 (Task 3) |
| `test-guardian-reset-hard.sh` | `test-guardian-tree-ops.sh`, caso 3 (Task 3) |
| `test-heartbeat-records-files.sh` | igual (Task 4) |
| `test-guardian-warns-shared-file.sh` | `test-guardian-shared-file.sh` (Task 5) |

La cobertura no cambia: `test-guardian-tree-ops.sh` añade además el caso 8
(lock legado sin `cwd`), que ejercita la degradación silenciosa exigida en las
restricciones globales.

---

### Task 1: El lock registra la carpeta física de trabajo

**Files:**

- Modify: `hooks/session-lock.sh:92-95` (escritura del lock)
- Modify: `hooks/session-heartbeat.sh:72-84` (bloque de espejo de branch/head)
- Test: `tests/test-session-lock-records-cwd.sh` (crear)

**Interfaces:**

- Consumes: nada (primera tarea).
- Produces: el esquema de lock que consumen las Tasks 3 y 5:

  ```json
  {"branch": "<str>", "cwd": "<ruta física absoluta>", "worktree": "<str, legado>",
   "head": "<sha>", "started_at": "<ISO8601>", "files": []}
  ```

  El campo `cwd` se escribe **siempre**, tanto en sesión sola como en colisión. El campo `files` se inicializa como lista vacía y lo rellena la Task 4. El campo `worktree` se conserva por compatibilidad con locks antiguos y queda siempre `""`.

- [ ] **Step 1: Escribir el test que falla**

Crear `tests/test-session-lock-records-cwd.sh`:

```bash
#!/usr/bin/env bash
# El lock debe registrar SIEMPRE la carpeta fisica de trabajo (cwd), no solo al aislar.
set -e
trap 'echo "FAIL at line $LINENO"' ERR

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/session-lock.sh"

setup_repo() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q
  git -C "$dir" config user.email "t@t.com"
  git -C "$dir" config user.name "t"
  git -C "$dir" commit --allow-empty -q -m init
  echo "$dir"
}

lock_field() {
  # $1=ruta del lock  $2=campo
  python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],'MISSING'))" "$1" "$2"
}

# --- 1. sesion sola: el lock registra cwd fisico y files vacio ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
echo '{"session_id":"sess-solo"}' | CLAUDE_PROJECT_ROOT="$REPO" bash "$HOOK" >/dev/null

LOCK="$REAL/.git/slate-sessions/sess-solo.lock"
[ -f "$LOCK" ] || { echo "FAIL: no se creo el lock en $LOCK"; exit 1; }

GOT=$(lock_field "$LOCK" cwd)
[ "$GOT" = "$REAL" ] || { echo "FAIL: cwd esperado '$REAL', obtenido '$GOT'"; exit 1; }
echo "PASS: el lock de una sesion sola registra cwd fisico"

FILES=$(python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get('files','MISSING')))" "$LOCK")
[ "$FILES" = "[]" ] || { echo "FAIL: 'files' esperado [], obtenido $FILES"; exit 1; }
echo "PASS: el lock inicializa files como lista vacia"
rm -rf "$REPO"

# --- 2. segunda sesion en colision: tambien registra su cwd ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
BR=$(git -C "$REPO" branch --show-current)
mkdir -p "$REAL/.git/slate-sessions"
cat > "$REAL/.git/slate-sessions/sess-live.lock" <<EOF
{"branch": "$BR", "cwd": "$REAL", "worktree": "", "started_at": "2026-01-01T00:00:00Z", "files": []}
EOF

echo '{"session_id":"sess-second"}' | CLAUDE_PROJECT_ROOT="$REPO" bash "$HOOK" >/dev/null
GOT=$(lock_field "$REAL/.git/slate-sessions/sess-second.lock" cwd)
[ "$GOT" = "$REAL" ] || { echo "FAIL: en colision, cwd esperado '$REAL', obtenido '$GOT'"; exit 1; }
echo "PASS: el lock de una sesion en colision tambien registra cwd"
rm -rf "$REPO"

# --- 3. el heartbeat refresca cwd en un lock que no lo tenia (lock legado) ---
HB="$PLUGIN_ROOT/hooks/session-heartbeat.sh"
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
mkdir -p "$REAL/.git/slate-sessions"
cat > "$REAL/.git/slate-sessions/sess-legacy.lock" <<EOF
{"branch": "main", "worktree": "", "started_at": "2026-01-01T00:00:00Z"}
EOF

python3 -c "import json,sys; print(json.dumps({'session_id':'sess-legacy','cwd':sys.argv[1],'tool_name':'Bash','tool_input':{'command':'ls'}}))" "$REAL" \
  | bash "$HB" >/dev/null

GOT=$(lock_field "$REAL/.git/slate-sessions/sess-legacy.lock" cwd)
[ "$GOT" = "$REAL" ] || { echo "FAIL: el heartbeat no relleno cwd en lock legado: '$GOT'"; exit 1; }
echo "PASS: el heartbeat rellena cwd en locks legados"
rm -rf "$REPO"

echo "All session-lock cwd tests passed."
```

- [ ] **Step 2: Correr el test y verificar que falla**

Run: `bash tests/test-session-lock-records-cwd.sh`
Expected: FAIL con `cwd esperado '<ruta>', obtenido 'MISSING'` en el primer caso.

- [ ] **Step 3: Implementar en `session-lock.sh`**

En `hooks/session-lock.sh`, sustituir el bloque de escritura del lock (líneas 92-95):

```bash
python3 -c "import json,sys
data = {'branch': sys.argv[1], 'worktree': sys.argv[2], 'head': sys.argv[3], 'started_at': sys.argv[4]}
json.dump(data, open(sys.argv[5], 'w'))
" "$LOCK_BRANCH_OUT" "$WT_OUT" "$HEAD_OUT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LOCK_DIR/$SESSION_ID.lock" 2>/dev/null || true
```

por:

```bash
# Ruta FISICA de la carpeta de trabajo. El hook ya hizo `cd "$PROJECT_ROOT"` al
# arrancar, asi que `pwd -P` es la raiz del proyecto con symlinks resueltos
# (en macOS /var -> /private/var). El guardian compara carpetas por esta ruta.
CWD_OUT="$(pwd -P)"

python3 -c "import json,sys
data = {'branch': sys.argv[1], 'worktree': sys.argv[2], 'head': sys.argv[3],
        'started_at': sys.argv[4], 'cwd': sys.argv[5], 'files': []}
json.dump(data, open(sys.argv[6], 'w'))
" "$LOCK_BRANCH_OUT" "$WT_OUT" "$HEAD_OUT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CWD_OUT" "$LOCK_DIR/$SESSION_ID.lock" 2>/dev/null || true
```

- [ ] **Step 4: Implementar en `session-heartbeat.sh`**

En `hooks/session-heartbeat.sh`, dentro del bloque `# 2. mirror current branch/head`, justo después de las asignaciones de `br` y `hd` y antes de `if changed:`, añadir el espejo de `cwd`:

```python
br = git("branch", "--show-current").stdout.strip()
hd = git("rev-parse", "HEAD").stdout.strip()
changed = False
if br and d.get("branch") != br:
    d["branch"] = br
    changed = True
if hd and d.get("head") != hd:
    d["head"] = hd
    changed = True

# Carpeta fisica viva de esta sesion. Se refresca siempre: un lock escrito por
# una version anterior no la tiene, y el guardian la necesita para saber si un
# peer comparte carpeta con nosotros.
try:
    rp = os.path.realpath(cwd)
except Exception:
    rp = ""
if rp and d.get("cwd") != rp:
    d["cwd"] = rp
    changed = True
```

- [ ] **Step 5: Correr el test y verificar que pasa**

Run: `bash tests/test-session-lock-records-cwd.sh`
Expected: PASS en los tres casos, terminando en `All session-lock cwd tests passed.`

- [ ] **Step 6: Correr la suite completa para descartar regresiones**

Run: `bash scripts/self-test.sh`
Expected: `Results: N pass, 0 fail`

- [ ] **Step 7: Commit**

```bash
git add hooks/session-lock.sh hooks/session-heartbeat.sh tests/test-session-lock-records-cwd.sh
git commit -m "feat(lock): registrar la carpeta fisica de trabajo en el lock de sesion

El guardian necesita saber en que carpeta trabaja cada sesion viva para decidir
si pueden pisarse. Hasta ahora el lock solo guardaba 'worktree', y solo cuando
hubo aislamiento. Ahora 'cwd' se escribe siempre y el heartbeat lo refresca,
rellenandolo tambien en locks escritos por versiones anteriores."
```

---

### Task 2: Eliminar la creación automática de worktrees

**Files:**

- Modify: `hooks/session-lock.sh:70-90` (bloque de colisión)
- Modify: `tests/test-session-lock.sh:69-93` (caso que afirma el comportamiento eliminado)
- Test: `tests/test-session-lock-no-worktree.sh` (crear)

**Interfaces:**

- Consumes: el esquema de lock con `cwd` de la Task 1.
- Produces: en colisión, `hookSpecificOutput.additionalContext` con un texto informativo que **no** menciona rutas de worktree ni ramas `slate-session/*`, y **ningún** efecto en disco fuera del propio lock. La variable `WT_OUT` se conserva declarada y siempre vacía (compatibilidad de esquema).

- [ ] **Step 1: Escribir el test que falla**

Crear `tests/test-session-lock-no-worktree.sh`:

```bash
#!/usr/bin/env bash
# Una colision de rama NO debe crear worktrees ni ramas: el aislamiento por
# worktree es inefectivo (un hook SessionStart no puede reubicar una sesion ya
# arrancada). Debe emitir un aviso accionable y nada mas.
set -e
trap 'echo "FAIL at line $LINENO"' ERR

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/session-lock.sh"

setup_repo() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q
  git -C "$dir" config user.email "t@t.com"
  git -C "$dir" config user.name "t"
  git -C "$dir" commit --allow-empty -q -m init
  echo "$dir"
}

REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
BR=$(git -C "$REPO" branch --show-current)
mkdir -p "$REAL/.git/slate-sessions"
cat > "$REAL/.git/slate-sessions/sess-live.lock" <<EOF
{"branch": "$BR", "cwd": "$REAL", "worktree": "", "started_at": "2026-01-01T00:00:00Z", "files": []}
EOF

OUT=$(echo '{"session_id":"sess-colliding"}' | CLAUDE_PROJECT_ROOT="$REPO" bash "$HOOK")

# 1. avisa de la colision
echo "$OUT" | grep -q additionalContext \
  || { echo "FAIL: no hubo additionalContext en una colision real. Output: $OUT"; exit 1; }
echo "PASS: la colision emite additionalContext"

# 2. el aviso nombra la operacion peligrosa
echo "$OUT" | grep -q "checkout" \
  || { echo "FAIL: el aviso no menciona checkout. Output: $OUT"; exit 1; }
echo "PASS: el aviso nombra la operacion peligrosa"

# 3. NO crea worktrees en disco
[ -d "${REPO}.slate-worktrees" ] && { echo "FAIL: se creo el directorio de worktrees"; exit 1; }
WT_COUNT=$(git -C "$REPO" worktree list | wc -l | tr -d ' ')
[ "$WT_COUNT" = "1" ] || { echo "FAIL: se esperaba 1 worktree (el principal), hay $WT_COUNT"; exit 1; }
echo "PASS: la colision no crea worktrees"

# 4. NO crea ramas slate-session/*
git -C "$REPO" branch --list 'slate-session/*' | grep -q . \
  && { echo "FAIL: se creo una rama slate-session/*"; exit 1; }
echo "PASS: la colision no crea ramas slate-session/*"

# 5. el lock propio queda en la rama real, no en una inventada
LOCK_BR=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('branch',''))" \
  "$REAL/.git/slate-sessions/sess-colliding.lock")
[ "$LOCK_BR" = "$BR" ] || { echo "FAIL: el lock registra rama '$LOCK_BR', se esperaba '$BR'"; exit 1; }
echo "PASS: el lock registra la rama real"

rm -rf "$REPO"
echo "All no-worktree tests passed."
```

- [ ] **Step 2: Correr el test y verificar que falla**

Run: `bash tests/test-session-lock-no-worktree.sh`
Expected: FAIL en `se creo el directorio de worktrees`.

- [ ] **Step 3: Implementar — sustituir el bloque de colisión**

En `hooks/session-lock.sh`, sustituir íntegramente el bloque (líneas 70-90):

```bash
if [ "$COLLISION" -eq 1 ]; then
  SHORT_ID="${SESSION_ID:0:8}"
  NEW_BRANCH="slate-session/${SHORT_ID}"
  PARENT_DIR="$(dirname "$PROJECT_ROOT")"
  BASE_NAME="$(basename "$PROJECT_ROOT")"
  WT_PATH="${PARENT_DIR}/${BASE_NAME}.slate-worktrees/${SHORT_ID}"

  mkdir -p "$(dirname "$WT_PATH")" 2>/dev/null
  if git worktree add "$WT_PATH" -b "$NEW_BRANCH" "$CURRENT_BRANCH" >/dev/null 2>&1; then
    LOCK_BRANCH_OUT="$NEW_BRANCH"
    WT_OUT="$WT_PATH"
    HEAD_OUT="$(git -C "$WT_PATH" rev-parse HEAD 2>/dev/null || echo "$HEAD_OUT")"
    CONTEXT="Otra sesion de Claude Code ya esta activa en la rama '${CURRENT_BRANCH}' de este repo. Para no pisarle la rama, el indice de git, ni el stash, esta sesion quedo aislada en una copia separada del repo:

  ${WT_PATH}  (rama: ${NEW_BRANCH})

A partir de ahora, para CUALQUIER comando git (branch, commit, push, stash, etc.) usa esa carpeta: cd ${WT_PATH} && git ... No operes sobre ${PROJECT_ROOT} hasta que la otra sesion termine."
  else
    CONTEXT="AVISO: otra sesion ya esta activa en la rama '${CURRENT_BRANCH}' y no pude aislar esta sesion en un worktree separado (fallo 'git worktree add'). Tene cuidado: pueden pisarse la rama, el indice o el stash."
  fi
fi
```

por:

```bash
# Aviso informativo, sin efectos en disco.
#
# Hasta 1.6.1 este bloque creaba una worktree dedicada y le pedia al agente que
# se mudara. No funciona: un hook SessionStart no puede cambiar el directorio de
# trabajo de una sesion ya arrancada, y la peticion compite (y pierde) contra el
# resto del contexto del agente. Verificado en vivo: las worktrees generadas asi
# quedaron siempre vacias. El mecanismo pagaba el costo (carpetas acumuladas)
# sin dar el beneficio (aislamiento). La proteccion real la aplica ahora
# session-guardian, denegando las operaciones que reescriben el arbol.
if [ "$COLLISION" -eq 1 ]; then
  CONTEXT="Otra sesion de Claude Code ya esta activa en la rama '${CURRENT_BRANCH}' de esta misma carpeta:

  ${PROJECT_ROOT}

NO cambies de rama mientras dure: 'git checkout', 'git switch', 'git restore' y 'git reset --hard' reescriben en disco los archivos que la otra sesion esta editando, sin que su agente se entere. session-guardian bloqueara esas operaciones.

Editar archivos distintos sobre la rama actual es seguro. Si necesitas trabajar en OTRA rama en paralelo, abre una sesion de Claude Code NUEVA en otra carpeta: el aislamiento solo funciona si la sesion arranca alli, no si se le pide mudarse."
fi
```

Nota: `LOCK_BRANCH_OUT`, `WT_OUT` y `HEAD_OUT` siguen declarados más arriba (líneas 66-68) y ya no se reasignan. `WT_OUT` queda siempre `""`, que es lo que la Task 1 escribe en el campo legado `worktree`.

- [ ] **Step 4: Actualizar el test existente que afirma el comportamiento eliminado**

En `tests/test-session-lock.sh`, sustituir íntegramente el bloque de las líneas 69-93 por:

```bash
# --- Test: existing SAME-branch FRESH lock -> colision real, avisa SIN crear worktree ---
REPO=$(setup_repo)
BR=$(git -C "$REPO" branch --show-current)
mkdir -p "$REPO/.git/slate-sessions"
cat > "$REPO/.git/slate-sessions/sess-live.lock" <<EOF
{"branch": "$BR", "worktree": "", "started_at": "2026-01-01T00:00:00Z"}
EOF

OUTPUT4=$(echo '{"session_id":"sess-colliding"}' | CLAUDE_PROJECT_ROOT="$REPO" bash "$HOOK")
echo "$OUTPUT4" | grep -q additionalContext || { echo "FAIL: no additionalContext on real collision. Output: $OUTPUT4"; exit 1; }
echo "$OUTPUT4" | grep -q "checkout" || { echo "FAIL: el aviso de colision no nombra la operacion peligrosa. Output: $OUTPUT4"; exit 1; }

REPO_PARENT="$(dirname "$REPO")"
REPO_BASE="$(basename "$REPO")"
[ -d "${REPO_PARENT}/${REPO_BASE}.slate-worktrees" ] && { echo "FAIL: se creo un worktree; el aislamiento automatico fue eliminado"; exit 1; }

LOCK_FILE="$REPO/.git/slate-sessions/sess-colliding.lock"
grep -q "slate-session/" "$LOCK_FILE" && { echo "FAIL: el lock registra una rama slate-session/* inventada"; exit 1; }
echo "PASS: real branch collision warns without creating a worktree"

rm -rf "$REPO" 2>/dev/null
```

- [ ] **Step 5: Correr ambos tests y verificar que pasan**

Run: `bash tests/test-session-lock-no-worktree.sh && bash tests/test-session-lock.sh`
Expected: ambos terminan en PASS, sin FAIL.

- [ ] **Step 6: Correr la suite completa**

Run: `bash scripts/self-test.sh`
Expected: `Results: N pass, 0 fail`. En particular `test-session-lock-worktree-visibility.sh` y `test-session-lock-cleanup.sh` deben seguir pasando sin tocarlos: el primero valida que el directorio de locks es compartido entre worktrees creadas a mano (premisa de este diseño), el segundo que la limpieza no borra worktrees ajenas.

- [ ] **Step 7: Commit**

```bash
git add hooks/session-lock.sh tests/test-session-lock.sh tests/test-session-lock-no-worktree.sh
git commit -m "fix(lock): eliminar la creacion automatica de worktrees

Un hook SessionStart no puede reubicar una sesion ya arrancada, asi que el
aviso de mudarse nunca se obedecia: las worktrees generadas quedaban vacias.
El mecanismo pagaba el costo (carpetas acumuladas junto a cada repo) sin dar
el beneficio. Se sustituye por un aviso accionable; la proteccion real pasa a
session-guardian."
```

---

### Task 3: El guardián deniega las reescrituras del árbol de trabajo

**Files:**

- Modify: `hooks/session-guardian.sh` — `classify()` (bloque de verbos, ~líneas 78-86), recolección de locks foráneos (~líneas 108-122), y nueva regla antes del bloque de emisión
- Test: `tests/test-guardian-tree-ops.sh` (crear)

**Interfaces:**

- Consumes: el campo `cwd` del lock (Task 1), y el `mtime` del fichero de lock como medida de frescura.
- Produces: para las Tasks 4 y 5, la variable `now` y la lista `foreign`, donde cada entrada lleva ahora `d["_mtime"]` (float, epoch) además del ya existente `d["_id"]`.

- [ ] **Step 1: Escribir el test que falla**

Crear `tests/test-guardian-tree-ops.sh`:

```bash
#!/usr/bin/env bash
# El guardian debe denegar las operaciones que reescriben el arbol de trabajo
# cuando un peer VIVO comparte la MISMA carpeta. En carpetas distintas no
# interfiere. Con un lock envejecido, avisa en vez de bloquear.
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

payload() {
  # $1=session_id $2=cwd $3=command
  python3 -c "import json,sys; print(json.dumps({'session_id': sys.argv[1], 'cwd': sys.argv[2], 'tool_name': 'Bash', 'tool_input': {'command': sys.argv[3]}}))" "$1" "$2" "$3"
}

write_peer_lock() {
  # $1=repo $2=lockname $3=cwd_del_peer
  mkdir -p "$1/.git/slate-sessions"
  python3 -c "import json,sys; json.dump({'branch':'main','cwd':sys.argv[2],'worktree':'','head':'','started_at':'2026-01-01T00:00:00Z','files':[]}, open(sys.argv[1],'w'))" \
    "$1/.git/slate-sessions/$2.lock" "$3"
}

age_lock() {
  # $1=ruta del lock  $2=segundos de antiguedad
  python3 -c "import os,sys,time; p=sys.argv[1]; t=time.time()-float(sys.argv[2]); os.utime(p,(t,t))" "$1" "$2"
}

is_deny() { echo "$1" | grep -q '"permissionDecision": "deny"'; }
is_warn() { echo "$1" | grep -q '"additionalContext"'; }

# --- 1. peer fresco en la MISMA carpeta -> checkout DENEGADO ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
write_peer_lock "$REPO" "peer" "$REAL"
OUT=$(payload "yo" "$REAL" "git checkout -b otra" | bash "$HOOK")
is_deny "$OUT" || { echo "FAIL: checkout con peer fresco en la misma carpeta no fue denegado: $OUT"; exit 1; }
echo "PASS: checkout denegado con peer vivo en la misma carpeta"
rm -rf "$REPO"

# --- 2. mismos verbos: switch y restore tambien denegados ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
write_peer_lock "$REPO" "peer" "$REAL"
for CMD in "git switch main" "git restore ."; do
  OUT=$(payload "yo" "$REAL" "$CMD" | bash "$HOOK")
  is_deny "$OUT" || { echo "FAIL: '$CMD' no fue denegado: $OUT"; exit 1; }
done
echo "PASS: switch y restore tambien denegados"
rm -rf "$REPO"

# --- 3. reset --hard denegado; reset --soft NO ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
write_peer_lock "$REPO" "peer" "$REAL"
OUT=$(payload "yo" "$REAL" "git reset --hard HEAD~1" | bash "$HOOK")
is_deny "$OUT" || { echo "FAIL: 'reset --hard' no fue denegado: $OUT"; exit 1; }
OUT=$(payload "yo" "$REAL" "git reset --soft HEAD~1" | bash "$HOOK")
is_deny "$OUT" && { echo "FAIL: 'reset --soft' no toca el arbol y no debe denegarse: $OUT"; exit 1; }
echo "PASS: reset --hard denegado, reset --soft permitido"
rm -rf "$REPO"

# --- 4. peer en OTRA carpeta -> no interfiere ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
OTHER=$(mktemp -d)
write_peer_lock "$REPO" "peer" "$(cd "$OTHER" && pwd -P)"
OUT=$(payload "yo" "$REAL" "git checkout -b otra" | bash "$HOOK")
is_deny "$OUT" && { echo "FAIL: peer en otra carpeta no debe bloquear: $OUT"; exit 1; }
echo "PASS: peer en carpeta distinta no interfiere"
rm -rf "$REPO" "$OTHER"

# --- 5. sesion sola -> nunca se bloquea ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
OUT=$(payload "yo" "$REAL" "git checkout -b otra" | bash "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: sesion sola produjo output: $OUT"; exit 1; }
echo "PASS: una sesion sola nunca se bloquea"
rm -rf "$REPO"

# --- 6. peer TIBIO (>300s, <900s) -> avisa, no bloquea ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
write_peer_lock "$REPO" "peer" "$REAL"
age_lock "$REPO/.git/slate-sessions/peer.lock" 600
OUT=$(payload "yo" "$REAL" "git checkout -b otra" | bash "$HOOK")
is_deny "$OUT" && { echo "FAIL: peer tibio (600s) no debe denegar: $OUT"; exit 1; }
is_warn "$OUT" || { echo "FAIL: peer tibio (600s) debe avisar: $OUT"; exit 1; }
echo "PASS: peer tibio avisa sin bloquear"
rm -rf "$REPO"

# --- 7. peer RANCIO (>900s) -> ignorado por completo ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
write_peer_lock "$REPO" "peer" "$REAL"
age_lock "$REPO/.git/slate-sessions/peer.lock" 1200
OUT=$(payload "yo" "$REAL" "git checkout -b otra" | bash "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: peer rancio (1200s) debe ignorarse: $OUT"; exit 1; }
echo "PASS: peer rancio se ignora"
rm -rf "$REPO"

# --- 8. lock legado sin cwd -> se ignora para esta regla, nunca rompe ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
mkdir -p "$REPO/.git/slate-sessions"
echo '{"branch": "main", "worktree": "", "started_at": "2026-01-01T00:00:00Z"}' \
  > "$REPO/.git/slate-sessions/legacy.lock"
OUT=$(payload "yo" "$REAL" "git checkout -b otra" | bash "$HOOK")
is_deny "$OUT" && { echo "FAIL: un lock sin cwd no debe denegar: $OUT"; exit 1; }
echo "PASS: lock legado sin cwd se ignora sin romper"
rm -rf "$REPO"

echo "All guardian tree-op tests passed."
```

- [ ] **Step 2: Correr el test y verificar que falla**

Run: `bash tests/test-guardian-tree-ops.sh`
Expected: FAIL en el caso 1 — `checkout con peer fresco en la misma carpeta no fue denegado:` seguido de salida vacía (hoy `classify()` no reconoce `checkout`).

- [ ] **Step 3: Reconocer los verbos que reescriben el árbol en `classify()`**

En `hooks/session-guardian.sh`, dentro de `classify()`, sustituir el bloque de clasificación de verbos:

```python
        verb = toks[j]
        if verb in ("commit", "push", "merge", "rebase", "cherry-pick"):
            verbs.add(verb)
        elif verb == "stash":
```

por:

```python
        verb = toks[j]
        if verb in ("commit", "push", "merge", "rebase", "cherry-pick"):
            verbs.add(verb)
        elif verb in ("checkout", "switch", "restore"):
            # Reescriben el arbol de trabajo en disco. Prefijo "tree:" para no
            # mezclarlos con los verbos de integracion de las reglas 1-3.
            verbs.add("tree:" + verb)
        elif verb == "reset":
            # Solo --hard toca los archivos en disco; --soft y --mixed no.
            if "--hard" in toks[j + 1:]:
                verbs.add("tree:reset")
        elif verb == "stash":
```

- [ ] **Step 4: Guardar la frescura de cada lock foráneo**

En el bloque `# --- gather OTHER live locks ---`, sustituir:

```python
    try:
        if now - os.path.getmtime(lp) > TTL:
            continue
        d = json.load(open(lp))
    except Exception:
        continue
    d["_id"] = lid
    foreign.append(d)
```

por:

```python
    try:
        mt = os.path.getmtime(lp)
        if now - mt > TTL:
            continue
        d = json.load(open(lp))
    except Exception:
        continue
    if not isinstance(d, dict):
        continue
    d["_id"] = lid
    d["_mtime"] = mt
    foreign.append(d)
```

- [ ] **Step 5: Añadir la regla de reescritura del árbol**

En `hooks/session-guardian.sh`, justo después de `integ = verbs & {"push", "merge", "rebase", "cherry-pick"}` y **antes** de `# Rule 1`, insertar:

```python
FRESH = 300  # s. Peer con lock mas nuevo que esto = vivo casi con certeza.

# Rule 0 — reescritura del arbol: un peer vivo en la MISMA carpeta fisica.
# Es la unica clase de dano catastrofico: 'checkout'/'switch'/'restore'/
# 'reset --hard' reescriben los archivos que el otro agente esta editando, en
# vivo y sin que se entere. En carpetas distintas no hay nada que proteger.
tree_ops = sorted(v.split(":", 1)[1] for v in verbs if v.startswith("tree:"))
if tree_ops:
    try:
        my_dir = os.path.realpath(cwd)
    except Exception:
        my_dir = ""
    for d in foreign:
        peer_cwd = (d.get("cwd") or "").strip()
        if not my_dir or not peer_cwd:
            continue  # lock legado sin cwd: se ignora, nunca se deniega a ciegas
        try:
            if os.path.realpath(peer_cwd) != my_dir:
                continue  # carpetas distintas: ya estan aislados
        except Exception:
            continue
        age = int(now - d.get("_mtime", 0))
        if age <= FRESH:
            denies.append(
                "Otra sesion de Claude Code esta viva en ESTA MISMA carpeta (candado %s, "
                "actividad hace %ss). 'git %s' reescribiria en disco los archivos que esa "
                "sesion esta editando ahora mismo, sin que su agente se entere. "
                "Bloqueado por session-guardian. Trabaja sobre la rama actual, o abre una "
                "sesion nueva en otra carpeta si necesitas otra rama."
                % (d["_id"][:8], age, tree_ops[0])
            )
        else:
            warns.append(
                "hay un candado de otra sesion en esta misma carpeta (%s) sin actividad desde "
                "hace %ss; puede estar muerta sin limpiar. 'git %s' reescribe el arbol de "
                "trabajo: confirma que nadie mas esta editando aqui antes de seguir."
                % (d["_id"][:8], age, tree_ops[0])
            )
        break
```

- [ ] **Step 6: Correr el test y verificar que pasa**

Run: `bash tests/test-guardian-tree-ops.sh`
Expected: los 8 casos en PASS, terminando en `All guardian tree-op tests passed.`

- [ ] **Step 7: Correr la suite completa**

Run: `bash scripts/self-test.sh`
Expected: `Results: N pass, 0 fail`. `test-session-guardian.sh` debe seguir pasando sin cambios: sus casos usan `commit`/`push`/`stash`, que no entran en la regla nueva.

- [ ] **Step 8: Commit**

```bash
git add hooks/session-guardian.sh tests/test-guardian-tree-ops.sh
git commit -m "feat(guardian): denegar reescrituras del arbol con un peer en la misma carpeta

checkout, switch, restore y reset --hard reescriben los archivos que otra
sesion viva esta editando, en vivo y sin aviso. Era la unica clase de dano
catastrofico y la unica operacion que el guardian no vigilaba.

La respuesta es graduada por frescura del lock del peer: <=300s deniega,
300-900s avisa (puede ser una sesion muerta sin limpiar), >900s se ignora.
Asi un candado huerfano no bloquea un cambio de rama legitimo."
```

---

### Task 4: El heartbeat registra los archivos escritos

**Files:**

- Modify: `hooks/session-heartbeat.sh` — importar `time`, leer `tool_name`/`tool_input`, y actualizar `files` en el bloque de espejo
- Test: `tests/test-heartbeat-records-files.sh` (crear)

**Interfaces:**

- Consumes: el campo `files` del lock inicializado en la Task 1.
- Produces: para la Task 5, `files` como lista de objetos `{"path": "<ruta absoluta>", "ts": <int epoch>}`, ordenada de más antiguo a más reciente, deduplicada por `path`, con **máximo 20** entradas.

- [ ] **Step 1: Escribir el test que falla**

Crear `tests/test-heartbeat-records-files.sh`:

```bash
#!/usr/bin/env bash
# El heartbeat debe anotar en el lock los archivos que esta sesion escribe,
# deduplicados por ruta y acotados a 20 entradas.
set -e
trap 'echo "FAIL at line $LINENO"' ERR

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/session-heartbeat.sh"

setup_repo() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q
  git -C "$dir" config user.email "t@t.com"
  git -C "$dir" config user.name "t"
  git -C "$dir" commit --allow-empty -q -m init
  mkdir -p "$dir/.git/slate-sessions"
  printf '{"branch": "main", "cwd": "%s", "worktree": "", "head": "", "started_at": "2026-01-01T00:00:00Z", "files": []}' \
    "$(cd "$dir" && pwd -P)" > "$dir/.git/slate-sessions/sess-hb.lock"
  echo "$dir"
}

beat() {
  # $1=cwd $2=tool_name $3=file_path
  python3 -c "import json,sys; print(json.dumps({'session_id':'sess-hb','cwd':sys.argv[1],'tool_name':sys.argv[2],'tool_input':{'file_path':sys.argv[3]}}))" "$1" "$2" "$3" \
    | bash "$HOOK" >/dev/null
}

paths() {
  python3 -c "import json,sys; print(','.join(e['path'] for e in json.load(open(sys.argv[1])).get('files',[])))" "$1"
}
count() {
  python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('files',[])))" "$1"
}

# --- 1. un Write queda anotado con ruta y ts ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
LOCK="$REAL/.git/slate-sessions/sess-hb.lock"
beat "$REAL" "Write" "$REAL/a.txt"
[ "$(paths "$LOCK")" = "$REAL/a.txt" ] || { echo "FAIL: Write no quedo anotado: $(paths "$LOCK")"; exit 1; }
TS=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['files'][0].get('ts',0))" "$LOCK")
[ "$TS" -gt 0 ] || { echo "FAIL: la entrada no tiene ts valido: $TS"; exit 1; }
echo "PASS: un Write queda anotado con path y ts"

# --- 2. Edit tambien se anota; herramientas de lectura no ---
beat "$REAL" "Edit" "$REAL/b.txt"
beat "$REAL" "Read" "$REAL/c.txt"
[ "$(paths "$LOCK")" = "$REAL/a.txt,$REAL/b.txt" ] || { echo "FAIL: se esperaba a,b; hay: $(paths "$LOCK")"; exit 1; }
echo "PASS: Edit se anota y Read no"

# --- 3. reescribir el mismo archivo deduplica y lo mueve al final ---
beat "$REAL" "Write" "$REAL/a.txt"
[ "$(paths "$LOCK")" = "$REAL/b.txt,$REAL/a.txt" ] || { echo "FAIL: no deduplico por path: $(paths "$LOCK")"; exit 1; }
echo "PASS: deduplica por path conservando el mas reciente"
rm -rf "$REPO"

# --- 4. tope de 20 entradas ---
REPO=$(setup_repo)
REAL=$(cd "$REPO" && pwd -P)
LOCK="$REAL/.git/slate-sessions/sess-hb.lock"
for i in $(seq 1 25); do beat "$REAL" "Write" "$REAL/f$i.txt"; done
[ "$(count "$LOCK")" = "20" ] || { echo "FAIL: se esperaban 20 entradas, hay $(count "$LOCK")"; exit 1; }
paths "$LOCK" | grep -q "f25.txt" || { echo "FAIL: falta la escritura mas reciente"; exit 1; }
paths "$LOCK" | grep -q "f1.txt" && { echo "FAIL: no se descarto la mas antigua"; exit 1; }
echo "PASS: la lista se acota a las 20 mas recientes"
rm -rf "$REPO"

# --- 5. sin lock propio no hace nada y no rompe ---
REPO=$(mktemp -d)
git -C "$REPO" init -q
REAL=$(cd "$REPO" && pwd -P)
beat "$REAL" "Write" "$REAL/x.txt"
echo "PASS: sin lock propio termina limpio"
rm -rf "$REPO"

echo "All heartbeat file-tracking tests passed."
```

- [ ] **Step 2: Correr el test y verificar que falla**

Run: `bash tests/test-heartbeat-records-files.sh`
Expected: FAIL en el caso 1 — `Write no quedo anotado:` con lista vacía.

- [ ] **Step 3: Implementar en `session-heartbeat.sh`**

Primero, añadir `time` a los imports. Sustituir:

```python
import sys, os, json, subprocess
```

por:

```python
import sys, os, json, subprocess, time
```

Segundo, leer la herramienta del payload. Justo después de la línea que calcula `cwd` y antes de `if not os.path.isdir(cwd):`, insertar:

```python
# Herramienta que acaba de ejecutarse. Solo las de escritura dejan rastro en el
# lock: son las unicas que pueden pisar el trabajo de otra sesion.
tool = (payload.get("tool_name") or "").strip()
tool_input = payload.get("tool_input") or {}
written = ""
if tool in ("Write", "Edit", "NotebookEdit"):
    written = (tool_input.get("file_path") or tool_input.get("notebook_path") or "").strip()
```

Tercero, registrar el archivo en el bloque de espejo, después del bloque de `cwd` de la Task 1 y antes de `if changed:`:

```python
# Archivos escritos recientemente por esta sesion. El guardian los usa para
# avisar cuando dos sesiones de la misma carpeta editan lo mismo. Se acotan a
# las 20 mas recientes, deduplicadas por ruta, para que el lock no crezca.
if written:
    prev = d.get("files")
    if not isinstance(prev, list):
        prev = []
    files = [e for e in prev if isinstance(e, dict) and e.get("path") != written]
    files.append({"path": written, "ts": int(time.time())})
    d["files"] = files[-20:]
    changed = True
```

- [ ] **Step 4: Correr el test y verificar que pasa**

Run: `bash tests/test-heartbeat-records-files.sh`
Expected: los 5 casos en PASS, terminando en `All heartbeat file-tracking tests passed.`

- [ ] **Step 5: Correr la suite completa**

Run: `bash scripts/self-test.sh`
Expected: `Results: N pass, 0 fail`

- [ ] **Step 6: Commit**

```bash
git add hooks/session-heartbeat.sh tests/test-heartbeat-records-files.sh
git commit -m "feat(heartbeat): anotar en el lock los archivos que escribe la sesion

Guarda las 20 rutas mas recientes escritas via Write/Edit/NotebookEdit,
deduplicadas por ruta. El guardian las usa para avisar cuando dos sesiones de
la misma carpeta editan el mismo archivo."
```

---

### Task 5: El guardián avisa (sin bloquear) por archivo compartido

**Files:**

- Modify: `hooks/hooks.json` — nueva entrada `PreToolUse` con matcher `Write|Edit|NotebookEdit`
- Modify: `hooks/session-guardian.sh` — parseo del payload por herramienta y rama de modo fichero
- Test: `tests/test-guardian-shared-file.sh` (crear)

**Interfaces:**

- Consumes: `files` del lock (Task 4) y `cwd` del lock (Task 1); `foreign` con `_mtime` (Task 3).
- Produces: nada para tareas posteriores. Emite exclusivamente `hookSpecificOutput.additionalContext` — **nunca** `permissionDecision`.

- [ ] **Step 1: Escribir el test que falla**

Crear `tests/test-guardian-shared-file.sh`:

```bash
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
```

- [ ] **Step 2: Correr el test y verificar que falla**

Run: `bash tests/test-guardian-shared-file.sh`
Expected: FAIL en el caso 1 — `no aviso del archivo compartido:` con salida vacía (hoy el guardián sale antes por falta de `command` en `tool_input`).

- [ ] **Step 3: Parsear el payload según la herramienta**

En `hooks/session-guardian.sh`, sustituir el bloque de parseo:

```python
sid = (payload.get("session_id") or "").strip()
cmd = (payload.get("tool_input") or {}).get("command") or ""
cwd = (payload.get("cwd") or "").strip()
if not sid or not cmd:
    sys.exit(0)
```

por:

```python
sid = (payload.get("session_id") or "").strip()
tool = (payload.get("tool_name") or "").strip()
tool_input = payload.get("tool_input") or {}
cmd = tool_input.get("command") or ""
cwd = (payload.get("cwd") or "").strip()
if not sid:
    sys.exit(0)

# Dos modos. "file": una escritura, solo puede AVISAR de un choque de archivo.
# "bash": un comando git, es el unico que puede DENEGAR.
if tool in ("Write", "Edit", "NotebookEdit"):
    mode = "file"
    target = (tool_input.get("file_path") or tool_input.get("notebook_path") or "").strip()
    if not target:
        sys.exit(0)
else:
    mode = "bash"
    target = ""
    if not cmd:
        sys.exit(0)
```

- [ ] **Step 4: Clasificar sólo en modo bash**

Sustituir:

```python
verbs, stash = classify(cmd)
if not verbs:
    sys.exit(0)
```

por:

```python
if mode == "bash":
    verbs, stash = classify(cmd)
    if not verbs:
        sys.exit(0)
else:
    verbs, stash = set(), {"sub": None, "explicit": False}
```

- [ ] **Step 5: Añadir la rama de modo fichero**

Justo después de `if not foreign: sys.exit(0)` y **antes** de `actual_branch = ...`, insertar:

```python
# --- modo fichero: avisar si un peer de la MISMA carpeta escribio este archivo -
# Nunca deniega. El choque de archivo es localizado, visible en 'git status' y
# recuperable; bloquearlo generaria friccion constante sin evitar dano real.
if mode == "file":
    try:
        my_dir = os.path.realpath(cwd)
    except Exception:
        sys.exit(0)
    for d in foreign:
        peer_cwd = (d.get("cwd") or "").strip()
        if not peer_cwd:
            continue
        try:
            if os.path.realpath(peer_cwd) != my_dir:
                continue
        except Exception:
            continue
        entries = d.get("files")
        if not isinstance(entries, list):
            continue
        for e in entries:
            if not isinstance(e, dict) or e.get("path") != target:
                continue
            try:
                ago = int(now - float(e.get("ts") or 0))
            except Exception:
                continue
            if ago > TTL:
                continue
            msg = ("session-guardian: otra sesion viva en esta misma carpeta (candado %s) "
                   "escribio '%s' hace %ss. Relee el archivo antes de editarlo: tu version "
                   "en contexto puede estar desactualizada y tu escritura pisaria su cambio."
                   % (d["_id"][:8], os.path.basename(target), ago))
            print(json.dumps({
                "systemMessage": "⚠️ " + msg,
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "additionalContext": msg,
                }
            }))
            sys.exit(0)
    sys.exit(0)
```

- [ ] **Step 6: Registrar el matcher en `hooks.json`**

En `hooks/hooks.json`, sustituir el bloque `PreToolUse`:

```json
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-guardian.sh" }
        ]
      }
    ]
```

por:

```json
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-guardian.sh" }
        ]
      },
      {
        "matcher": "Write|Edit|NotebookEdit",
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-guardian.sh" }
        ]
      }
    ]
```

- [ ] **Step 7: Correr el test y verificar que pasa**

Run: `bash tests/test-guardian-shared-file.sh`
Expected: los 5 casos en PASS, terminando en `All guardian shared-file tests passed.`

- [ ] **Step 8: Correr la suite completa**

Run: `bash scripts/self-test.sh`
Expected: `Results: N pass, 0 fail`. `test-session-guardian.sh` y `test-guardian-tree-ops.sh` deben seguir pasando: sus payloads llevan `tool_name: "Bash"` o carecen del campo, y ambos casos entran en modo `bash`.

- [ ] **Step 9: Commit**

```bash
git add hooks/session-guardian.sh hooks/hooks.json tests/test-guardian-shared-file.sh
git commit -m "feat(guardian): avisar cuando dos sesiones editan el mismo archivo

Al bloquear los cambios de rama, dos sesiones de la misma carpeta quedan en la
misma rama, asi que editar el mismo archivo se vuelve mas probable. El guardian
lo detecta via los archivos anotados en el lock del peer y avisa.

Aviso, nunca bloqueo: el choque de archivo es localizado, visible en git status
y recuperable. Se emite por additionalContext, sin tocar el flujo de permisos."
```

---

### Task 6: Versión del plugin y CHANGELOG

**Files:**

- Modify: `.claude-plugin/plugin.json` (campo `version`)
- Modify: `CHANGELOG.md` (nueva entrada al principio)

**Interfaces:**

- Consumes: el trabajo de las Tasks 1-5.
- Produces: nada. Es el paso que hace que el cambio llegue al uso real — Claude Code cachea el plugin por versión en `~/.claude/plugins/cache/slate-direct/slate/<version>/`, así que sin subir la versión los hooks nuevos no se cargan.

- [ ] **Step 1: Verificar la versión actual**

Run: `python3 -c "import json;print(json.load(open('.claude-plugin/plugin.json'))['version'])"`
Expected: `1.6.1`

- [ ] **Step 2: Subir la versión menor**

En `.claude-plugin/plugin.json`, cambiar `"version": "1.6.1"` por `"version": "1.7.0"`.

- [ ] **Step 3: Escribir la entrada de CHANGELOG**

Añadir al principio de `CHANGELOG.md`, justo debajo del encabezado del archivo y antes de la entrada más reciente:

```markdown
## 1.7.0

**Seguridad real entre sesiones paralelas (FEAT-003).** El aislamiento
automático por worktree se elimina: un hook `SessionStart` no puede reubicar una
sesión ya arrancada, así que el aviso de mudarse nunca se obedecía y las
worktrees generadas quedaban vacías. Pagaba el costo (carpetas acumuladas junto
a cada repo) sin dar el beneficio.

La protección pasa a `session-guardian`, que sí se hace cumplir:

- **Nuevo:** el lock de sesión registra la carpeta física de trabajo (`cwd`) y
  los últimos 20 archivos escritos (`files`).
- **Nuevo:** se deniegan `checkout`, `switch`, `restore` y `reset --hard`
  cuando otra sesión viva comparte la misma carpeta — la única operación que
  reescribe en disco el trabajo ajeno. Respuesta graduada: peer con actividad en
  los últimos 300 s deniega; entre 300 s y 900 s avisa; más allá se ignora, así
  un candado huérfano no bloquea un cambio de rama legítimo.
- **Nuevo:** aviso (nunca bloqueo) al escribir un archivo que otra sesión de la
  misma carpeta tocó en los últimos 900 s.
- **Eliminado:** la creación automática de `<repo>.slate-worktrees/<id>` y las
  ramas `slate-session/*`. Las worktrees existentes no se tocan; se pueden
  borrar a mano con `git worktree remove` + `git branch -D`.

Los locks escritos por versiones anteriores (sin `cwd` ni `files`) se ignoran
para las reglas nuevas y nunca provocan una denegación.

**Límite conocido:** esto hace que el trabajo paralelo inseguro falle de forma
ruidosa, no que sea seguro. Para trabajar en ramas distintas a la vez hay que
abrir cada sesión en su propia carpeta; el aislamiento sólo funciona si la
sesión arranca allí.
```

- [ ] **Step 4: Verificar la suite completa una última vez**

Run: `bash scripts/self-test.sh`
Expected: `Results: N pass, 0 fail`

- [ ] **Step 5: Verificar el JSON del plugin y de los hooks**

Run: `python3 -c "import json;print(json.load(open('.claude-plugin/plugin.json'))['version']);json.load(open('hooks/hooks.json'));print('hooks.json OK')"`
Expected:

```text
1.7.0
hooks.json OK
```

- [ ] **Step 6: Commit**

```bash
git add .claude-plugin/plugin.json CHANGELOG.md
git commit -m "chore(release): 1.7.0 — seguridad real entre sesiones paralelas

Claude Code cachea el plugin por version, asi que sin este bump los hooks
nuevos no se cargan en uso real."
```

---

## Verificación final

Tras la Task 6, comprobar los criterios de aceptación de la spec contra el repo:

- [ ] Una segunda sesión en un repo con otra sesión viva no crea ningún directorio nuevo — cubierto por `test-session-lock-no-worktree.sh` casos 3 y 4.
- [ ] Con dos sesiones vivas en la misma carpeta, `git checkout` es denegado nombrando el candado peer — `test-guardian-tree-ops.sh` caso 1.
- [ ] Con dos sesiones en carpetas distintas, `git checkout` no es interferido — `test-guardian-tree-ops.sh` caso 4.
- [ ] Con el lock del peer por encima de 300 s, la misma operación avisa sin bloquear — `test-guardian-tree-ops.sh` caso 6.
- [ ] Editar un archivo que un peer vivo de la misma carpeta tocó hace menos de 900 s produce aviso y procede — `test-guardian-shared-file.sh` caso 1.
- [ ] `bash scripts/self-test.sh` termina en `0 fail`.
- [ ] `.claude-plugin/plugin.json` marca `1.7.0` y `CHANGELOG.md` describe el cambio.

## Seguimiento (fuera de este plan)

Registrar en `docs/slate/features/backlog.md`, vía la skill `slate:breaking-down-features`:

- **Comando opt-in de aislamiento real.** Crear una worktree bajo demanda e indicar al usuario cómo abrir una sesión nueva en ella. Es la única vía que habilita paralelismo real entre ramas, decisión tomada con el usuario el 2026-07-25 de dejarlo fuera de este cambio.
- **Limpieza de worktrees heredadas.** Acción manual puntual sobre los repos del usuario, no código: `git worktree remove <ruta>` + `git branch -D slate-session/<id>` para las que no tengan trabajo pendiente.
