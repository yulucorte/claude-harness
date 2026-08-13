#!/usr/bin/env bash
# PostToolUse hook (all tools): session-lock guardian, heartbeat refresh.
# Two jobs, both strictly passive (PostToolUse cannot block, and this never tries):
#   1. touch the lock so it isn't reaped as stale (liveness).
#   2. mirror this session's CURRENT branch + tip (head SHA) into the lock, so a
#      peer session can detect a branch built on top of this session's live work
#      right after a commit. Uses the payload `cwd`: the physical folder this
#      session really works in, which is what the guardian compares peers by.
#      (Automatic worktree isolation was removed in 1.7.0 — a SessionStart hook
#      cannot relocate a session that is already running. Real parallel work
#      means opening a NEW Claude Code session in a different folder.)
set -uo pipefail

STDIN_JSON=""
if [ ! -t 0 ]; then
  STDIN_JSON=$(cat 2>/dev/null || true)
fi
[ -z "$STDIN_JSON" ] && exit 0

SG_JSON="$STDIN_JSON" python3 - <<'PY'
import sys, os, json, subprocess, time


def main():
    try:
        payload = json.loads(os.environ.get("SG_JSON") or "{}")
    except Exception:
        sys.exit(0)

    # Mismo contrato de tipos que session-guardian.sh: el payload de nivel superior
    # puede no ser un objeto (una lista, un numero, una cadena), y CADA campo puede
    # llegar con un tipo inesperado. Se comprueba isinstance y se degrada al valor
    # vacio; nunca se asume el tipo. Un .strip()/.get() sobre el tipo equivocado
    # aqui tumbaba TODO el heartbeat (liveness y espejo incluidos), porque estas
    # lineas corren antes de llegar al resto del script -- y como el envoltorio bash
    # acaba siempre en 'exit 0', el latido desaparecia sin rastro y la sesion pasaba
    # a parecer muerta para el guardian.
    if not isinstance(payload, dict):
        sys.exit(0)

    sid = payload.get("session_id")
    sid = sid.strip() if isinstance(sid, str) else ""
    if not sid:
        sys.exit(0)
    raw_cwd = payload.get("cwd")
    cwd = raw_cwd.strip() if isinstance(raw_cwd, str) else ""
    cwd = cwd or os.environ.get("CLAUDE_PROJECT_ROOT") or os.getcwd()

    # Herramienta que acaba de ejecutarse. Solo las de escritura dejan rastro en el
    # lock: son las unicas que pueden pisar el trabajo de otra sesion.
    tool = payload.get("tool_name")
    tool = tool.strip() if isinstance(tool, str) else ""
    tool_input = payload.get("tool_input")
    tool_input = tool_input if isinstance(tool_input, dict) else {}
    written = ""
    if tool in ("Write", "Edit", "NotebookEdit"):
        fp = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
        written = fp.strip() if isinstance(fp, str) else ""

    if not os.path.isdir(cwd):
        sys.exit(0)


    def git(*a):
        try:
            return subprocess.run(
                ["git", "-C", cwd, *a],
                capture_output=True, text=True, timeout=10,
            )
        except Exception:
            class _R:
                returncode = 1
                stdout = ""
                stderr = ""
            return _R()


    if git("rev-parse", "--git-dir").returncode != 0:
        sys.exit(0)

    r = git("rev-parse", "--git-common-dir")
    gcd = r.stdout.strip()
    if not gcd:
        sys.exit(0)
    if not os.path.isabs(gcd):
        gcd = os.path.join(cwd, gcd)
    gcd = os.path.realpath(gcd)

    lock = os.path.join(gcd, "slate-sessions", sid + ".lock")
    if not os.path.isfile(lock):
        # 1.9.0: RECREATE instead of doing nothing. session-lock.sh and
        # session-lock-cleanup.sh both reap locks older than 15min
        # (find -mmin +15 -delete) so dead sessions don't pile up forever.
        # But a session that is genuinely alive and simply hasn't called a
        # tool in >15min (thinking, waiting on the user, one long-running
        # tool) has ITS lock reaped too by a peer merely starting or ending.
        # Leaving this as a no-op made that session invisible to
        # session-guardian.sh from then on: a peer could checkout/reset/stash
        # over its live work with no deny and no warn. Recreate with the same
        # shape session-lock.sh writes, so the next tree-op check sees it again.
        try:
            os.makedirs(os.path.dirname(lock), exist_ok=True)
            br = git("branch", "--show-current").stdout.strip()
            hd = git("rev-parse", "HEAD").stdout.strip()
            try:
                rp = os.path.realpath(cwd)
            except Exception:
                rp = cwd
            files = []
            if written:
                files = [{"path": written, "ts": int(time.time())}]
            data = {
                "branch": br, "worktree": "", "head": hd,
                "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "cwd": rp, "files": files,
            }
            tmp = lock + ".tmp"
            json.dump(data, open(tmp, "w"))
            os.replace(tmp, lock)
        except Exception:
            pass
        sys.exit(0)

    # 1. liveness: refresh mtime
    try:
        os.utime(lock, None)
    except OSError:
        pass

    # 2. mirror current branch/head (best effort, atomic write)
    try:
        d = json.load(open(lock))
    except Exception:
        sys.exit(0)

    br = git("branch", "--show-current").stdout.strip()
    hd = git("rev-parse", "HEAD").stdout.strip()
    changed = False
    if br and d.get("branch") != br:
        d["branch"] = br
        changed = True
    if hd and d.get("head") != hd:
        d["head"] = hd
        changed = True

    # Carpeta fisica viva de esta sesion. Se refresca siempre: un lock escrito por
    # una version anterior no la tiene, y el guardian la necesita para saber si un
    # peer comparte carpeta con nosotros.
    try:
        rp = os.path.realpath(cwd)
    except Exception:
        rp = ""
    if rp and d.get("cwd") != rp:
        d["cwd"] = rp
        changed = True

    # Archivos escritos recientemente por esta sesion. El guardian los usa para
    # avisar cuando dos sesiones de la misma carpeta editan lo mismo. Se acotan a
    # las 20 mas recientes, deduplicadas por ruta, para que el lock no crezca.
    if written:
        prev = d.get("files")
        if not isinstance(prev, list):
            prev = []
        files = [e for e in prev if isinstance(e, dict) and e.get("path") != written]
        files.append({"path": written, "ts": int(time.time())})
        d["files"] = files[-20:]
        changed = True

    if changed:
        tmp = lock + ".tmp"
        try:
            json.dump(d, open(tmp, "w"))
            os.replace(tmp, lock)  # atomic
        except Exception:
            try:
                os.remove(tmp)
            except OSError:
                pass

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
