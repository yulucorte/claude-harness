#!/usr/bin/env bash
# Atomically reserve a FEAT-NNN / BUG-NNN candidate ID, so two sessions on
# different (not-yet-merged) branches can't both compute the same "grep the
# live files for the max, add 1" and pick the same number.
#
# Uses mkdir's atomicity: mkdir fails if the target directory already exists,
# which is enough for one-shot reservation without a separate lockfile.
# Reservations live under .git/slate-ids/<PREFIX>/<NUMBER>, resolved via
# `git rev-parse --git-common-dir` — the directory shared by every branch and
# every worktree of the SAME repo, unlike a linked worktree's own private
# .git file. Bucketed by prefix (FEAT/, BUG/, ...) so FEAT and BUG numbering,
# which is explicitly independent (see skills/tracking-bugs/SKILL.md), can
# never collide with each other.
#
# This is a per-repo, per-machine safety net: it does NOT protect across
# separate clones/machines that never share a .git directory.
#
# Usage: reserve-id.sh FEAT-144
# Exit 0: reserved. Exit non-zero: already reserved (try the next number) or
#         bad usage/environment — see the stderr message for which.
set -uo pipefail

ID="${1:-}"
if [ -z "$ID" ]; then
  echo "reserve-id: uso: reserve-id.sh <ID>  (ej. FEAT-144, BUG-012)" >&2
  exit 2
fi

# "FEAT-144" -> prefix "FEAT", number "144". Reject anything without that
# PREFIX-NUMBER shape instead of reserving something malformed.
PREFIX="${ID%%-*}"
NUMBER="${ID#*-}"
if [ -z "$PREFIX" ] || [ -z "$NUMBER" ] || [ "$PREFIX" = "$ID" ]; then
  echo "reserve-id: '$ID' no tiene forma PREFIJO-NUMERO (ej. FEAT-144)" >&2
  exit 2
fi

GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null)"
if [ -z "$GIT_COMMON_DIR" ]; then
  echo "reserve-id: no estas dentro de un repo git" >&2
  exit 2
fi
case "$GIT_COMMON_DIR" in
  /*) : ;;
  *) GIT_COMMON_DIR="$(pwd)/$GIT_COMMON_DIR" ;;
esac

RESERVE_DIR="$GIT_COMMON_DIR/slate-ids/$PREFIX"
if ! mkdir -p "$RESERVE_DIR" 2>/dev/null; then
  echo "reserve-id: no se pudo crear $RESERVE_DIR" >&2
  exit 2
fi

if mkdir "$RESERVE_DIR/$NUMBER" 2>/dev/null; then
  exit 0
fi

echo "reserve-id: $ID ya esta reservado (otra sesion o rama lo tomo primero); prueba el siguiente numero" >&2
exit 1
