# Changelog

## 1.9.0 — 2026-08-13

Seis arreglos aprobados tras diagnosticar un incidente real (el guardián
guardó silencio durante una colisión de dos sesiones en ramas distintas). Una
segunda auditoría en paralelo, hecha sobre el plan antes de tocar código,
encontró 5 huecos concretos en cómo estaban especificados esos arreglos — ya
están incorporados abajo, no quedaron como una segunda pasada.

### Corregido — el guardián se quedaba callado ante la colisión real que lo motivó

Dos huecos independientes dejaban pasar exactamente el escenario del
incidente: dos sesiones en ramas distintas de la misma carpeta, una de ellas
sin llamar a ninguna herramienta por un rato.

1. **Banda tibia (5–15 min) eliminada.** `FRESH` (300s) hacía que un candado
   ajeno de 300–900s de antigüedad solo generara aviso, nunca bloqueo.
   `FRESH` pasa a valer lo mismo que `TTL` (900s): cualquier candado dentro
   del TTL deniega igual que uno recién creado.
2. **El candado de una sesión viva podía borrarse y no recrearse nunca.**
   `session-lock.sh` y `session-lock-cleanup.sh` borran candados de más de 15
   minutos (`find … -mmin +15 -delete`) para no acumular basura de sesiones
   muertas — pero una sesión VIVA que simplemente no llamó a ninguna
   herramienta en ese rato perdía su candado por el mismo mecanismo, y
   `session-heartbeat.sh` no lo recreaba (`if not isfile(lock): exit 0`),
   solo refrescaba uno que ya existiera. Esa sesión quedaba invisible para el
   guardián para siempre — sin este segundo arreglo, subir el umbral del (1)
   no habría cerrado nada, solo habría movido el mismo hueco. El heartbeat
   ahora recrea el candado si lo encuentra ausente.
3. El mensaje de denegación incluye ahora la ruta del archivo de candado, para
   poder borrar a mano uno fantasma (de una sesión que se cayó sin cerrar
   limpio) si hace falta desbloquear antes de que expire el TTL.

### Cambiado — current.md ya no se inyecta completo al arrancar

`session-start.sh` hacía un `cat` íntegro de `docs/slate/progress/current.md`
en cada arranque. Medido en un proyecto real: 31.6 KB, ~9000 tokens, en cada
mensaje de inicio de sesión. Ahora se inyectan solo las últimas ~100 líneas,
con una nota (`truncado — abre docs/slate/progress/current.md si necesitas
el resto`) cuando se recorta. Un archivo de 100 líneas o menos se inyecta
igual que antes, sin nota.

### Agregado — merge=union para history.md

`history.md` es de solo-anexado, pero dos sesiones en ramas distintas
anexando al mismo tiempo generaban un conflicto de fusión en cada `git
merge` (17 conflictos medidos). `docs/slate/progress/.gitattributes` ahora
marca `history.md merge=union`, así que git combina los anexados de ambas
ramas en vez de pedir resolución manual.

Se entrega por dos vías, no solo una: `install-into-project.sh` para
instalaciones nuevas, y `session-start.sh` (corre en cada sesión) para
proyectos ya instalados. Solo el instalador habría dejado sin cubrir a
cualquier proyecto que instaló slate antes de este cambio — corre una única
vez y nunca pisa un `.gitattributes` que el proyecto ya tenga, así que jamás
vuelve a alcanzarlo (la misma clase de bug que dejó `codebase-map.md`
regenerándose de más en proyectos ya instalados, ver 1.8.0 más abajo).
Ninguna de las dos vías reemplaza un `.gitattributes` propio: si ya existe
uno, solo se le añade la línea si falta.

### Agregado — versión activa visible al arrancar

`session-start.sh` inyecta ahora `slate X.Y.Z` (leído de
`.claude-plugin/plugin.json`) como línea visible, para que una instalación
con caché vieja (hooks o skills editados pero la versión del plugin sin
subir, con lo que Claude Code sigue sirviendo la versión anterior) sea obvia
en vez de silenciosa. Si el archivo no se puede leer, la línea se omite sin
romper el arranque de la sesión.

### Agregado — contador de history.md visible al superar el límite

