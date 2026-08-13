---
name: managing-feature-list
description: Use when the user defines new scope, when about to mark anything complete, when the user asks "what's left", or when moving work between backlog/in-progress/done. Maintains docs/slate/features/backlog.md, docs/slate/features/in-progress.md, docs/slate/features/done.md.
---

# Managing the feature list

The three files in `docs/slate/features/` are the canonical scope. Plans (`docs/superpowers/plans/`) describe HOW; the feature list describes WHAT and WHETHER IT WORKS.

## Format of a feature entry

See `docs/feature-format.md` for the full reference. Minimum:

    ## FEAT-XXX: <Title>
    - **Status**: backlog | in_progress | done
    - **Created**: YYYY-MM-DD
    - **Updated**: YYYY-MM-DD
    - **Plan**: docs/superpowers/plans/<file>.md (or `none`)
    - **Branch**: feat/feat-NNN-<slug> (or `none`)
    - **Verified**: YYYY-MM-DD (only when Status: done)

    ### Subtasks
    - [ ] FEAT-XXX.1: <subtask>

## Movement rules

Every feature MUST pass through `in-progress.md` so SessionStart can recover context.

| From | To | Condition |
|---|---|---|
| backlog.md | in-progress.md | Work is starting now. Soft recommendation: only one feature in-progress at a time. |
| in-progress.md | done.md | ALL subtasks `[x]` AND `Verified: <date>` set. Verification before moving is recommended. |
| in-progress.md | backlog.md | User explicitly defers it. |
| backlog.md | done.md | FORBIDDEN. Route through `in-progress.md`. |
| any | edit done.md | FORBIDDEN. Create a successor with `Supersedes: FEAT-XXX`. |

## ID assignment

Do NOT read the files whole — that is the expensive mistake. Get the highest
`FEAT-NNN` with a bounded search over the live files AND the pending
reservations other branches may already hold (a session on an unmerged
branch can have claimed a higher number that appears in no file yet):

    grep -hoE 'FEAT-[0-9]+' docs/slate/features/backlog.md docs/slate/features/in-progress.md docs/slate/features/done.md 2>/dev/null \
      | grep -oE '[0-9]+' | sort -n | tail -1
    ls "$(git rev-parse --git-common-dir)/slate-ids/FEAT" 2>/dev/null | sort -n | tail -1

Candidate ID = the HIGHER of those two numbers + 1, zero-padded to 3 digits
(e.g. `FEAT-043`). Empty output from both → `FEAT-001`.

**Reserve it before writing it anywhere**: `$CLAUDE_PLUGIN_ROOT/scripts/reserve-id.sh FEAT-043`.
Exit 0 → the ID is yours, use it. Non-zero exit → another branch/session
reserved it first; retry with the next candidate (`FEAT-044`, ...) and
reserve THAT, until a reservation succeeds. This is what closes the race a
plain `grep`+1 can't: two sessions on different unmerged branches computing
the same "max + 1" and both picking it, invisibly to each other until they
merge.

Subtasks: `FEAT-XXX.M` where `M` is the next integer within the feature.
Subtasks are NOT reserved — they live inside an already-reserved feature, so
there's no cross-branch race to protect. IDs are immutable.

The file search reads only the live files, never the `done-archive-*.md` files:
archiving moves only the oldest (lowest-numbered) entries, so the highest number
always stays live. See `docs/archiving.md`.

The reservation directory (`scripts/reserve-id.sh`) is a per-repo, per-machine
safety net: it's shared via `git rev-parse --git-common-dir`, so every branch
and worktree of the SAME repo sees it, but it does NOT protect across
separate clones or machines that never share a `.git`.

## Archiving done.md

`done.md` is append-only and would grow without bound. When it exceeds **40
entries**, rotate before (or right after) appending the completed feature: move
the **oldest** entries in bulk — leaving the ~20 most recent — into
`docs/slate/features/done-archive-YYYYHn.md` (`H1` = Jan–Jun, `H2` = Jul–Dec, by today's
date). Entries move intact, oldest-first. This is the ONLY sanctioned way to
shrink `done.md`; full reference in `docs/archiving.md`.

## When subtasks complete

Mark `[x]` and update `Updated:`. Do not move the feature until ALL subtasks are checked AND `Verified:` is set.

## Anti-patterns

- DO NOT mark `Status: done` without a `Verified:` date.
- DO NOT delete or rewrite a feature in `done.md`. Append a successor. (Moving whole, untouched entries in bulk to `done-archive-YYYYHn.md` is the ONE exception — that changes where a card lives, not what it says. See `docs/archiving.md`.)
- DO NOT use statuses like "almost done" or "WIP". Only `backlog | in_progress | done`.
- DO NOT skip `in-progress.md`. Even retroactive work routes through it.
