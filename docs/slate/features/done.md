# Done

<!-- FORBIDDEN to edit existing entries. Create a successor with Supersedes: FEAT-XXX. -->

## FEAT-001: Session lock — guardián de sesiones paralelas
- **Status**: done
- **Created**: 2026-07-19
- **Updated**: 2026-07-19
- **Spec**: docs/superpowers/specs/2026-07-19-session-lock-design.md
- **Plan**: docs/superpowers/plans/2026-07-19-session-lock.md
- **Branch**: feat/feat-001-session-lock
- **Verification**: integration-test
- **Verified**: 2026-07-19

### Subtasks
- [x] FEAT-001.1: session-lock.sh claim path
- [x] FEAT-001.2: session-lock.sh stale-lock reaping test
- [x] FEAT-001.3: session-lock.sh colisión → aislamiento en worktree (+ fix symlinks macOS)
- [x] FEAT-001.4: session-heartbeat.sh
- [x] FEAT-001.5: session-guardian.sh
- [x] FEAT-001.6: session-lock-cleanup.sh
- [x] FEAT-001.7: cablear hooks en hooks.json
- [x] FEAT-001.8: verificación real con dos sesiones de Claude Code

### Notes
Dos capas: candado de sesión (SessionStart/PostToolUse/SessionEnd, en `$(git rev-parse --git-common-dir)/slate-sessions/`, resuelto con `pwd -P` para sobrevivir symlinks tipo /var→/private/var de macOS) + guardián de commit (PreToolUse sobre Bash). TTL de heartbeat 900s (15 min). Worktree de aislamiento vive fuera del repo (`<repo>.slate-worktrees/<8-char-session-id>`), se deja en disco al cerrar sesión (decisión de Felipe: no auto-borrar).

Verificado 2026-07-19 con DOS sesiones reales de `claude` (no simuladas): sesión A reclama la rama `main`; sesión B, arrancada en paralelo sobre el mismo repo, es detectada, aislada en worktree separado (`slate-session/<id>`), y el aviso realmente llega al modelo (confirmado leyendo el transcript .jsonl, no solo la respuesta de la sesión). Sesión aparte: guardián bloquea un `git commit` real cuando la rama activa cambió por debajo — confirmado con el campo `permission_denials` del output y con que el commit nunca aparece en `git log`.

Bug real encontrado y corregido durante la verificación real: el formato plano `{"additionalContext": ...}` (usado también por el `session-start.sh` preexistente) se ejecuta sin error pero Claude Code lo descarta silenciosamente cuando compiten varios hooks de SessionStart de distintos plugins — solo sobrevive el formato envuelto `{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": ...}}`. `session-lock.sh` ya usa el formato correcto. `session-start.sh` no se tocó (fuera del alcance del guardián) pero podría tener el mismo problema en la práctica — reportado a Felipe, no corregido por decisión de alcance.

13/13 tests unitarios en `scripts/self-test.sh` en verde (incluye 6 archivos de test nuevos para este guardián). Cero rutas hardcodeadas (verificado por grep). Sin regresiones en skills/hooks preexistentes.

## FEAT-002: Session guardian redesign — cerrar los puntos ciegos de BUG-002
- **Status**: done
- **Created**: 2026-07-19
- **Updated**: 2026-07-19
- **Spec**: docs/superpowers/specs/2026-07-19-session-guardian-redesign-design.md
- **Plan**: inline en el spec
- **Branch**: feat/feat-002-session-guardian-redesign
- **Verification**: unit (git real: commits/ramas/worktrees reales + candados vivos simulados)
- **Verified**: 2026-07-19
- **Bug**: BUG-002