`docs/archiving.md` fija el límite de rotación en 40 entradas. `session-start.sh`
ahora cuenta los bloques reales de `history.md` — reutilizando el mismo
filtro que `history_tail()` ya usaba para descartar ruido de hooks (ecos de
`init.sh`, cabeceras de `PreCompact`), no un conteo crudo de líneas que
empiezan con `##` — y muestra `history.md: N/40 bloques — rota con
tracking-progress` solo cuando N supera 40. Contar esas líneas en crudo
habría inflado el número: medido en este mismo repo, 53 líneas que empiezan
con `##` de las cuales solo 27 son bloques reales.

### Agregado — reserva de IDs en .git para FEAT-XXX/BUG-XXX

`managing-feature-list`, `breaking-down-features` y `tracking-bugs`
calculaban el próximo ID con un `grep` del máximo en los archivos vivos + 1.
Dos sesiones en ramas sin fusionar podían ver el mismo máximo y elegir el
mismo ID sin que ninguna se enterara hasta el merge.

`scripts/reserve-id.sh` reserva un ID candidato de forma atómica creando
`$(git rev-parse --git-common-dir)/slate-ids/<PREFIJO>/<NUMERO>` — `mkdir`
falla si el directorio ya existe, lo que da atomicidad sin lockfile aparte.
Las reservas van separadas por prefijo (`slate-ids/FEAT/`, `slate-ids/BUG/`)
para que `FEAT-042` y `BUG-042` nunca colisionen entre sí, ya que
`tracking-bugs` declara esas dos numeraciones independientes. Las tres
skills ahora calculan el candidato como el máximo ENTRE los archivos vivos Y
las reservas pendientes (no solo los archivos — mirar solo los archivos
dejaría pasar exactamente la colisión que esto debía evitar) y llaman al
script antes de dar el número por definitivo; si la reserva falla, prueban
el siguiente. `breaking-down-features` puede crear hasta 3 features de una
vez: reserva una vez POR feature, no una sola vez para el lote completo.

Límite conocido: es una protección por repositorio y por máquina
(`git rev-parse --git-common-dir` es compartido entre ramas y worktrees del
MISMO repo, incluido). No protege entre clones distintos que nunca comparten
un `.git`.

`.git/slate-ids/` es la única excepción documentada a "Markdown es el
contrato" (`skills/using-slate/SKILL.md`): son directorios marcador vacíos,
de uso interno, invisibles y no versionados — nunca un documento de
producto.

### Tests

23 → 29 archivos en `tests/test-*.sh`, todos en verde. Nuevos: reserva de
IDs (incluye reserva hecha desde un worktree enlazado bloqueando el mismo ID
en el worktree principal), recreación de candado por el heartbeat (incluye
verificar que la sesión recreada vuelve a ser visible para
`session-guardian.sh`), truncado de `current.md`, versión + contador de
`history.md` (con guarda explícita contra el conteo inflado por ruido de
hooks), entrega de `.gitattributes` tanto por el instalador como por
`session-start.sh`. Ajustados: los tests de `session-guardian` que
verificaban la banda tibia (300–900s) ahora verifican que esa banda ya no
existe.

No verificado en un escenario real de dos sesiones de Claude Code corriendo
en paralelo de verdad (dos procesos distintos, dos ramas, con tiempo real
transcurriendo): toda la cobertura de arriba usa repos temporales y payloads
simulados dentro de la misma sesión de tests, no dos agentes reales
compitiendo por el mismo repo.

## 1.8.0 — 2026-07-26

**Auditoría de uso real (FEAT-006).** Se midió el plugin contra un proyecto que
lo usa de verdad (1244 commits, 4 meses) en vez de contra su propio repo. Varias
funciones llevaban meses sin funcionar y nadie lo había notado, porque fallaban
en silencio.

### Corregido — el historial se envenenaba a sí mismo

`session-start.sh` anexaba la salida de `init.sh` a `history.md` y acto seguido
inyectaba el final de ese mismo fichero como «History (reciente)». El hook se
leía a sí mismo: **cada sesión arrancaba con `[init.sh] OK` como su historial**.
Medido: 1437 de 6265 líneas del historial eran ese eco, y 46 de las últimas 50
líneas útiles eran ruido.

