# Seguridad real entre sesiones paralelas — diseño

**Fecha**: 2026-07-25
**Feature**: FEAT-003 (sucede a FEAT-001 / FEAT-002; ver `docs/superpowers/specs/2026-07-19-session-lock-design.md` y `2026-07-19-session-guardian-redesign-design.md`)
**Origen**: pregunta del usuario sobre por qué se acumulan carpetas `<repo>.slate-worktrees/` en sus repos, más inspección en vivo del sistema durante la sesión del 2026-07-25.

## Problema

El aislamiento por worktree introducido en FEAT-001 **no funciona**, y el guardián de FEAT-002 **no vigila la operación más destructiva**. Ambas cosas están comprobadas empíricamente, no inferidas.

### Evidencia 1 — el aislamiento es teatro

`hooks/session-lock.sh` detecta colisión de rama y crea una worktree dedicada (`<parent>/<repo>.slate-worktrees/<short-id>`, rama `slate-session/<short-id>`). Luego **le pide al agente que se mude** vía `additionalContext`.

Estado observado en el repo `slate` el 2026-07-25:

| Worktree | Cambios sin commitear | Commits no fusionados a `main` |
| --- | --- | --- |
| `1d93b272` | ninguno | ninguno |
| `36c29325` | ninguno | ninguno |
| `a078d02b` | ninguno | ninguno |

`1d93b272` corresponde a la sesión **activa durante la inspección**, que trabajó todo el tiempo en `~/Desktop/slate` (la raíz), nunca en su worktree. Es prueba directa —no inferencia— de que el aviso no se obedece.

Se descartó la hipótesis barata («el aviso no se emite»): ejecutando el hook en un repo de prueba, emite JSON válido con el formato documentado `hookSpecificOutput.additionalContext` y el texto correcto.

**Causa raíz**: un hook `SessionStart` no puede cambiar el directorio de trabajo de una sesión ya arrancada. El aviso es una petición de una línea que compite contra el resto del contexto del agente (directorio de trabajo fijado por el harness, rutas absolutas en la conversación, referencias del IDE). Pierde. No es un bug reparable: es un mecanismo que no puede funcionar como está construido.

**Consecuencia**: el mecanismo paga el costo (carpetas acumuladas junto a cada repo, confusión del usuario) sin entregar el beneficio (aislamiento).

### Evidencia 2 — el guardián deja pasar la operación catastrófica

`classify()` en `hooks/session-guardian.sh` sólo reconoce los verbos `commit`, `push`, `merge`, `rebase`, `cherry-pick`, `stash`.

`checkout` y `switch` **no** están vigilados. Son precisamente las operaciones que reescriben el árbol de trabajo completo en disco: si dos sesiones comparten carpeta y una cambia de rama, los archivos de la otra son sustituidos en vivo, sin que su agente se entere. Es el daño que el usuario reporta como «se pisan las ramas, se tocan archivos en diferentes ramas».

### Evidencia 3 — falta el dato para decidir

Los locks (`$GIT_COMMON_DIR/slate-sessions/<sid>.lock`) guardan `branch`, `worktree`, `head`, `started_at`. El campo `worktree` sólo se rellena cuando hubo aislamiento; en el caso normal queda `""`. Por tanto **ninguna sesión sabe en qué carpeta física trabaja otra**, que es justo la condición que determina si pueden pisarse.

`hooks/session-heartbeat.sh` ya recibe el `cwd` real en el payload de `PostToolUse` y refresca el lock en cada llamada a herramienta. El dato existe; sólo no se persiste.

## Principio de diseño

Dos agentes en la misma carpeta se pisan; en carpetas distintas, no. El aislamiento sólo es efectivo si la sesión **arranca** en su carpeta. Como Slate no controla el arranque, deja de simular aislamiento y pasa a **impedir**, mediante el único mecanismo que sí se cumple (denegación en `PreToolUse`), las operaciones que destruyen trabajo ajeno.

Regla: **si no se puede hacer cumplir, no se promete.**

## Alcance

### Dentro

1. Persistir la carpeta real de trabajo de cada sesión en su lock.
2. Vigilar y denegar las operaciones que reescriben el árbol de trabajo, con respuesta graduada.
3. Eliminar la creación automática de worktrees; sustituirla por un aviso accionable.
4. Avisar (sin bloquear) cuando dos sesiones en la misma carpeta editan el mismo archivo.
5. Subir versión del plugin y registrar en CHANGELOG.

### Fuera (follow-up explícito, decidido con el usuario el 2026-07-25)

- **Comando opt-in de aislamiento real**: crear una worktree bajo demanda e indicar al usuario cómo abrir una sesión nueva en ella. Es la única vía que habilita paralelismo real entre ramas. Se anota como feature aparte en `docs/slate/features/backlog.md`; no entra en este cambio.
- **Limpieza de las worktrees ya existentes** en repos del usuario: acción manual puntual, no código.

### No objetivos

