#!/usr/bin/env bash
# PostToolUse hook (all tools): session-lock guardian, heartbeat refresh.
# Two jobs, both strictly passive (PostToolUse cannot block, and this never tries):
#   1. touch the lock so it isn't reaped as stale (liveness).
#   2. mirror this session's CURRENT branch + tip (head SHA) into the lock, so a
#      peer session can detect a branch built on top of this session's live work
#      right after a commit. Uses the payload `cwd` so it is correct even when
#      this session works inside an isolated worktree.
set -uo pipefail

STDIN_JSON=""
if [ ! -t 0 ]; then
  STDIN_JSON=$(cat 2>/dev/null || true)
fi
[ -z "$STDIN_JSON" ] && exit 0

SG_JSON="$STDIN_JSON" python3 - <<'PY'
import sys, os, json, subprocess

try:
    payload = json.loads(os.environ.get("SG_JSON") or "{}")
except Exception:
    sys.exit(0)

sid = (payload.get("session_id") or "").strip()
if not sid:
    sys.exit(0)
cwd = (payload.get("cwd") or "").strip() or os.environ.get("CLAUDE_PROJECT_ROOT") or os.getcwd()
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
    sys.exit(0)  # this session never claimed a lock; nothing to refresh

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
PY
exit 0