- La salida de `init.sh` ya no toca `history.md`; solo aparece en stderr si falla.
- `history_tail()` filtra además el ruido heredado (salida de init, avisos de
  PreCompact, bloques de plantilla vacía), así que **los proyectos ya
  contaminados se arreglan sin reescribir ni borrar nada**.

### Corregido — cierres de sesión vacíos

La comprobación de «¿hay trabajo en `current.md`?» estaba anclada a principio de
línea, así que las líneas *indentadas* del comentario de la plantilla contaban
como trabajo real. Medido: **180 de 270 bloques de cierre eran la plantilla
vacía copiada**. Ahora se descartan los bloques `<!-- ... -->` completos antes de
juzgar.

### Eliminado

- **`pre-compact.sh`**. Leía `CLAUDE_TRANSCRIPT_PATH`, que el harness nunca
  define, y su `matcher` venía de un argumento que `hooks.json` nunca pasaba.
  Sus 58 disparos en producción escribieron 58 veces «no transcript available» y
  cero copias. Se elimina el hook y su entrada `PreCompact`.
- **El mapa del código** (`docs/slate/progress/codebase-map.md`). 677 líneas
  regeneradas en cada arranque; ningún hook lo inyectaba, ninguna skill lo
  mencionaba y `.gitignore` lo excluía. Cero lectores.
- **El commit automático de fin de sesión.** Producía 248 de 1244 commits —uno de
  cada cinco— titulados «auto: session-end checkpoint», casi todos vacíos. El
  estado se commitea junto al trabajo que describe, como cualquier otro archivo.

### Corregido — `session-guardian` denegaba trabajo legítimo

`classify()` buscaba el primer token literal `git` en cualquier posición del
segmento y trataba todo `checkout`/`switch`/`restore` como reescritura del árbol.
Ahora:

- `git` debe ser **el comando** del segmento (se saltan asignaciones `VAR=x` y
  envoltorios como `sudo`). Deja de denegar `man git checkout` y `echo git ...`.
- Se cortan los comentarios: `ls  # git checkout main` ya no se deniega.
- `git checkout -b <rama>` y `git switch -c <rama>` **sin punto de partida** no
  tocan el árbol de trabajo: se permiten. Con punto de partida
  (`-b x origin/main`) siguen denegándose.
- `git restore --staged` solo toca el índice: se permite. Con `--worktree` sigue
  denegándose.
- `git clean` deja de leer como bandera lo que va después de `--`
  (`git clean -- -foo` era un falso positivo).

Lo que seguía protegiendo, sigue protegiendo: `checkout`/`switch` de rama,
`reset --hard`, `clean -f`, `stash` destructivo, `pull` y `restore` de archivos.

### Corregido — los candados de sesión no se recogían nunca

`session-lock-cleanup.sh` solo borraba el candado propio; el TTL hacía que los
demás se *ignoraran*, pero nadie los borraba. Medido: 13 candados muertos en un
proyecto, el más viejo de 6 días, y un fantasma de 51 minutos que seguía
anunciándose como «otra sesión activa». Ahora se recogen los vencidos (>15 min)
tanto al arrancar como al cerrar.

También: la ruta del candado se pasa por `argv` en vez de interpolarse en el
código Python, así que una ruta de repo con apóstrofo deja de romper el parseo.

### Cambiado — el buzón de ideas es un depósito, no una cola

`SessionStart` ya no reclama «correr /ideas-triage» en cada arranque: un aviso
ignorado sesión tras sesión (28 ideas, 0 triages, 28 avisos ignorados) entrena a
saltarse esa zona entera del mensaje. Ahora solo aparece al superar
`SLATE_IDEAS_NAG_AT` (por defecto 40).

A cambio, la captura se vuelve más exigente en lo que sí importa:

- **Clasificar antes de guardar.** Lo que ya está roto (bug, configuración de
  producción mal puesta, documentación que contradice al código) va a
  `bugs/open.md`, no al buzón. Se encontró un bloqueo de facturación en
  producción archivado como «idea» en el puesto 28.
- **Buscar duplicados antes de escribir.** 28 líneas del buzón resultaron ser 21
  ideas y 7 pares duplicados, porque se capturaba sin leer.