### Subtasks
- [x] FEAT-002.1: session-lock.sh registra el tip (head SHA) en el candado
- [x] FEAT-002.2: session-guardian.sh — reencuadre a candados vivos ajenos (falso positivo #2 + re-chequeo continuo #4)
- [x] FEAT-002.3: session-guardian.sh — detección rama-encima por ancestro de tip (#1)
- [x] FEAT-002.4: session-guardian.sh — protección del stash compartido (#3)
- [x] FEAT-002.5: session-heartbeat.sh mantiene branch+head fresco (usa cwd del payload)
- [x] FEAT-002.6: tests con git real verdes (13/13 en scripts/self-test.sh)
- [x] FEAT-002.7: bump plugin 1.3.0→1.4.0 + CHANGELOG
- [x] FEAT-002.8: cerrar BUG-002 en el tracker (open→fixed)

### Notes
Sucede a FEAT-001 (no lo reemplaza) y cierra BUG-002. Reencuadre central: el guardián compara la rama/tip ACTUAL de esta sesión contra los candados de OTRAS sesiones vivas en cada operación git sensible, no contra la foto del arranque; el candado propio pasa a ser un espejo veraz (lo refresca el heartbeat), no una jaula. Bloquea (deny) solo ante choque confirmado con un peer vivo; en la duda avisa (additionalContext + systemMessage) sin bloquear. Detecta rama-encima (el HEAD a integrar desciende del tip vivo ajeno no publicado en main), misma-rama con peer vivo, y peligros del stash compartido (pop/apply sin ref explícita, drop/clear). Una sesión sola nunca se bloquea (elimina el falso positivo de 1.3.0). session-lock guarda el head SHA; el heartbeat lo mantiene fresco usando el cwd del payload (correcto incluso en un worktree aislado).

Verificación por tests con git real (repos/commits/ramas/worktrees reales + candados vivos escritos a mano): 13/13 en `scripts/self-test.sh`, incluidos 10 casos del guardián (rama-encima sí/no, misma-rama, peer stale, stash pop genérico vs ref explícita vs sin peer, commit plano on-top permitido). La integración con Claude Code (disparo del hook + llegada del deny) no cambió respecto de FEAT-001, ya verificada en vivo con dos sesiones reales; por eso no se repitió la corrida de dos procesos reales. Plugin 1.4.0; activación vía `claude plugin update` / sesión nueva.

## FEAT-003: Seguridad real entre sesiones paralelas
- **Status**: done
- **Created**: 2026-07-25
- **Updated**: 2026-07-25
- **Spec**: docs/superpowers/specs/2026-07-25-parallel-session-safety-design.md
- **Plan**: docs/superpowers/plans/2026-07-25-parallel-session-safety.md
- **Branch**: main
- **Verification**: integration-test
- **Verified**: 2026-07-25
- **Supersedes**: FEAT-001
- **Tags**: sesiones-paralelas, hooks

### Subtasks
- [x] FEAT-003.1: `session-lock.sh` registra la carpeta física de trabajo (`cwd`) en el candado, siempre
- [x] FEAT-003.2: eliminar la creación automática de worktrees y sustituirla por un aviso accionable
- [x] FEAT-003.3: `session-heartbeat.sh` anota los archivos escritos (`files[]`, tope 20, dedup por ruta) y late también en `UserPromptSubmit`
- [x] FEAT-003.4: `session-guardian.sh` deniega las reescrituras del árbol con un peer vivo en la misma raíz de worktree, con respuesta graduada (≤300 s deniega, ≤900 s avisa, más allá ignora)
- [x] FEAT-003.5: aviso — nunca bloqueo — cuando dos sesiones de la misma carpeta escriben el mismo archivo
- [x] FEAT-003.6: cablear el matcher `Write|Edit|NotebookEdit` de `PreToolUse` en `hooks.json`
- [x] FEAT-003.7: subir el plugin a 1.7.0 y describir el cambio en `CHANGELOG.md`
- [x] FEAT-003.8: revisión final de rama — ampliar el conjunto vigilado (`pull`, `clean -f`, formas destructivas de `stash`), registrar también las sesiones con HEAD desprendido, blindar los dos hooks contra payloads malformados, y hacer atómica la escritura del candado

### Notes
Sucede a FEAT-001 y FEAT-002 y **reemplaza el mecanismo central de FEAT-001**: el aislamiento automático por worktree (FEAT-001.3). Se eliminó porque no funcionaba, comprobado en vivo y no inferido — un hook `SessionStart` no puede cambiar el directorio de trabajo de una sesión ya arrancada, así que el aviso de mudarse nunca se obedecía y las tres worktrees generadas en este mismo repo (`1d93b272`, `36c29325`, `a078d02b`) estaban vacías. Pagaba el costo (carpetas acumuladas junto a cada repo) sin dar el beneficio. El resto de FEAT-001 (candado, heartbeat, limpieza en SessionEnd) sigue vigente.

Principio: si no se puede hacer cumplir, no se promete. La protección pasa al único mecanismo que sí se cumple — denegar en `PreToolUse` — y el modelo del candado deja de estar centrado en la RAMA para estarlo en la CARPETA FÍSICA, que es lo que de verdad determina si dos agentes se pisan.

La revisión final de la rama (2026-07-25) encontró que el conjunto vigilado dejaba fuera precisamente los comandos que git **no** frena por su cuenta: git se niega a un `checkout`/`merge` que pisaría archivos modificados, pero `git clean -f` y `git stash` destruyen sin preguntar. Comprobado en repo de prueba: `git clean -fd` borró el archivo sin seguimiento del peer y `git stash -u` revirtió su edición sin commitear. Se añadieron `pull`, `clean` con fuerza, y las formas destructivas de `stash` al mismo camino graduado. En la misma revisión: una sesión con HEAD desprendido no escribía candado y era invisible para el guardián; seis campos del payload sin comprobación de tipo tumbaban el hook entero en silencio (el envoltorio bash siempre sale 0, así que la protección desaparecía sin rastro); y la escritura del candado truncaba el archivo en sitio, dejando ventanas en las que el guardián leía un candado a medias y dejaba de ver a un peer vivo.

Verificación 2026-07-25: `bash scripts/self-test.sh` → `Results: 22 pass, 0 fail`. Los tests nuevos de esta ronda se vieron FALLAR contra el código anterior antes de arreglar nada: tabla de veredictos por verbo (`test-guardian-verb-coverage.sh`), sesión en HEAD desprendido de punta a punta (`test-session-lock-detached-head.sh`), matriz de payloads malformados sobre los dos hooks afirmando stderr vacío (`test-hooks-malformed-payload.sh`), escritura atómica del candado y candado de PEER corrupto/vacío/`null` a la hora de decidir.

Límites conocidos, declarados en `CHANGELOG.md` y en la spec: el clasificador lee tokens, así que un `bash -c "git checkout main"` es invisible y esta denegación es ya la única barrera contra la clase catastrófica; las escrituras vía Bash (`sed -i`, heredoc, `cp`) nunca llegan a `files`, así que el aviso por archivo compartido subreporta por construcción; `git revert`/`am`/`apply`/`rm -r` no se vigilan a propósito. El paralelismo real entre ramas sigue sin cubrirse: es FEAT-004.

## FEAT-006: Auditoría de uso real — higiene de hooks y falsos positivos del guardian
- **Status**: done
- **Created**: 2026-07-26
- **Updated**: 2026-07-26
- **Verified**: 2026-07-26
- **Plan**: none (auditoría dirigida sobre un proyecto en uso real, no un plan previo)
- **Branch**: feat/feat-006-hygiene-and-guardian-fixes
- **Goal**: medir el plugin contra phlou-app (1244 commits, 4 meses) en vez de contra su propio repo, y corregir lo que llevaba meses fallando en silencio
- **Verification**: `bash scripts/self-test.sh` — 23 ficheros, 0 fallos (41 aserciones nuevas)
- **Tags**: hooks, guardian, ideas, higiene

### Subtasks
- [x] FEAT-006.1: `session-start.sh` deja de anexar la salida de `init.sh` a `history.md` (el hook se leía a sí mismo)
- [x] FEAT-006.2: `history_tail()` filtra el ruido heredado, arreglando proyectos ya contaminados sin reescribirlos
- [x] FEAT-006.3: `session-end.sh` descarta bloques `<!-- -->` antes de decidir si hay trabajo (180/270 bloques eran plantilla vacía)
- [x] FEAT-006.4: eliminado el commit automático de fin de sesión (248/1244 commits)
- [x] FEAT-006.5: eliminado `pre-compact.sh` (58 disparos, 58 fallos) y su entrada `PreCompact`
- [x] FEAT-006.6: eliminada la generación de `codebase-map.md` (677 líneas por arranque, cero lectores)
- [x] FEAT-006.7: `classify()` exige `git` como comando del segmento y corta comentarios
- [x] FEAT-006.8: `checkout -b` / `switch -c` sin punto de partida y `restore --staged` dejan de denegarse
- [x] FEAT-006.9: `git clean` deja de leer como bandera lo que sigue a `--`
- [x] FEAT-006.10: recogida de candados vencidos al arrancar y al cerrar; ruta del candado por `argv`
- [x] FEAT-006.11: el aviso del buzón de ideas pasa a umbral (`SLATE_IDEAS_NAG_AT`, def. 40)
- [x] FEAT-006.12: `managing-ideas` clasifica bug vs idea y busca duplicados antes de escribir
- [x] FEAT-006.13: +41 aserciones en dos ficheros de test nuevos
- [x] FEAT-006.14: `has_work()` deja de descartar encabezados `###` (formato de `tracking-progress`) y un `<!--` sin cerrar ya no traga el trabajo posterior
- [x] FEAT-006.15: envoltorios `env`/`sudo` cubiertos en el parser; alcance del guardian documentado en el código

## FEAT-007: El guardián no recreaba el candado borrado — arreglo real del incidente + higiene tras auditoría de phlou-app
- **Status**: done
- **Created**: 2026-08-13
- **Updated**: 2026-08-13
- **Verified**: 2026-08-13
- **Spec**: none
- **Plan**: none (auditoría dirigida sobre un reporte externo, no un plan previo)
- **Branch**: feat/feat-007-guardian-heartbeat-and-hygiene
- **Goal**: cerrar los fallos que un reporte de auditoría externo (phlou-app, "El backlog miente", 2026-08-13) encontró en el plugin, incluido un incidente en vivo donde el guardián no bloqueó una operación destructiva de otra sesión sobre trabajo ajeno sin commitear
- **Verification**: `for f in tests/*.sh; do bash "$f"; done` — 29 ficheros, 29/29 en verde (23→29; verificado de forma independiente, no solo por el agente que implementó)
- **Tags**: guardian, heartbeat, hooks, higiene, ids

### Subtasks
- [x] FEAT-007.1: Guardián — `FRESH` 300s→900s, elimina la banda tibia donde un candado ajeno de 5-15 min solo avisaba en vez de bloquear
- [x] FEAT-007.2: Heartbeat recrea el candado propio si una sesión peer lo borró por antigüedad (`find -mmin +15 -delete`) mientras la sesión seguía viva — el hueco real detrás del incidente; sin esto el punto .1 no cerraba nada
- [x] FEAT-007.3: Mensaje de deny del guardián incluye la ruta del candado, para poder borrar uno fantasma a mano
- [x] FEAT-007.4: `session-start.sh` inyecta `current.md` truncado a las últimas ~100 líneas en vez de completo (medido: 31.6 KB / ~9000 tokens por arranque en un caso real)
- [x] FEAT-007.5: `.gitattributes` con `history.md merge=union`, entregado tanto por el instalador (proyectos nuevos) como por el migrador de `session-start.sh` (alcanza proyectos ya instalados, que el instalador por sí solo nunca vuelve a tocar)
- [x] FEAT-007.6: Versión activa del plugin (leída de `plugin.json`) visible en el contexto de `SessionStart`
- [x] FEAT-007.7: Contador `history.md: N/40 bloques` visible al superar el límite, reutilizando el filtro de ruido de `history_tail()` en vez de contar líneas `## ` en crudo (que infla el número: medido en este mismo repo, 53 crudo vs. 27 real)
- [x] FEAT-007.8: `scripts/reserve-id.sh` — reserva atómica de un ID candidato vía `mkdir` en `$(git rev-parse --git-common-dir)/slate-ids/<PREFIJO>/<NUM>`, separado por prefijo para que FEAT y BUG no colisionen entre sí
- [x] FEAT-007.9: `managing-feature-list`, `breaking-down-features` y `tracking-bugs` calculan el candidato como máximo(archivos vivos, reservas pendientes)+1 y reservan antes de confirmar el ID (evita la colisión real medida: 5 casos en phlou-app, dos sesiones en ramas distintas viendo el mismo máximo)
- [x] FEAT-007.10: `using-slate/SKILL.md` documenta la excepción — `.git/slate-ids/` es el único estado de Slate que no es markdown, es un marcador técnico interno no versionado
- [x] FEAT-007.11: Suite de tests 23→29 ficheros, verificada en verde de forma independiente

### Notes
Disparado por una auditoría externa ("El backlog miente", Phlou, 2026-08-13) sobre
un proyecto real (`phlou-app`) que usa este plugin. El diagnóstico y las
propuestas los hizo un agente Opus contra el código real (no supuesto): descartó
con evidencia la hipótesis inicial de "versión de plugin desactualizada en
caché" — `phlou-app` corría la 1.8.0 exacta. Un segundo agente Opus, en paralelo
y de solo lectura, auditó el plan antes de tocar código y encontró que el
arreglo aprobado para el guardián (subir el umbral de 300s a 900s) no cerraba
el modo de fallo real del incidente — encontró la causa exacta (el candado se
borraba y el heartbeat no lo recreaba) y la sumó al lote antes de implementar.
La ejecución (agente Sonnet, TDD) verificó al final con la suite completa; yo
mismo la volví a correr de forma independiente antes de dar el trabajo por
cerrado.

Límite conocido: la reserva de IDs y el arreglo del candado son protecciones
por-repositorio y por-máquina — no cubren colisiones entre clones en máquinas
distintas ni en CI. Y subir la versión en `plugin.json` no actualiza sola una
instalación ya existente: un proyecto que ya tiene Slate instalado necesita
reinstalar/actualizar para recibir 1.9.0 (la misma clase de bug, documentada
aquí, que dejó `codebase-map.md` regenerándose de más en proyectos ya
instalados tras 1.8.0 — ver `templates/init.sh` vs. proyecto ya instalado).
