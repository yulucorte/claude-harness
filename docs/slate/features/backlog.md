# Backlog

## FEAT-004: Comando opt-in de aislamiento real (worktree bajo demanda)
- **Status**: backlog
- **Created**: 2026-07-25
- **Updated**: 2026-07-25
- **Spec**: docs/superpowers/specs/2026-07-25-parallel-session-safety-design.md
- **Plan**: none
- **Branch**: none
- **Verification**: integration-test
- **Tags**: sesiones-paralelas, hooks

### Subtasks
- [ ] FEAT-004.1: Comando `/slate:isolate` que cree una worktree bajo demanda (rama nueva, ruta fuera del repo) y NO intente mudar la sesión actual
- [ ] FEAT-004.2: Salida que le diga al usuario, literal y copiable, cómo abrir una sesión de Claude Code NUEVA en esa carpeta
- [ ] FEAT-004.3: Registrar la worktree creada, para que FEAT-005 sepa cuáles son de slate
- [ ] FEAT-004.4: Test: el comando crea la worktree, no toca la sesión actual, y es idempotente si ya existe

### Notes
Follow-up decidido con Felipe el 2026-07-25 al cerrar FEAT-003, y declarado en la
spec (`## Alcance` → `Fuera`). Es **la única vía que habilita paralelismo real
entre ramas**, y la respuesta de la propia spec a su límite conocido más grande:
1.7.0 hace que el trabajo paralelo inseguro falle de forma ruidosa, no que sea
seguro.

La diferencia con el mecanismo que 1.7.0 eliminó es toda la razón de ser de esta
feature: aquel creaba la worktree **automáticamente** y le pedía al agente que se
mudara — imposible, porque un hook `SessionStart` no puede cambiar el directorio
de trabajo de una sesión ya arrancada (verificado en vivo: las worktrees
generadas así quedaron siempre vacías). Aquí la worktree se crea **sólo cuando el
usuario la pide**, y el aislamiento lo consigue el usuario abriendo una sesión
nueva allí, que es lo único que funciona.

## FEAT-005: Limpieza de worktrees heredadas de versiones anteriores a 1.7.0
- **Status**: backlog
- **Created**: 2026-07-25
- **Updated**: 2026-07-25
- **Spec**: docs/superpowers/specs/2026-07-25-parallel-session-safety-design.md
- **Plan**: none
- **Branch**: none
- **Verification**: manual
- **Tags**: sesiones-paralelas, limpieza

### Subtasks
- [ ] FEAT-005.1: Localizar en los repos del usuario los directorios `<repo>.slate-worktrees/<id>` y las ramas `slate-session/*`
- [ ] FEAT-005.2: Comprobar en cada uno si hay trabajo pendiente (cambios sin commitear, o commits no fusionados a la línea principal)
- [ ] FEAT-005.3: Borrar sólo las que NO tengan trabajo pendiente: `git worktree remove <ruta>` + `git branch -D slate-session/<id>`
- [ ] FEAT-005.4: Reportar a Felipe las que sí tenían trabajo, sin tocarlas

### Notes
1.7.0 dejó de crear worktrees automáticas pero **no borra las ya existentes**,
por decisión explícita: borrar carpetas del usuario sin mirar su contenido es
justo el tipo de daño que este trabajo existe para evitar. En la inspección del
2026-07-25 sobre el repo `slate`, las tres worktrees encontradas (`1d93b272`,
`36c29325`, `a078d02b`) estaban vacías: ni cambios sin commitear ni commits sin
fusionar. Aun así la comprobación de FEAT-005.2 es obligatoria antes de cada
borrado, repo por repo.

El plan original lo describía como acción manual puntual y no como código; queda
registrado igualmente para que no se pierda, y la decisión de automatizarlo o
hacerlo a mano se toma al empezarlo.
