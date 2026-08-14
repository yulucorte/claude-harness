# Contexto: ¿debería Slate absorber capacidades tipo gentle-ai?

**Fecha:** 2026-08-01
**Estado:** debate abierto — NO es un spec, NO hay diseño aprobado
**Origen:** sesión de Claude Code en el repo `phlou-app`, trasladada aquí para continuar
**Siguiente paso:** responder la pregunta abierta del final (§7) y, si procede, entrar a `superpowers:brainstorming`

Este documento recoge lo verificado en esa sesión. Todo dato numérico o de
comportamiento fue comprobado contra la fuente (API de GitHub, archivos en disco,
documentación oficial), no recordado. Donde una fuente secundaria se equivocaba,
queda anotado.

---

## 1. Punto de partida: ¿Superpowers está actualizado?

Sí. Verificado el 2026-08-01.

| Comprobación | Resultado |
|---|---|
| Versión instalada | v6.2.0 |
| Ruta | `~/.claude/plugins/cache/claude-plugins-official/superpowers/6.2.0` |
| Contenido de las skills | Coincide **hash a hash** (SHA-256) con el commit que fija el marketplace oficial: `44c9b2d`, 2026-07-28 |
| Ese commit vs `main` de `obra/superpowers` | **Idéntico** — 0 commits de diferencia |
| Skills instaladas | 14 — mismas que upstream |

### Trampa encontrada (reutilizable)

El registro interno de plugins de Claude Code, `~/.claude/plugins/installed_plugins.json`,
guardaba un `gitCommitSha` obsoleto (`b7a8f76`, 2026-04-02). Comparando por ese campo
parecía que la instalación estaba **261 commits atrás**. Comparando el contenido real
de los archivos, estaba al día.

**Regla:** para saber si un plugin está actualizado, compara el **hash del contenido**
de sus archivos contra upstream. El campo `gitCommitSha` del registro puede mentir.

```bash
# Método que sí funciona
P=~/.claude/plugins/cache/<marketplace>/<plugin>/<version>
shasum -a 256 "$P/skills/<skill>/SKILL.md"
curl -s "https://raw.githubusercontent.com/<org>/<repo>/<sha>/skills/<skill>/SKILL.md" | shasum -a 256
```

---

## 2. Qué es cada framework

### Superpowers — `obra/superpowers` (Jesse Vincent)

Un **método de trabajo** empaquetado como skills de Markdown. No aporta herramientas
nuevas: impone un orden. Brainstorming → spec → plan → TDD → ejecución con subagentes
→ revisión. Vive dentro del marketplace oficial de Anthropic.

### gentle-ai — `Gentleman-Programming/gentle-ai` (Alan Buscaglia)

Un **configurador de entorno**, escrito en Go. Su propio README lo dice explícitamente:
*"This is NOT an AI agent installer. This is an ecosystem configurator."*

Toma el agente que ya usas y le enchufa siete subsistemas:

1. **Engram** — memoria persistente entre sesiones (repo aparte)
2. **SDD** — flujo de desarrollo dirigido por especificaciones, 10 fases
3. **Skills curadas** — React, Next.js, Tailwind, TypeScript, Playwright
4. **Servidores MCP** preconfigurados
5. **Model routing por fase** — Opus para diseñar, Sonnet para implementar, Haiku para cerrar
6. **Persona** orientada a la enseñanza, con permisos "security-first"
7. **RDD** (Receipt-Driven Development) — revisión nativa acotada con recibos verificables

---

## 3. Números reales (API de GitHub, 2026-08-01)

| | Superpowers | gentle-ai |
|---|---|---|
| Estrellas | **264.757** | 5.264 |
| Forks | 23.635 | 628 |
| Creado | 2025-10-09 | 2026-02-27 |
| Último push | 2026-07-31 | 2026-08-01 |
| Issues abiertos | 317 | **521** |
| Lenguaje | Shell | Go |
| Marketplace oficial de Anthropic | Sí | No |

gentle-ai es ~50× más pequeño y 4 meses más joven, con **más issues abiertos que
Superpowers teniendo 1/50 de los usuarios**. Lectura honesta: proyecto joven
moviéndose rápido, no necesariamente malo — pero de superficie inestable.

