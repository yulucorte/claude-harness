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

try:
    payload = json.loads(os.environ.get("SG_JSON") or "{}")
except Exception:
    sys.exit(0)

sid = (payload.get("session_id") or "").strip()
cmd = (payload.get("tool_input") or {}).get("command") or ""
cwd = (payload.get("cwd") or "").strip()
if not sid or not cmd:
    sys.exit(0)
if not cwd:
    cwd = os.environ.get("CLAUDE_PROJECT_ROOT") or os.getcwd()
if not os.path.isdir(cwd):
    sys.exit(0)


def git(*args):
    try:
        return subprocess.run(
            ["git", "-C", cwd, *args],
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
    stash = {"sub": None, "explicit": False}
    tree_dir = None  # valor de -C/--work-tree visto junto a un tree-op detectado
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
            if tree_dir is None:
                tree_dir = seg_dir or cwd
        elif verb == "reset":
            # --hard, --merge y --keep reescriben archivos del arbol de trabajo;
            # --soft y --mixed solo tocan HEAD/indice, nunca los archivos.
            if any(f in toks[j + 1:] for f in ("--hard", "--merge", "--keep")):
                verbs.add("tree:reset")
                if tree_dir is None:
                    tree_dir = seg_dir or cwd
        elif verb == "stash":
            verbs.add("stash")
            sub = toks[j + 1] if j + 1 < len(toks) else ""
            if sub.startswith("-"):
                sub = ""
            stash = {"sub": sub, "explicit": ("stash@{" in seg)}
    return verbs, stash, tree_dir


verbs, stash, tree_dir = classify(cmd)
if not verbs:
    sys.exit(0)

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

FRESH = 300  # s. Peer con lock mas nuevo que esto = vivo casi con certeza.

# Rule 0 — reescritura del arbol: un peer vivo en la MISMA carpeta fisica.
# Es la unica clase de dano catastrofico: 'checkout'/'switch'/'restore'/
# 'reset --hard|--merge|--keep' reescriben los archivos que el otro agente
# esta editando, en vivo y sin que se entere. En carpetas distintas no hay
# nada que proteger (por eso se respeta un -C/--work-tree explicito).
tree_ops = sorted(v.split(":", 1)[1] for v in verbs if v.startswith("tree:"))
if tree_ops:
    # El objetivo real de la operacion: -C/--work-tree si el comando lo trae
    # (un checkout hacia OTRO repo no toca esta carpeta); si no, esta sesion.
    target = tree_dir if tree_dir else cwd
    if not os.path.isabs(target):
        target = os.path.join(cwd, target)
    try:
        my_dir = os.path.realpath(target)
    except Exception:
        my_dir = ""
    matches = []
    for d in foreign:
        peer_cwd = d.get("cwd")
        if not isinstance(peer_cwd, str):
            continue  # ausente o de tipo inesperado: nunca se deniega a ciegas
        peer_cwd = peer_cwd.strip()
        if not my_dir or not peer_cwd:
            continue  # lock legado sin cwd: se ignora, nunca se deniega a ciegas
        try:
            if os.path.realpath(peer_cwd) != my_dir:
                continue  # carpetas distintas: ya estan aislados
        except Exception:
            continue
        matches.append(d)
    if matches:
        # El peer MAS FRESCO decide el veredicto: si al menos uno esta vivo
        # con certeza, se deniega; solo se avisa si TODOS los que comparten
        # carpeta estan en la banda tibia. El orden de glob.glob es arbitrario
        # y no debe decidir esto (antes ganaba el primer match, sin mas).
        freshest = min(matches, key=lambda d: now - d.get("_mtime", 0))
        age = int(now - freshest.get("_mtime", 0))
        if age <= FRESH:
            denies.append(
                "Otra sesion de Claude Code esta viva en ESTA MISMA carpeta (candado %s, "
                "actividad hace %ss). 'git %s' reescribiria en disco los archivos que esa "
                "sesion esta editando ahora mismo, sin que su agente se entere. "
                "Bloqueado por session-guardian. Trabaja sobre la rama actual, o abre una "
                "sesion nueva en otra carpeta si necesitas otra rama."
                % (freshest["_id"][:8], age, tree_ops[0])
            )
        else:
            warns.append(
                "hay un candado de otra sesion en esta misma carpeta (%s) sin actividad desde "
                "hace %ss; puede estar muerta sin limpiar. 'git %s' reescribe el arbol de "
                "trabajo: confirma que nadie mas esta editando aqui antes de seguir."
                % (freshest["_id"][:8], age, tree_ops[0])
            )

# Rule 1 — same-branch collision (confirmed): another live session is on my branch
if actual_branch and (verbs & {"commit", "push", "merge", "rebase", "cherry-pick"}):
    for d in foreign:
        if d.get("branch") and d["branch"] == actual_branch:
            denies.append(
                "Otra sesion de Claude Code sigue viva en la rama '%s' (candado %s). "
                "Dos sesiones en la misma rama se pisan el indice y la rama. "
                "Operacion git bloqueada por session-guardian. Coordina o aisla esta sesion en un worktree."
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
    if sub in ("list", "show"):
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
PY
exit 0