### Corregido — el cierre de sesión descartaba encabezados de trabajo

Encontrado al revisar el propio 1.8.0: la comprobación de contenido descartaba
**toda** línea que empezara por `#`, así que un `### FEAT-XXX en vuelo` —el
formato que escribe `tracking-progress`— no contaba como trabajo. Ahora solo se
ignora el `# ` del título. Además, un `<!--` sin cerrar ya no puede tragarse lo
que venga detrás: si el comentario nunca cierra, su contenido vuelve a contar.

### Tests

+41 aserciones en dos ficheros nuevos (`test-hygiene-1.8.0.sh`,
`test-guardian-false-positives.sh`) que fijan cada defecto medido arriba,
incluida la contraparte que importa: los 15 comandos que el guardian debe seguir
denegando (`checkout`, `reset --hard`, `clean -f`, `stash`, `pull`, y los mismos
tras `sudo`/`env`/`FOO=bar`).

Se elimina `test-init-codebase-map.sh` (probaba la generación del mapa) y se
actualiza `test-guardian-tree-ops.sh`, que usaba `git checkout -b X` como
tree-op canónico para probar la resolución de carpetas; ahora usa un cambio de
rama real.

### Alcance declarado del guardian

Queda escrito en el código: el guardian cubre al agente honesto, no a un evasor.
`sh -c "git checkout main"`, `xargs git checkout` y `/usr/bin/git checkout` pasan
—igual que en 1.7.0— porque el hook inspecciona una cadena, no ejecuta un shell.
Cubrir eso a medias solo daría sensación falsa de red.

## 1.7.0 — 2026-07-25

**Seguridad real entre sesiones paralelas (FEAT-003).** El aislamiento
automático por worktree se elimina: un hook `SessionStart` no puede reubicar una
sesión ya arrancada, así que el aviso de mudarse nunca se obedecía y las
worktrees generadas quedaban vacías. Pagaba el costo (carpetas acumuladas junto
a cada repo) sin dar el beneficio.

La protección pasa a `session-guardian`, que sí se hace cumplir:

- **Nuevo:** el lock de sesión registra la carpeta física de trabajo (`cwd`) y
  los últimos 20 archivos escritos (`files`).
- **Nuevo:** `session-heartbeat.sh` corre ahora también en `UserPromptSubmit`,
  además de `PostToolUse`: una sesión cuyo humano está leyendo o escribiendo,
  sin usar herramientas, ya no se confunde con una sesión muerta. Los umbrales
  de vida de 300 s / 900 s no cambian.
- **Nuevo:** se deniegan, cuando otra sesión viva comparte la misma carpeta, las
  operaciones que reescriben o borran en disco el trabajo ajeno:
  `checkout`, `switch`, `restore`, `reset --hard`/`--merge`/`--keep`, `pull`,
  `clean` con `-f`/`-fd`/`-fdx`/`--force`, y las formas destructivas de `stash`
  (`git stash`, `stash push`, `stash save`, `stash -u`, y `stash pop`/`apply`
  sin una referencia `stash@{n}` explícita). Los tres últimos importan
  especialmente porque git **no** los frena por su cuenta: git se niega a un
  `checkout`/`merge` que pisaría archivos modificados, pero `clean -f` y
  `stash` destruyen sin preguntar. Quedan permitidos `reset --soft`/`--mixed`
  (solo tocan HEAD/índice), `clean` sin fuerza (git ya lo rechaza),
  `stash list`/`stash show`, y `stash pop`/`apply stash@{n}` con referencia
  explícita. La carpeta se compara por la RAÍZ del
  worktree de git (`git rev-parse --show-toplevel`, memoizada por carpeta), no
  por el string crudo de `cwd`: así `git -C <subcarpeta> checkout` se deniega
  correctamente con un peer en la raíz, `git -C <otro-repo> checkout` no
  interfiere con un peer de esta carpeta, y un worktree enlazado anidado queda
  separado del principal en ambas direcciones. Respuesta graduada, decidida
  siempre por el peer MÁS FRESCO que comparte carpeta (nunca un peer arbitrario
  ni el orden de listado del filesystem): actividad en los últimos 300 s
  deniega y lo nombra en el mensaje; entre 300 s y 900 s avisa nombrándolo
  igual; más allá se ignora, así un candado huérfano no bloquea un cambio de
  rama legítimo.
