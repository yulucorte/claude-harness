# Changelog

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
