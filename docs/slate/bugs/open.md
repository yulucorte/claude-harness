# Open bugs

<!-- Bugs found but not yet fixed. Status: open.
     Add via slate:tracking-bugs.
     Move to fixed.md once Fix, Commit, and Fixed: date are all set. -->

## BUG-003: `session-start.sh` emite el formato plano — Claude Code descarta TODO el estado de arranque
- **Status**: open
- **Severity**: critical
- **Reported-by**: @felipevillacorte
- **Detected**: 2026-08-14
- **Where**: `hooks/session-start.sh:233` (emisión del `additionalContext`)
- **Root cause**: El hook emitía `{"additionalContext": ...}` (formato plano). Claude Code lo ejecuta sin error pero lo DESCARTA en silencio cuando varios plugins cablean `SessionStart` a la vez; solo sobrevive el formato envuelto `{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": ...}}`. La competencia es el caso normal, no el raro: Superpowers 6.3.0 cablea `SessionStart` con matcher `startup|clear|compact`, y slate se declara en `plugin.json` como *"Lightweight companion to Superpowers"*. Consecuencia: nada de lo que slate inyecta al arrancar llegaba al agente — índice de in-progress, estado en vuelo, historial reciente, bugs abiertos, conteo de ideas, versión del plugin, contador de `history.md`, truncado de `current.md`. Las cinco capacidades que 1.9.0 añadió dentro de este hook nunca llegaron a uso real. Mismo modo de fallo que `pre-compact.sh` (corre, no falla, nadie lee), que 1.8.0 borró exactamente por ese test. `session-lock.sh:156` ya emitía el formato correcto desde FEAT-001, donde el bug quedó DOCUMENTADO en las notas de `done.md` pero sin corregir aquí por decisión de alcance — 26 días abierto sin que nadie lo notara, porque el síntoma es silencio.
- **Fix**: Emitir el formato envuelto en `session-start.sh`, copiando el de `session-lock.sh:156`. Test de regresión `tests/test-session-start-wrapped-output.sh` (4 aserciones, incluida una que falla si el formato plano reaparece en el fuente). Los dos tests preexistentes que decodificaban la salida (`test-session-start-current-truncate.sh`, `test-session-start-version-history-count.sh`) leían la clave plana y pasaban en verde contra un formato que nunca llegaba a producción: actualizados al envelope. Requiere bump de versión para llegar a uso real (ver BUG-001).
- **Commit**: none
- **Related feature**: FEAT-001

### Notes
Medición que lo confirmó (no simulada): sesión real de Claude Code con slate + Superpowers instalados, leyendo el transcript `.jsonl` — el bloque de Superpowers (envuelto) aparece como `type=attachment`; el de slate (plano) no aparece nunca, solo como resultado de herramienta cuando el agente leyó el fuente a mano. El hook sí corre y sí produce 1189 bytes: falla la entrega, no la ejecución. Mismo método de verificación que usó FEAT-001 (transcript crudo, no la respuesta del modelo).

Encontrado como subproducto de un debate de diseño sobre otra cosa (relevo Superpowers→Slate), no buscándolo.
