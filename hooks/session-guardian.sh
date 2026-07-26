#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash): session-lock guardian, layer 2 (redesign).
#
# BUG-002 / FEAT-002 redesign. The old guardian compared the ACTIVE branch
# against the branch THIS session claimed at startup, so it (a) missed a branch
# built ON TOP of another session's live commits, (b) false-blocked a deliberate
# branch change by this very session, (c) ignored the shared stash, and (d) only
# reasoned about a startup snapshot.
#
# New model: on every sensitive git op, compare THIS session's CURRENT branch/tip
# against the locks of OTHER LIVE sessions (never against this session's own past).
# Block (deny) only on a CONFIRMED clash with a live peer; otherwise warn and let
# the normal permission flow proceed. If this session is alone, nothing is guarded
# (that is what removes the old false positive).
set -uo pipefail

STDIN_JSON=""
if [ ! -t 0 ]; then
  STDIN_JSON=$(cat 2>/dev/null || true)
fi
[ -z "$STDIN_JSON" ] && exit 0

SG_JSON="$STDIN_JSON" python3 - <<'PY'
import sys, os, json, re, shlex, subprocess, time, glob

TTL = 900  # seconds; matches session-lock.sh stale-lock reaping
FRESH = 300  # s. Peer con lock mas nuevo que esto = vivo casi con certeza.