- **Nuevo:** aviso (nunca bloqueo) al escribir un archivo que otra sesión de la
  misma carpeta (misma raíz de worktree) tocó en los últimos 900 s, nombrando
  siempre al peer más fresco entre los que coinciden. La ruta se compara de
  forma física (`os.path.realpath`), igual que el resto de comparaciones del
  guardian, para que un symlink o una ruta relativa no esconda el choque.
- **Eliminado:** la creación automática de `<repo>.slate-worktrees/<id>` y las
  ramas `slate-session/*`. Las worktrees existentes no se tocan; se pueden
  borrar a mano con `git worktree remove` + `git branch -D`.

Los locks escritos por versiones anteriores (sin `cwd` ni `files`) se ignoran
para las reglas nuevas y nunca provocan una denegación. Una sesión con HEAD
desprendido (`detached HEAD`) también se registra, con `branch` vacío: su árbol
de trabajo se destruye igual que cualquier otro.

**Límites conocidos** (declarados, no ocultos):

- Esto hace que el trabajo paralelo inseguro falle de forma **ruidosa**, no que
  sea seguro. Para trabajar en ramas distintas a la vez hay que abrir cada
  sesión en su propia carpeta; el aislamiento sólo funciona si la sesión
  arranca allí.
- **El clasificador lee tokens del comando, no ejecuta nada.** Un
  `bash -c "git checkout main"`, un `sh -c ...`, un alias o cualquier git
  dentro de un script `.sh` son **invisibles** para él. Como el aislamiento
  automático ya no existe, esta denegación es la ÚNICA barrera contra la clase
  catastrófica: si se sortea, no hay red debajo.
- **Las escrituras hechas vía Bash no se anotan en `files`.** Un `sed -i`, una
  redirección con heredoc o un `cp` modifican archivos sin pasar por
  `Write`/`Edit`/`NotebookEdit`, que son las únicas herramientas que el
  heartbeat registra. El aviso por archivo compartido, por tanto, **subreporta
  por construcción**: avisa de lo que ve, nunca de todo lo que pasa.
- **No se vigilan** `git revert`, `git am`, `git apply` ni `git rm -r`. Todos
  pueden tocar el árbol ajeno; se dejan fuera a propósito porque su uso normal
  es deliberado y acotado, y denegarlos generaría fricción constante. Queda
  anotado para que sea una decisión revisable y no un olvido
  (`tests/test-guardian-verb-coverage.sh` fija su silencio como esperado).
- **Ventana de hasta 5 minutos** en la que un candado huérfano puede denegar un
  cambio de rama legítimo. Salida: ejecutar el comando en una terminal fuera de
  Claude, o borrar el candado de `$(git rev-parse --git-common-dir)/slate-sessions/`.

## 1.6.1 — 2026-07-21

### Changed
- `scripts/install-into-project.sh` no longer creates `docs/superpowers/specs/`
  and `docs/superpowers/plans/`. Superpowers owns those paths and creates them
  on demand (its `brainstorming` / `writing-plans` skills write there directly),
  so pre-creating them left empty folders in projects that never use Superpowers.
  slate now provisions only `docs/slate/`.

## 1.6.0 — 2026-07-21

Moves all slate state out of the repo root and under a single `docs/slate/`
directory, so an installed project's root stays clean. The four state folders
`progress/`, `features/`, `bugs/`, `ideas/` now live at `docs/slate/progress/`,
`docs/slate/features/`, `docs/slate/bugs/`, `docs/slate/ideas/`. Superpowers
artifacts (`docs/superpowers/`) and the plugin's own reference docs are
unchanged. Existing projects self-migrate automatically — no manual steps.

### Added
- Auto-migrator in `session-start.sh` (`slate_migrate_layout`): on the next
  session in any project still using the old root layout, the four state dirs
  are moved into `docs/slate/` (via `git mv` when tracked, plain `mv`
  otherwise). Idempotent and content-preserving; runs before anything reads
  state.
- `tests/test-migration.sh` — covers git-tracked migration, idempotency, and the
  non-git `mv` path.

