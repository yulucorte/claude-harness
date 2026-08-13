---
name: tracking-bugs
description: Use when the user reports a bug, when diagnosing a bug's root cause, when a fix is about to be committed, or when the user asks "what bugs are open". Maintains docs/slate/bugs/open.md and docs/slate/bugs/fixed.md.
---

# Tracking bugs

The two files in `docs/slate/bugs/` are the canonical bug record. `docs/slate/bugs/open.md` is
mutable working state; `docs/slate/bugs/fixed.md` is the permanent, append-only record —
same relationship as `docs/slate/features/backlog.md` to `docs/slate/features/done.md`.

## Format of a bug entry

See `docs/bug-format.md` for the full reference. Minimum:

    ## BUG-XXX: <Title>
    - **Status**: open | fixed
    - **Severity**: low | medium | high | critical
    - **Reported-by**: <name/@handle>
    - **Detected**: YYYY-MM-DD
    - **Where**: <file/module/screen>
    - **Root cause**: <free text, or "unknown">
    - **Fix**: <free text, or "none">
    - **Commit**: <sha or branch, or "none">

## Lifecycle

1. **Report**: user describes a bug. Assign next `BUG-XXX` with a bounded
   search over the live files AND pending reservations from other branches
   — do NOT read the files whole:

       grep -hoE 'BUG-[0-9]+' docs/slate/bugs/open.md docs/slate/bugs/fixed.md 2>/dev/null \
         | grep -oE '[0-9]+' | sort -n | tail -1
       ls "$(git rev-parse --git-common-dir)/slate-ids/BUG" 2>/dev/null | sort -n | tail -1

   Candidate ID = the HIGHER of those two numbers + 1, zero-padded to 3
   digits. Empty output from both → `BUG-001`.

   Reserve it: `$CLAUDE_PLUGIN_ROOT/scripts/reserve-id.sh BUG-012`. Exit 0 →
   use it. Non-zero exit → another branch/session reserved it first; retry
   with the next candidate until a reservation succeeds.

   Append to `docs/slate/bugs/open.md` with `Root cause: unknown` and `Fix: none` if not
   yet diagnosed. Only live files are scanned; `fixed-archive-*.md` is never
   needed (archiving moves oldest entries only — see `docs/archiving.md`).
2. **Diagnose**: when the root cause is found, update the `Root cause` field
   in place (this is `open.md`, mutation is allowed here).
3. **Fix**: when a fix is committed, fill `Fix`, `Commit`, set
   `Status: fixed` and `Fixed: <date>`, then move the whole entry to
   `docs/slate/bugs/fixed.md`.
4. **Closed bugs never reopen.** If the same bug recurs, file a new
   `BUG-XXX` and note the earlier ID in its `Notes` section.

## ID assignment

Use the bounded search AND reservation check in step 1 of the Lifecycle above
(grep over `docs/slate/bugs/open.md docs/slate/bugs/fixed.md` plus
`.git/slate-ids/BUG/`, take the higher `max + 1`, reserve it with
`reserve-id.sh` before using it). Never read the files whole. IDs are
immutable and independent of `FEAT-XXX` numbering — reservations are kept in
separate `slate-ids/FEAT/` and `slate-ids/BUG/` buckets for the same reason.

## Archiving fixed.md

`docs/slate/bugs/fixed.md` is append-only. When it exceeds **40 entries**, move the
**oldest** entries in bulk — leaving the ~20 most recent — into
`docs/slate/bugs/fixed-archive-YYYYHn.md` (`H1` = Jan–Jun, `H2` = Jul–Dec, by today's
date). Entries move intact, oldest-first. This is the ONLY sanctioned way to
shrink `fixed.md`; full reference in `docs/archiving.md`.

## Anti-patterns

- DO NOT move a bug to `fixed.md` without `Fix`, `Commit`, and `Fixed:` all set.
- DO NOT edit or delete an entry in `fixed.md`. File a new `BUG-XXX` instead. (Moving whole, untouched entries in bulk to `fixed-archive-YYYYHn.md` is the ONE exception — that changes where an entry lives, not what it says.)
- DO NOT reuse a `BUG-XXX` ID after a bug is closed.