def main():
    try:
        payload = json.loads(os.environ.get("SG_JSON") or "{}")
    except Exception:
        sys.exit(0)

    # El payload de nivel superior no siempre es un objeto: un stdin malformado
    # puede traer una lista, un numero o una cadena, y entonces el primer
    # payload.get() revienta antes de llegar a ninguna regla.
    if not isinstance(payload, dict):
        sys.exit(0)

    # CADA campo del payload puede llegar con un tipo inesperado. La regla es
    # siempre la misma: comprobar isinstance y degradar al valor vacio, nunca
    # asumir el tipo. Un .strip()/.get() sobre el tipo equivocado aqui tumbaba
    # TODO el guardian (deny de tree-ops incluido), porque estas lineas corren
    # antes de cualquier regla; y como el envoltorio bash acaba siempre en
    # 'exit 0', la proteccion desaparecia sin dejar rastro en el codigo de salida.
    sid = payload.get("session_id")
    sid = sid.strip() if isinstance(sid, str) else ""
    tool = payload.get("tool_name")
    tool = tool.strip() if isinstance(tool, str) else ""
    tool_input = payload.get("tool_input")
    tool_input = tool_input if isinstance(tool_input, dict) else {}
    cmd = tool_input.get("command")
    cmd = cmd if isinstance(cmd, str) else ""
    cwd = payload.get("cwd")
    cwd = cwd.strip() if isinstance(cwd, str) else ""
    if not sid:
        sys.exit(0)

    # Dos modos. "file": una escritura, solo puede AVISAR de un choque de archivo.
    # "bash": un comando git, es el unico que puede DENEGAR.
    if tool in ("Write", "Edit", "NotebookEdit"):
        mode = "file"
        raw_target = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
        target = raw_target.strip() if isinstance(raw_target, str) else ""
        if not target:
            sys.exit(0)
    else:
        mode = "bash"
        target = ""
        if not cmd:
            sys.exit(0)
    if not cwd:
        cwd = os.environ.get("CLAUDE_PROJECT_ROOT") or os.getcwd()
    if not os.path.isdir(cwd):
        sys.exit(0)


    def git(*args, in_dir=None):
        try:
            return subprocess.run(
                ["git", "-C", in_dir or cwd, *args],
                capture_output=True, text=True, timeout=10,
            )
        except Exception:
            class _R:  # subprocess-like failure
                returncode = 1
                stdout = ""
                stderr = ""
            return _R()


    # --- classify the command: which sensitive git verbs appear? -----------------
    def classify(command):
        verbs = set()
        stash = {"sub": None, "explicit": False, "tree": False}
        # Un tree-op por cada invocacion de git que lo dispare, con su propio
        # -C/--work-tree (o None). Un comando compuesto puede traer varios; cada
        # uno se evalua por separado mas adelante (round 2, item 2) en vez de
        # dejar que el primero decida por todos.
        tree_hits = []
        for seg in re.split(r"[;&|\n]+", command):
            try:
                toks = shlex.split(seg)
            except ValueError:
                toks = seg.split()
            gi = next((i for i, t in enumerate(toks) if t == "git"), None)
            if gi is None:
                continue
            j = gi + 1
            seg_dir = None
            while j < len(toks) and toks[j].startswith("-"):
                if toks[j] in ("-C", "--work-tree"):
                    if j + 1 < len(toks):
                        seg_dir = toks[j + 1]
                    j += 2
                elif toks[j] in ("-c", "--git-dir", "--namespace"):
                    j += 2
                else:
                    j += 1
            if j >= len(toks):
                continue
            verb = toks[j]
            if verb in ("commit", "push", "merge", "rebase", "cherry-pick"):
                verbs.add(verb)
            elif verb in ("checkout", "switch", "restore"):
                # Reescriben el arbol de trabajo en disco. Prefijo "tree:" para no
                # mezclarlos con los verbos de integracion de las reglas 1-3.
                verbs.add("tree:" + verb)
                tree_hits.append(seg_dir)
            elif verb == "reset":
                # --hard, --merge y --keep reescriben archivos del arbol de trabajo;
                # --soft y --mixed solo tocan HEAD/indice, nunca los archivos.
                if any(f in toks[j + 1:] for f in ("--hard", "--merge", "--keep")):
                    verbs.add("tree:reset")
                    tree_hits.append(seg_dir)
            elif verb == "pull":
                # 'git pull' = fetch + merge/rebase EN el arbol de trabajo: reescribe
                # en disco todo archivo que haya cambiado upstream, y con --rebase
                # reconstruye el arbol commit a commit. Mismo dano que un checkout
                # para el agente que esta editando esos archivos ahora mismo.
                verbs.add("tree:pull")
                tree_hits.append(seg_dir)
            elif verb == "clean":
                # 'git clean' BORRA archivos sin seguimiento -- incluidos los que la
                # otra sesion acaba de crear y aun no ha commiteado. Sin -f/--force
                # git se niega por si mismo (clean.requireForce), asi que solo se
                # vigila con la fuerza presente. Las banderas cortas se agrupan
                # ('-fd', '-fdx', '-xdf'), de ahi que se busque la letra 'f' dentro
                # de cualquier grupo corto y no el token exacto '-f'.
                forced = any(
                    t == "--force" or (t.startswith("-") and not t.startswith("--") and "f" in t)
                    for t in toks[j + 1:]
                )
                if forced:
                    verbs.add("tree:clean")
                    tree_hits.append(seg_dir)
            elif verb == "stash":
                verbs.add("stash")
                sub = toks[j + 1] if j + 1 < len(toks) else ""
                if sub.startswith("-"):
                    sub = ""
                explicit = ("stash@{" in seg)
                # Formas DESTRUCTIVAS del stash: 'git stash' / 'stash push' /
                # 'stash save' / 'stash -u' guardan y REVIERTEN el arbol de trabajo
                # (y con -u borran ademas los archivos sin seguimiento); un 'pop'/
                # 'apply' sin referencia explicita lo reescribe con contenido que
                # puede ni ser suyo. Van por la MISMA via graduada que los tree-ops
                # (regla 0) cuando un peer comparte la raiz del worktree: git no
                # frena ninguna de estas, a diferencia de checkout/merge, que si se
                # niegan a pisar archivos modificados. El resto de formas conserva
                # exactamente su trato anterior en la regla 3.
                destructive = (
                    sub in ("", "push", "save")
                    or (sub in ("pop", "apply") and not explicit)
                )
                stash = {"sub": sub, "explicit": explicit, "tree": destructive}
                if destructive:
                    verbs.add("tree:stash")
                    tree_hits.append(seg_dir)
        return verbs, stash, tree_hits


    if mode == "bash":
        verbs, stash, tree_hits = classify(cmd)
        if not verbs:
            sys.exit(0)
    else:
        verbs, stash, tree_hits = set(), {"sub": None, "explicit": False, "tree": False}, []

    # --- must be a real git repo -------------------------------------------------
    if git("rev-parse", "--git-dir").returncode != 0:
        sys.exit(0)

    r = git("rev-parse", "--git-common-dir")
    gcd = r.stdout.strip()
    if not gcd:
        sys.exit(0)
    if not os.path.isabs(gcd):
        gcd = os.path.join(cwd, gcd)
    gcd = os.path.realpath(gcd)
    lock_dir = os.path.join(gcd, "slate-sessions")

    # --- gather OTHER live locks -------------------------------------------------
    now = time.time()
    foreign = []
    for lp in glob.glob(os.path.join(lock_dir, "*.lock")):
        lid = os.path.basename(lp)[:-5]
        if lid == sid:
            continue
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

    if not foreign:
        # This session is alone. A deliberate branch change is not a collision.
        sys.exit(0)

    _toplevel_cache = {}


    def worktree_root(path):
        # Memoizado: la misma carpeta nunca se resuelve dos veces en una
        # invocacion. Sin esto, un comando con varios tree-ops identicos (o
        # varios peers en la misma carpeta) dispara un "git rev-parse
        # --show-toplevel" por cada uno; con git colgado, cada uno gasta su
        # propio timeout=10 en vez de compartir un solo resultado.
        if path in _toplevel_cache:
            return _toplevel_cache[path]
        r = git("rev-parse", "--show-toplevel", in_dir=path)
        top = r.stdout.strip()
        try:
            result = os.path.realpath(top) if r.returncode == 0 and top else path
        except Exception:
            result = path
        _toplevel_cache[path] = result
        return result


    # --- modo fichero: avisar si un peer de la MISMA carpeta escribio este archivo -
    # Nunca deniega. El choque de archivo es localizado, visible en 'git status' y
    # recuperable; bloquearlo generaria friccion constante sin evitar dano real.
    # Comparo raices de worktree resueltas (no cwd crudo) por la misma razon que
    # la regla 0: un -C o un worktree enlazado pueden hacer que dos cwd distintos
    # sean la MISMA raiz fisica, o que el mismo cwd crudo ya no sea suficiente.
    # El archivo tambien se compara por ruta FISICA, no como string crudo: un
    # symlink, un 'a/../b' o un file_path relativo no deben esconder la colision.
    if mode == "file":
        try:
            my_root = worktree_root(os.path.realpath(cwd))
            target_real = os.path.realpath(os.path.join(cwd, target))
        except Exception:
            sys.exit(0)
        hits = []  # (lock del peer, ago) por cada entrada que coincide
        for d in foreign:
            peer_cwd = d.get("cwd")
            if not isinstance(peer_cwd, str):
                continue  # ausente o de tipo inesperado: nunca se avisa a ciegas
            peer_cwd = peer_cwd.strip()
            if not peer_cwd:
                continue  # lock legado sin cwd: se ignora, nunca se avisa a ciegas
            if not os.path.isabs(peer_cwd):
                continue  # relativa: se resolveria contra el proceso del hook, no contra el peer
            try:
                p = os.path.realpath(peer_cwd)
            except Exception:
                continue
            if worktree_root(p) != my_root:
                continue  # raiz de worktree distinta: no hay nada que avisar
            entries = d.get("files")
            if not isinstance(entries, list):
                continue
            for e in entries:
                if not isinstance(e, dict):
                    continue
                epath = e.get("path")
                if not isinstance(epath, str):
                    continue  # tipo inesperado: nunca se avisa a ciegas
                try:
                    if os.path.realpath(epath) != target_real:
                        continue
                except Exception:
                    continue
                try:
                    ago = int(now - float(e.get("ts") or 0))
                except Exception:
                    continue
                if ago > TTL or ago < 0:
                    continue  # viejo, o con reloj adelantado: ambos se ignoran
                hits.append((d, ago))
        if hits:
            # Mismo criterio que la regla 0: el candado MAS FRESCO decide a quien
            # se nombra en el aviso -- nunca el primero que devuelva glob.glob().
            freshest_d, ago = min(hits, key=lambda h: h[1])
            msg = ("session-guardian: otra sesion viva en esta misma carpeta (candado %s) "
                   "escribio '%s' hace %ss. Relee el archivo antes de editarlo: tu version "
                   "en contexto puede estar desactualizada y tu escritura pisaria su cambio."
                   % (freshest_d["_id"][:8], os.path.basename(target), ago))
            print(json.dumps({
                "systemMessage": "⚠️ " + msg,
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "additionalContext": msg,
                }
            }))
        sys.exit(0)

    actual_branch = git("branch", "--show-current").stdout.strip()
    actual_head = git("rev-parse", "HEAD").stdout.strip()


    def main_ref():
        for ref in ("origin/HEAD", "main", "master", "origin/main", "origin/master"):
            if git("rev-parse", "--verify", "--quiet", ref).returncode == 0:
                return ref
        return ""


    denies = []
    warns = []
    integ = verbs & {"push", "merge", "rebase", "cherry-pick"}

    # Rule 0 — reescritura del arbol: un peer vivo en la MISMA carpeta fisica.
    # Es la unica clase de dano catastrofico: 'checkout'/'switch'/'restore'/
    # 'reset --hard|--merge|--keep'/'pull'/'clean -f'/'stash' (formas destructivas)
    # reescriben o borran los archivos que el otro agente esta editando, en vivo y
    # sin que se entere. En carpetas distintas no hay nada que proteger (por eso se
    # respeta un -C/--work-tree explicito).
    # True SOLO si la regla 0 llego a DENEGAR. No basta con que un peer comparta
    # carpeta: la regla 3 delega en la regla 0 unicamente cuando esta ya ha
    # bloqueado la operacion. Con un peer tibio la regla 0 solo avisa, y entonces
    # la regla 3 tiene que poder denegar por su cuenta (el stash es del repo
    # entero, asi que su peligro no depende de la frescura del candado ajeno).
    tree_denied = False
    tree_ops = sorted(v.split(":", 1)[1] for v in verbs if v.startswith("tree:"))
    if tree_ops:
        # worktree_root()/_toplevel_cache definidos arriba (compartidos con el
        # modo fichero) -- no se redefinen aqui.

        def resolve_target(raw_dir):
            # El objetivo crudo: -C/--work-tree si el comando lo trae (resuelto
            # relativo a esta sesion), si no, esta sesion misma.
            try:
                t = raw_dir if raw_dir else cwd
                if not os.path.isabs(t):
                    t = os.path.join(cwd, t)
                t = os.path.realpath(t)
            except Exception:
                return ""
            # checkout/switch/restore/reset reescriben el arbol de trabajo COMPLETO
            # sin importar la subcarpeta desde la que se invoquen: -C solo cambia
            # DONDE busca git el repo, no el alcance de lo que toca (probado:
            # 'git -C sub switch otra' cambio archivos FUERA de sub). Por eso se
            # resuelve a la raiz real del worktree; si falla (no es un repo, git
            # no disponible, etc.) se degrada al directorio crudo sin romper.
            return worktree_root(t)

        # Un comando compuesto puede traer varios tree-ops con -C distintos; el de
        # UNO no debe decidir el objetivo de OTRO (round 2, item 2). Se dedupean
        # los -C/--work-tree crudos ANTES de resolver (y worktree_root() memoiza
        # por carpeta), para no repetir el mismo subproceso por cada ocurrencia
        # identica en el comando.
        targets = set()
        for raw_dir in set(tree_hits):
            t = resolve_target(raw_dir)
            if t:
                targets.add(t)

        # Se compara la RAIZ del worktree de cada peer contra mis objetivos -- NO
        # contencion de carpetas. Un worktree enlazado ('git worktree add') puede
        # vivir FISICAMENTE anidado dentro del repo principal y comparte
        # slate-sessions/ (mismo git-common-dir), pero tiene su PROPIA raiz de
        # arbol de trabajo: probado que un checkout en la raiz deja intactos los
        # archivos del worktree enlazado anidado, y viceversa. Comparar por
        # contencion los confundia con el mismo arbol y denegaba sin una colision
        # real (round 3, item 1); comparar raices resueltas por igualdad los
        # distingue, y de paso ya no importa si un -C cae en una subcarpeta simple
        # (sin worktree propio): esa resuelve a la MISMA raiz que el resto del repo.
        matches = []
        for d in foreign:
            peer_cwd = d.get("cwd")
            if not isinstance(peer_cwd, str):
                continue  # ausente o de tipo inesperado: nunca se deniega a ciegas
            peer_cwd = peer_cwd.strip()
            if not peer_cwd:
                continue  # lock legado sin cwd: se ignora, nunca se deniega a ciegas
            if not os.path.isabs(peer_cwd):
                # Una ruta relativa se resolveria contra el directorio del PROCESO
                # DEL HOOK, no contra el del peer: inventaria una carpeta que nadie
                # ocupa. Y esto esta en la ruta de DENEGACION, asi que una mala
                # resolucion bloquea trabajo legitimo. Se descarta ese peer.
                continue
            try:
                p = os.path.realpath(peer_cwd)
            except Exception:
                continue
            if worktree_root(p) not in targets:
                continue  # raiz de worktree distinta: ya estan aislados
            matches.append(d)
        if matches:
            # El peer MAS FRESCO decide el veredicto: si al menos uno esta vivo
            # con certeza, se deniega; solo se avisa si TODOS los que comparten
            # carpeta estan en la banda tibia. El orden de glob.glob es arbitrario
            # y no debe decidir esto (antes ganaba el primer match, sin mas).
            freshest = min(matches, key=lambda d: now - d.get("_mtime", 0))
            age = int(now - freshest.get("_mtime", 0))
            if age <= FRESH:
                tree_denied = True
                denies.append(
                    "Otra sesion de Claude Code esta viva en ESTA MISMA carpeta (candado %s, "
                    "actividad hace %ss). 'git %s' reescribiria o borraria en disco los archivos "
                    "que esa sesion esta editando ahora mismo, sin que su agente se entere. "
                    "Bloqueado por session-guardian. Sigue trabajando sobre el arbol tal como "
                    "esta (editar archivos distintos es seguro), o abre una sesion de Claude "
                    "Code NUEVA en otra carpeta si necesitas trabajar en paralelo de verdad."
                    % (freshest["_id"][:8], age, tree_ops[0])
                )
            else:
                warns.append(
                    "hay un candado de otra sesion en esta misma carpeta (%s) sin actividad desde "
                    "hace %ss; puede estar muerta sin limpiar. 'git %s' reescribe o borra archivos "
                    "del arbol de trabajo: confirma que nadie mas esta editando aqui antes de seguir."
                    % (freshest["_id"][:8], age, tree_ops[0])
                )

    # Rule 1 — same-branch collision (confirmed): another live session is on my branch
    if actual_branch and (verbs & {"commit", "push", "merge", "rebase", "cherry-pick"}):
        for d in foreign:
            if d.get("branch") and d["branch"] == actual_branch:
                denies.append(
                    "Otra sesion de Claude Code sigue viva en la rama '%s' (candado %s). "
                    "Dos sesiones en la misma rama se pisan el indice y la rama. "
                    "Operacion git bloqueada por session-guardian. Coordina con esa sesion, o abre "
                    "una sesion de Claude Code NUEVA en otra carpeta: el aislamiento solo funciona "
                    "si la sesion arranca alli (mudar una sesion ya arrancada no funciona, por eso "
                    "1.7.0 elimino las worktrees automaticas)."
                    % (actual_branch, d["_id"][:8])
                )
                break

    # Rule 2 — branch-on-top (integration ops): my HEAD is built on a peer's live tip
    if actual_head and integ:
        mref = main_ref()
        for d in foreign:
            H = (d.get("head") or "").strip()
            if not H:
                continue
            if git("merge-base", "--is-ancestor", H, actual_head).returncode != 0:
                continue  # my HEAD does not descend from their tip -> independent, fine
            if mref:
                if git("merge-base", "--is-ancestor", H, mref).returncode == 0:
                    continue  # their tip is already in mainline -> shared history, fine
                denies.append(
                    "Tu rama esta construida ENCIMA de commits vivos de otra sesion "
                    "(candado %s, rama '%s', tip %s) que aun no estan en la linea principal. "
                    "Integrarla (push/merge/rebase) arrastraria ese trabajo ajeno. "
                    "Bloqueado por session-guardian. Rebasea sobre la linea principal o coordina antes de integrar."
                    % (d["_id"][:8], d.get("branch", "?"), H[:8])
                )
                break
            else:
                warns.append(
                    "no pude confirmar la linea principal para verificar si tu rama se apoya "
                    "en trabajo vivo de otra sesion (candado %s, tip %s); revisa 'git log --oneline' antes de integrar."
                    % (d["_id"][:8], H[:8])
                )

    # Rule 3 — shared stash: the stash is repo-global, shared across worktrees
    if "stash" in verbs:
        sub = stash.get("sub") or ""
        explicit = stash.get("explicit", False)
        if stash.get("tree") and tree_denied:
            # La regla 0 ya DENEGO esta invocacion por compartir carpeta con un
            # peer fresco, que es el dano mayor y el mensaje mas concreto: no se
            # duplica aqui. Se exige la denegacion, no la mera presencia de un
            # peer: si la regla 0 solo aviso (banda tibia), esta regla debe seguir
            # su curso, o un peer tibio en la MISMA carpeta acabaria mas permisivo
            # que uno en otra carpeta -- justo al reves de lo que toca.
            pass
        elif sub in ("list", "show"):
            pass  # read-only
        elif sub in ("pop", "apply"):
            if not explicit:
                denies.append(
                    "Hay otra sesion de Claude Code viva y el 'git stash' es compartido por todo el repo "
                    "(incluidos los worktrees). 'git stash %s' sin una referencia stash@{n} explicita "
                    "podria sacar el stash de otra sesion. Bloqueado por session-guardian. "
                    "Usa 'git stash list' y aplica una referencia explicita, o coordina." % sub
                )
        elif sub in ("drop", "clear"):
            denies.append(
                "Hay otra sesion viva y el stash es compartido; 'git stash %s' es destructivo sobre ese "
                "cajon compartido. Bloqueado por session-guardian." % sub
            )
        else:
            warns.append(
                "hay otra sesion de Claude Code viva y el 'git stash' es compartido por todo el repo; "
                "tu stash y el de la otra sesion conviven en la misma pila, al recuperar usa referencias stash@{n} explicitas."
            )

    # --- emit: deny wins over warn ----------------------------------------------
    if denies:
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": " ".join(denies),
            }
        }))
    elif warns:
        msg = "session-guardian: " + " ".join(warns)
        print(json.dumps({
            "systemMessage": "⚠️ " + msg,
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "additionalContext": msg,
            }
        }))
    sys.exit(0)


# Red de seguridad de ULTIMO recurso. Un hook JAMAS puede romper una sesion,
# asi que cualquier excepcion que se escape de main() termina en salida limpia.
# No sustituye a las guardas de tipo de arriba, las respalda: las guardas
# mantienen al hook HACIENDO SU TRABAJO ante un payload raro; esto solo evita
# que un fallo imprevisto escriba un traceback en stderr. Si esta red se
# dispara, el hook no protege: la respuesta correcta es anadir la guarda que
# falte, no ampliar el except.
try:
    main()
except Exception:
    pass
sys.exit(0)
PY
exit 0