- No se persigue impedir toda colisión posible entre agentes. Se persigue eliminar la clase catastrófica (reescritura del árbol) y hacer visible la clase recuperable (mismo archivo).
- No se añaden sandboxes, orquestadores ni gestión de puertos. Fuera de la filosofía de Slate (estado en markdown, mínimo de hooks).

## Diseño

### Componente 1 — `session-lock.sh`: registrar carpeta, no crear worktrees

**Cambia**:

- Añadir al lock el campo `cwd`: ruta física (`realpath`) de la carpeta donde trabaja la sesión. Se escribe **siempre**, no sólo al aislar.
- Eliminar el bloque de creación de worktree (`git worktree add`, `mkdir -p` del directorio `.slate-worktrees`, y el cálculo de `WT_PATH`/`NEW_BRANCH`).
- La detección de colisión se mantiene, pero su salida pasa a ser sólo informativa: mensaje que nombra a la sesión peer, advierte de no cambiar de rama, y explica que para trabajo paralelo real hay que abrir otra sesión en otra carpeta.

**Se conserva**: el campo `worktree` en el esquema del lock, por compatibilidad con locks escritos por versiones anteriores. Los lectores lo tratan como opcional.

**Esquema del lock resultante**:

```json
{
  "branch": "main",
  "cwd": "/Users/x/Desktop/slate",
  "worktree": "",
  "head": "<sha>",
  "started_at": "2026-07-25T12:00:00Z",
  "files": []
}
```

### Componente 2 — `session-heartbeat.sh`: mantener `cwd` y registrar archivos escritos

**Cambia**:

- Escribir/refrescar `cwd` en el lock usando el `cwd` del payload (ya disponible), en cada refresco.
- Cuando `tool_name` es `Write`, `Edit` o `NotebookEdit`, extraer `file_path` de `tool_input` y añadir a `files` una entrada `{"path": <ruta absoluta>, "ts": <epoch>}`.
- `files` se mantiene acotado a las **20 entradas más recientes**, deduplicado por `path` (se conserva el `ts` más nuevo). Evita crecimiento indefinido del lock.

**Se conserva**: la actualización de `branch` y `head`, y el carácter estrictamente pasivo del hook.

### Componente 3 — `session-guardian.sh`: denegar reescrituras del árbol

**Cambia**:

- `classify()` reconoce además los verbos que reescriben el árbol de trabajo: `checkout`, `switch`, `restore`, y `reset` **sólo** cuando lleva `--hard` (un `reset --soft`/`--mixed` no toca los archivos en disco).
- Nueva condición de colisión: existe un peer vivo cuyo `cwd` (resuelto con `realpath`) es **igual** al `cwd` de esta sesión. Si los `cwd` difieren, estas operaciones no se vigilan — las sesiones ya están aisladas y no se estorban.
- **Respuesta graduada por frescura del lock del peer**, medida por su `mtime`:
  - peer **fresco** (edad ≤ 300 s): `deny`. El peer está vivo con casi certeza; el comando destruiría su árbol.
  - peer **tibio** (300 s < edad ≤ TTL de 900 s): `warn`. Puede ser una sesión muerta sin limpiar; no se bloquea al usuario.
  - peer **rancio** (edad > 900 s): ignorado, igual que hoy.

  Esto resuelve el falso bloqueo por lock huérfano sin renunciar a la protección: el heartbeat corre en cada llamada a herramienta, así que una sesión realmente activa tiene el lock de hace segundos.
- **Aviso por archivo compartido** (nunca bloqueo): al interceptar `Write`/`Edit`/`NotebookEdit`, si un peer vivo comparte `cwd` y su lista `files` contiene el mismo `path` con `ts` dentro de los últimos 900 s, se emite un `warn` indicando qué sesión lo tocó y cuándo. Nunca `deny`: el choque de archivo es recuperable y visible en `git status`, y bloquearlo generaría fricción constante.

**Se conserva**: toda la lógica actual de `commit`/`push`/`merge`/`rebase`/`cherry-pick`/`stash`, el TTL de 900 s, la salida temprana cuando la sesión está sola, y la regla de no comparar nunca contra el propio pasado de la sesión.

### Componente 4 — `hooks/hooks.json`: matcher para escrituras

Añadir una entrada `PreToolUse` con `matcher: "Write|Edit|NotebookEdit"` apuntando a `session-guardian.sh`. El guardián distingue el caso por `tool_name` del payload.

### Componente 5 — versionado

Subir la versión menor en `.claude-plugin/plugin.json` (1.6.1 → 1.7.0) y añadir entrada en `CHANGELOG.md`. Sin esto el cambio no llega al uso real: el plugin se cachea por versión en `~/.claude/plugins/cache/slate-direct/slate/<version>/`.

## Flujo de datos