### Changed
- `hooks/` — `session-start.sh`, `session-end.sh`, `pre-compact.sh` read/write
  under `docs/slate/`; SessionEnd auto-commit now stages `docs/slate/`.
- `init.sh`, `templates/init.sh`, `scripts/install-into-project.sh` create and
  seed state under `docs/slate/`.
- `skills/*`, `docs/*`, `templates/AGENTS.md`, `AGENTS.md`, `README.md`,
  `.gitignore` — every state path reference now points at `docs/slate/`.
- Historical `docs/superpowers/specs` and `docs/superpowers/plans` left intact
  (they record what was built at the time).

## 1.5.0 — 2026-07-20

Cuts `managing-feature-list` from ~84k tokens/invocation to <5k by (a) replacing
full-file reads with a bounded `grep` for the next ID, and (b) adding an official
by-entry-count archiving flow for the append-only files. Same ID fix applies to
`tracking-bugs`. No change to the `FEAT-XXX` / `BUG-XXX` format; IDs stay
immutable.

### Changed (`skills/`)
- `managing-feature-list` — next `FEAT-NNN` now comes from a bounded `grep` over
  the live files (`backlog`/`in-progress`/`done`), never a whole-file read. New
  "Archiving done.md" section; anti-pattern carve-out for the sanctioned bulk
  move.
- `breaking-down-features` — step 2 uses the same bounded `grep`.
- `tracking-bugs` — next `BUG-NNN` via bounded `grep`; new archiving section for
  `fixed.md`.
- `tracking-progress` — new archiving section for `history.md`; reconciled the
  "don't summarize history" anti-pattern (archiving is a bulk move of intact
  blocks, not a summary).
- `using-slate` — lists `*-archive-*.md` as canonical-but-never-loaded; forbids
  whole-file reads for ID computation.

### Added (`docs/`)
- `docs/archiving.md` — the single reference for rotation: 40-entry threshold,
  `*-archive-YYYYHn.md` naming, oldest-first invariant (keeps ID search correct),
  and the bulk-move-≠-edit rule.
- `docs/feature-format.md`, `docs/bug-format.md` — the "next ID" bullet is now the
  bounded `grep`; movement tables gain the archive row.

### Note
- Consumers must run `claude plugin update` (or start a fresh Claude Code
  session) to pull 1.5.0 into the versioned plugin cache — same activation step
  as any skill change (see BUG-001).

## 1.4.0 — 2026-07-19

Redesigns the session guardian to close the four blind spots of BUG-002 that let
a parallel session clobber another's work in real use (a branch built on top of
another live session's commits reached production on merge). Ships FEAT-002.

### Changed (`hooks/`)
- `session-guardian.sh` — now decides by comparing THIS session's current
  branch/tip against the locks of OTHER LIVE sessions on every sensitive git op
  (`commit`/`push`/`merge`/`rebase`/`cherry-pick`/`stash`), instead of against a
  startup snapshot of its own claim. It blocks (`deny`) only on a confirmed clash
  with a live peer, and otherwise warns without blocking (`additionalContext` +
  `systemMessage`, leaving the normal permission flow intact). New detections:
  (1) a branch built on top of a live peer's un-mainlined tip (branch-on-top),
  (2) a live peer on the same branch, (3) shared-stash hazards (`git stash
  pop`/`apply` without an explicit `stash@{n}`, and `drop`/`clear`, are blocked
  while a peer is live). A session acting alone is never blocked — this removes
  the 1.3.0 false positive that blocked a deliberate branch change by the session
  itself.
- `session-lock.sh` — records the branch tip (`head` SHA) in the lock so peers
  can detect a branch-on-top.
- `session-heartbeat.sh` — besides refreshing liveness, mirrors this session's
  current branch + tip into its lock (using the payload `cwd`, correct even in an
  isolated worktree) so a peer sees fresh state right after a commit.

### Note
- Consumers must run `claude plugin update` (or start a fresh Claude Code
  session) to pull 1.4.0 into the versioned plugin cache — same activation step
  as any hook change (see BUG-001).

## 1.3.0 — 2026-07-19

