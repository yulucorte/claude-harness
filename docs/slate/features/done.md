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