```text
SessionStart
  └─ session-lock.sh
       ├─ lee locks vivos de otras sesiones
       ├─ escribe SU lock con {branch, cwd, head, started_at, files: []}
       └─ si hay peer en la misma rama → additionalContext informativo (sin crear carpetas)

PostToolUse (toda herramienta)
  └─ session-heartbeat.sh
       └─ refresca SU lock: mtime, branch, head, cwd, files[] (si fue escritura)

PreToolUse (Bash)
  └─ session-guardian.sh
       ├─ clasifica verbos git del comando
       ├─ si no hay peers vivos → allow
       ├─ verbos de integración (commit/push/…) → lógica actual
       └─ verbos de árbol (checkout/switch/restore/reset --hard)
            └─ peer con mismo cwd → deny (fresco) | warn (tibio)

PreToolUse (Write|Edit|NotebookEdit)
  └─ session-guardian.sh
       └─ peer con mismo cwd y mismo file_path reciente → warn (nunca deny)
```

## Manejo de errores

Se mantiene el contrato vigente de los tres hooks: **nunca romper una sesión**. Cualquier fallo (git ausente, lock ilegible, JSON corrupto, payload inesperado) termina en salida limpia que permite continuar. En concreto:

- Lock ilegible o sin `cwd` (escrito por una versión anterior): se ignora ese peer para las reglas nuevas. Degradación silenciosa, nunca excepción.
- `files` ausente: se trata como lista vacía.
- `realpath` que falla sobre un `cwd` inexistente (sesión cuyo directorio fue borrado): ese peer se ignora.
- El guardián nunca deniega por falta de datos, sólo por colisión confirmada.

## Plan de pruebas

Se añaden a `tests/`, siguiendo el estilo de los tests existentes (repo temporal con `git init`, invocación directa del hook con payload JSON por stdin):

1. `test-session-lock-records-cwd.sh` — el lock contiene `cwd` con la ruta física correcta, tanto en sesión sola como en colisión.
2. `test-session-lock-no-worktree.sh` — tras una colisión **no** se crea ningún directorio `*.slate-worktrees`, y el `additionalContext` emitido menciona la colisión.
3. `test-guardian-blocks-checkout.sh` — con un peer fresco en el mismo `cwd`, `git checkout otra-rama` recibe `deny`; con peer en `cwd` distinto, pasa.
4. `test-guardian-graduated-staleness.sh` — mismo escenario con el lock del peer envejecido artificialmente (`touch -t`): peer tibio produce `warn`, no `deny`.
5. `test-guardian-reset-hard.sh` — `git reset --hard` se vigila; `git reset --soft` no.
6. `test-heartbeat-records-files.sh` — tras un payload de `Write`, el lock contiene la ruta en `files`; se verifica el tope de 20 y la deduplicación por `path`.
7. `test-guardian-warns-shared-file.sh` — peer vivo en el mismo `cwd` con el archivo en su `files` produce `warn` sobre `Write`, nunca `deny`.

Sobre los tests existentes:

- `test-session-lock.sh` — su caso «existing SAME-branch FRESH lock → real collision, isolates into worktree» afirma el comportamiento que este diseño elimina. **Se reescribe** para afirmar lo contrario: la colisión se detecta, se emite `additionalContext`, y no se crea directorio alguno.
- `test-session-lock-worktree-visibility.sh` — **se conserva sin cambios**. No prueba la creación automática de worktrees, sino que el directorio de locks (`$GIT_COMMON_DIR/slate-sessions/`) es compartido y visible entre worktrees creadas a mano. Es precisamente la premisa sobre la que se apoya este diseño.
- `test-session-lock-cleanup.sh` — **se conserva sin cambios**. Verifica que la limpieza no toca worktrees ajenas, que sigue siendo cierto.

## Límites conocidos

Declarados de forma explícita, no ocultos:

- **Dos agentes pueden seguir editando el mismo archivo.** Se avisa, no se impide. Es un choque localizado, visible y recuperable, a diferencia de la reescritura del árbol.
- **El paralelismo real entre ramas sigue sin estar cubierto** por este cambio. Requiere el comando opt-in listado como follow-up. Este diseño hace que la situación insegura falle de forma ruidosa en lugar de silenciosa; no la convierte en segura.
- **La primera sesión de una carpeta nunca se reubica.** Es una consecuencia de la física del harness, no una decisión.
- **Ventana de hasta 5 minutos** en la que un lock huérfano puede denegar un cambio de rama legítimo. Salida disponible: ejecutar el comando en una terminal fuera de Claude, o borrar el lock.

## Criterios de aceptación

1. Iniciar una segunda sesión en un repo con otra sesión viva **no** crea ningún directorio nuevo en disco.
2. Con dos sesiones vivas en la misma carpeta, `git checkout <otra-rama>` es denegado con un mensaje que nombra a la sesión peer.
3. Con dos sesiones vivas en carpetas distintas, `git checkout` no es interferido.
4. Con el lock del peer envejecido por encima de 5 minutos, la misma operación produce aviso y no bloqueo.
5. Editar un archivo que un peer vivo de la misma carpeta tocó en los últimos 15 minutos produce un aviso y la edición procede.
6. La suite de `tests/` pasa completa.
7. `.claude-plugin/plugin.json` refleja 1.7.0 y `CHANGELOG.md` describe el cambio.