Ships FEAT-001 (session lock) to consumers. The hook scripts and `hooks.json`
wiring for parallel-session protection landed in the repo but the plugin version
was never bumped, so Claude Code kept serving the cached 1.2.0 copy (which lacks
the new hooks) and the protection never loaded in real, marketplace-installed
sessions. This release exists to trigger the cache re-copy. See BUG-001.

### Added (`hooks/`)
- `session-lock.sh` — SessionStart: writes a per-session lock under
  `$(git rev-parse --git-common-dir)/slate-sessions/`; if another live session
  already claims the current branch, auto-isolates into a new `git worktree`.
- `session-heartbeat.sh` — PostToolUse: refreshes the lock's heartbeat so a live
  session isn't reaped by the 15-minute stale TTL.
- `session-guardian.sh` — PreToolUse(Bash): blocks `git commit`/`git push` when
  the current branch differs from the one this session claimed at start.
- `session-lock-cleanup.sh` — SessionEnd: releases this session's lock.
- `hooks.json` now wires `PostToolUse` and `PreToolUse(Bash)` in addition to the
  existing `SessionStart`, `SessionEnd`, `PreCompact` (these two event types were
  removed in 1.0.0 and are reintroduced here only for the session guardian).

### Note
- Consumers must run `claude plugin update` (or start a fresh Claude Code
  session) to pull 1.3.0 into the versioned plugin cache. Editing plugin source
  without bumping the version has no effect — Claude Code keeps the cached copy.

## 1.2.0 — 2026-07-06

Adds bug traceability and idea capture, following the same markdown-only,
append-only-history pattern as `features/`.

### Added
- `bugs/open.md` / `bugs/fixed.md` — bug tracking with `BUG-XXX` IDs,
  independent numbering from `FEAT-XXX`. See `docs/bug-format.md`.
- `ideas/inbox.md` / `ideas/triaged.md` — zero-friction idea capture plus
  explicit triage (group by area, promote/archive/keep-pending). See
  `docs/idea-format.md`.
- Skills: `tracking-bugs`, `managing-ideas`.
- Commands: `/idea "<text>"`, `/ideas-triage`.
- `hooks/session-start.sh` now injects open-bug count + IDs and
  pending-idea count, same lightweight index principle as the existing
  in-progress features index.

## 1.1.0 — 2026-06-22

SessionStart hook now injects lightweight state instead of full dumps. Measured
against a real project (novateks-improductivos): ~21478 bytes (~5369 tok) →
~789 bytes (~197 tok) on startup, ~326 bytes (~81 tok) on compact/resume.

### Changed (`hooks/session-start.sh`)
- Stops injecting `features/backlog.md` (read on demand via managing-feature-list).
- in-progress injected as an INDEX (one line per FEAT: id + title + status),
  not full blocks.
- Stops `cat`-ing SKILL.md; injects a one-line header pointing at the
  `using-slate` skill (protocol loads via the Skill tool on demand).
- Branches on the SessionStart `source` (read from stdin JSON):
  startup|clear → header + in-progress index + current.md + last 2 history lines;
  compact|resume → in-progress index + last history line only, no header.
- history capped to the last line(s) instead of `tail -30`.

## 1.0.0 — 2026-05-25

Lean rewrite. The harness now does exactly three things: persistent session state, controlled feature movement, and SessionStart context injection.

### Removed (vs 0.5.0)
- All `PostToolUse`, `PreToolUse`, and `Stop` hooks (formatter, safety, checkpoint, watchers, notify).
- Skills: `consulting-project-map`, `harness-create-branch`, `harness-doctor`, `harness-open-pr`, `verify-harness-hooks`, `verifying-features`, `handing-off-session`, `scaffolding-environment`.
- `scripts/harness/` (doctor, pr-open, pr-merge, rollback).
- `scripts/lib/parse-features.sh`, `scripts/lib/checkpoint.sh`, all `hooks/lib/`.
- Config layer (`templates/.slate/`).
- Project map and ADR templates.
- v0.2/v0.4/v0.5 install-time migrations.

### Kept and simplified
- 3 hooks: `SessionStart`, `SessionEnd`, `PreCompact`.
- 4 skills: `using-slate`, `managing-feature-list`, `breaking-down-features`, `tracking-progress`.
- 1 install script that copies templates and exits.
