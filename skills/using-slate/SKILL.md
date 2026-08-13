---
name: using-slate
description: Use when starting any session in a project that contains docs/slate/progress/ or docs/slate/features/ directories. Establishes the protocol for reading current state, updating progress, and respecting the feature list as canonical scope.
---

# Using slate

Loads at SessionStart in projects initialized with slate.

## State files (canonical)

- `docs/slate/progress/current.md` — work in flight. Read at start, update during, drain at end.
- `docs/slate/progress/history.md` — append-only log. Never edit existing entries.
- `docs/slate/features/backlog.md` — desired but not started.
- `docs/slate/features/in-progress.md` — actively being built.
- `docs/slate/features/done.md` — completed. Editing entries here is FORBIDDEN.
- `*-archive-YYYYHn.md` (`docs/slate/features/done-archive-*`, `docs/slate/bugs/fixed-archive-*`, `docs/slate/progress/history-archive-*`) — rotated history. Canonical but NEVER bulk-loaded in normal operation. `grep` them on demand only. See `docs/archiving.md`.

## Protocol

1. **Session start**: the hook already injected recent history and active features. Do not re-read those files unless you need detail beyond what was injected.
2. **Before dispatching a subagent**: invoke `tracking-progress` to log the dispatch.
3. **Before marking work done**: invoke `managing-feature-list`. A feature only moves to `done.md` when ALL subtasks are `[x]` AND `Verified: <date>` is set.
4. **Session end**: append the contents of `docs/slate/progress/current.md` to `docs/slate/progress/history.md` under a `## YYYY-MM-DD — <summary>` heading, then clear `current.md`.

## Interop with Superpowers

slate does NOT replace Superpowers.
- `superpowers:brainstorming` → spec in `docs/superpowers/specs/`.
- `superpowers:writing-plans` → plan in `docs/superpowers/plans/`.
- After the plan is approved, invoke `breaking-down-features` to derive entries in `docs/slate/features/backlog.md`.

## Anti-patterns

- DO NOT introduce JSON, YAML, or SQLite alternatives. Markdown is the contract.
  The ONE exception: `.git/slate-ids/` (see `scripts/reserve-id.sh`), a set of
  empty marker directories used to atomically reserve a `FEAT-NNN`/`BUG-NNN`
  before it is written anywhere. It is not a product document — it is an
  internal technical marker: invisible, and never version-controlled (it
  lives inside `.git`, which is not itself tracked by git).
- DO NOT edit entries in `done.md`. Create a successor with `Supersedes: FEAT-XXX`.
- DO NOT skip `tracking-progress`. Commit messages are too terse for cross-session recovery.
- DO NOT read all four `docs/slate/features/*.md` files preemptively. Use what the hook injected plus targeted reads.
- DO NOT read `done.md` whole to compute the next `FEAT-NNN`. Use the bounded `grep` in `managing-feature-list` / `docs/feature-format.md`. Same for `BUG-NNN`.
- DO NOT bulk-read `*-archive-*.md` files. They exist to be `grep`ed on demand, never loaded into context.