> **Advertencia sobre fuentes secundarias.** La guía en español
> [ccodecurso.com/frameworks-agenticos.html](https://www.ccodecurso.com/frameworks-agenticos.html)
> es útil para el marco conceptual, pero sus cifras están mal: da 158.000 ⭐ a
> Superpowers (real: 264.757) y 2.131 a gentle-ai (real: 5.264). No citar sus números.

---

## 4. Comparación de fondo

| Eje | Superpowers | gentle-ai |
|---|---|---|
| Qué aporta | Disciplina (cómo trabajar) | Infraestructura (con qué trabajar) |
| Forma | 14 skills en Markdown | Binario Go + skills + MCP + persona |
| Instalación | Plugin de Claude Code | `go install` / `brew`; requiere Go 1.25 + Node 18 |
| TDD | **Obligatorio** | Flexible |
| Memoria entre sesiones | No la aporta | Sí (Engram) |
| Model routing por fase | No | Sí |
| Agentes soportados | ~4 | ~10 |
| Toca config global del usuario | No | **Sí: `~/.claude/CLAUDE.md`**, `~/.claude/mcp/`, `~/.claude/output-styles/` |

**No compiten de frente.** Superpowers es el motor; gentle-ai es el taller alrededor
del motor. Son componibles.

**Riesgo concreto de gentle-ai:** escribe en `~/.claude/CLAUDE.md`, que es configuración
global compartida por todos los proyectos del usuario. Su documentación no promete
explícitamente preservar lo que ya esté escrito ahí.

---

## 5. Engram vs graphify — ¿conflicto?

Pregunta que surgió porque `phlou-app` usa **graphify** (grafo del código) y Engram
sería memoria persistente. Verificado: **no chocan.**

| | graphify (v0.8.44, instalado en phlou-app) | Engram |
|---|---|---|
| Qué guarda | Estructura del código: qué llama a qué | Notas que el agente escribe: decisiones, por qué |
| Origen del dato | Derivado del código real, automático | Escrito a mano por el agente vía `mem_save` |
| Dónde vive | `graphify-out/` dentro del repo (7 MB, en `.gitignore`) | `~/.engram/engram.db` — **fuera** del repo |
| Interfaz | Comando de terminal (`.venv/bin/graphify query`) | 20 herramientas MCP, todas prefijadas `mem_*` |
| Ciclo de vida | Se regenera al cambiar la estructura | Se acumula indefinidamente |

Cero solapamiento de rutas. Cero colisión de nombres. **Engram no indexa código
fuente** (confirmado en su documentación). Son un mapa del edificio y un cuaderno
de bitácora.

### Fricciones reales (no son conflictos, pero importan)

1. **Engram se salta el candado de graphify.** En `phlou-app` hay dos hooks
   `PreToolUse` que obligan a correr graphify antes de buscar en archivos.
   Interceptan `grep`/`find` y `Read`/`Glob` — **no interceptan llamadas MCP**.
   Un `mem_search "dónde se calcula el inventario"` respondería desde una nota vieja
   sin que ningún gancho recuerde mirar el código real.

2. **Triplicaría el almacén de "qué decidimos y por qué".** Hoy conviven Slate
   (`docs/slate/`) y el archivo de auto-memoria del agente. Engram sería el tercero.
   La regla de `phlou-app` dice: *"Slate = único tracker. Sin listas paralelas."*

3. **Una sola base para todos los proyectos.** Engram guarda "un solo cerebro" en
   `~/.engram/engram.db`, compartido entre repos. Se acota con `--project`, pero
   es manual.

**Conclusión:** Engram no es un añadido, es un **reemplazo** del sistema de memoria
actual. Su ventaja real y concreta: hoy el índice de memorias son ~60 líneas que se
cargan **enteras cada sesión**; Engram las buscaría bajo demanda. Eso ahorra contexto.

---

## 6. La pregunta de Slate

> *"Yo soy dueño de Slate. ¿Podría hacer lo mismo que hace gentle con Slate,
> e integrarme mejor con Superpowers?"*

### Qué es Slate hoy (v1.8.0, leído del repo)

- **6 skills** — `using-slate`, `tracking-progress`, `managing-feature-list`,
  `breaking-down-features`, `tracking-bugs`, `managing-ideas`
- **6 hooks** — `session-start`, `session-end`, `session-guardian`, `session-lock`,
  `session-lock-cleanup`, `session-heartbeat`
- **20 tests** en `tests/`
- **Solo Markdown.** Sin JSON, YAML ni SQLite de estado.
- Ya se define en `plugin.json` como *"Lightweight companion to Superpowers"*

El README declara el alcance **cerrado**: Slate llena tres huecos que Superpowers
no cubre — estado entre sesiones, alcance canónico de features, contexto al arrancar
— y dice literalmente *"Nothing more."*

### La tensión central

La filosofía escrita de Slate es lo **opuesto** a la de gentle-ai:

> *"6 hooks, 6 skills. If you cannot justify one in a sentence, it does not belong
> here — and if nobody reads what it writes, it stops being a hook. 1.8.0 removed
> `pre-compact.sh` and the codebase map on exactly that test."*
>
> *"Hooks may not shout. A line injected at every session start that nobody acts on
> trains the reader to skip that whole region. Surface state on a threshold, not
> on a timer."*

En v1.8.0 se **quitaron** dos piezas porque nadie leía lo que escribían. gentle-ai
va en dirección contraria: apila memoria + SDD + skills + MCP + routing + persona
+ review. Copiarlo entero rompería la regla que hace a Slate defendible.

### Aviso de alcance

"Hacer lo que hace gentle" **no es una cosa: son siete subsistemas independientes**
(§2). Meterlos en un solo spec daría un plan inejecutable. Si se avanza, hay que
descomponer: elegir cuáles valen, en qué orden, cada uno con su propio ciclo
spec → plan → implementación.

### Observación: son dos preguntas, no una

La pregunta original mezcla dos cosas que conviene separar, porque tienen respuestas
distintas:

- **(a) ¿Slate absorbe capacidades tipo gentle-ai?** — expansión de alcance. Choca
  de frente con la filosofía declarada.
- **(b) ¿Slate se integra mejor con Superpowers?** — profundizar en lo que Slate
  YA declara ser. No choca con nada.

Hipótesis a debatir: **(b) probablemente vale más que (a)**, y es coherente con el
producto que ya existe. Pero no está evaluada — hace falta responder §7 primero.

---

## 7. PREGUNTA ABIERTA — bloquea el diseño

**¿Para qué debe crecer Slate?** La respuesta cambia qué vale construir y qué no:

| Opción | Qué implica | Cómo se mide |
|---|---|---|
| **A. Mejorar el trabajo diario** | Slate es herramienta interna. Si nadie más lo usa, da igual. Prioriza lo que duele hoy en `phlou-app`. | ¿Ahorra tiempo, tokens o errores? |
| **B. Producto público** | Buscar tracción real (gentle-ai logró 5.264 ⭐ en 5 meses). Prioriza diferenciación, instalación fácil, documentación. | Adopción de terceros |
| **C. Interna primero, pública después** | Construir para uno mismo y empujar afuera si funciona. **Riesgo:** lo óptimo para un usuario suele ser malo para muchos. | Ambas, en secuencia |

Sin esta respuesta no se puede recomendar alcance: bajo (A) casi nada de gentle-ai
vale la pena; bajo (B) la conversación es sobre diferenciación, no sobre features.

---

## 8. Restricción de calendario (contexto, no opinión)

`phlou-app` está a ~10 semanas del cutover de Novateks. Cualquier cambio en cómo
funciona la memoria o el tracker durante ese periodo es riesgo sin premio inmediato.
Esto no impide diseñar ahora; sí sugiere que **desplegar** cambios grandes de
infraestructura de trabajo sea posterior al cutover.

---

## Fuentes

- [obra/superpowers](https://github.com/obra/superpowers/)
- [Gentleman-Programming/gentle-ai](https://github.com/Gentleman-Programming/gentle-ai)
- [gentle-ai/docs/agents.md](https://github.com/Gentleman-Programming/gentle-ai/blob/main/docs/agents.md)
- [Gentleman-Programming/engram](https://github.com/Gentleman-Programming/engram)
- [Frameworks agénticos para Claude Code](https://www.ccodecurso.com/frameworks-agenticos.html) — marco conceptual útil, **cifras incorrectas**
- Repo local `slate` v1.8.0: `README.md`, `.claude-plugin/plugin.json`, `skills/`, `hooks/`, `tests/`
