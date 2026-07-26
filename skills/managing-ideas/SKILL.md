---
name: managing-ideas
description: Use when the user wants to jot down a future idea mid-session ("anota esta idea...", "se me ocurrió que...", or /idea), or when running /ideas-triage to group, prioritize, and promote/archive accumulated ideas. Maintains docs/slate/ideas/inbox.md and docs/slate/ideas/triaged.md.
---

# Managing ideas

Two triggers, one skill — same shape as `managing-feature-list` covering
multiple lifecycle stages.

## Capture (low friction — no judgment calls)

Trigger: the user says something like "anota esta idea...", "se me ocurrió
que...", or runs `/idea "<text>"`.

### Step 1 — is it an idea, or something already broken?

The inbox is a DEPOSIT for future work. Anything that is **already wrong right
now** does not belong there: it gets buried and nobody reads it again. Route it
instead:

| What it is | Goes to |
|---|---|
| Something to build later | `docs/slate/ideas/inbox.md` |
| Something broken in code | `docs/slate/bugs/open.md` via `tracking-bugs` |
| Broken config/data in production, no code change | `docs/slate/bugs/open.md`, `Where: <screen/setting>` |
| Docs or `CLAUDE.md` contradicting the code | `docs/slate/bugs/open.md` — it misleads every future session |

Decide silently from the text; only ask the user when it is genuinely
ambiguous. A known defect with a trigger ("breaks when the first non-Colombian
tenant signs up") is a bug with a deadline you do not control, not an idea.

### Step 2 — check for a duplicate

`grep` the inbox for the 2–3 most distinctive words of the new idea before
writing:

    grep -in '<keyword>' docs/slate/ideas/inbox.md

If a line already covers it: do NOT append a second one. Either leave it alone
or enrich the existing line, and say so in your one-line confirmation. Capturing
without reading is how an inbox of 28 lines turns out to hold 21 ideas and 7
duplicate pairs.

### Step 3 — append

One line, verbatim, no reformatting:

    - YYYY-MM-DD HH:MM — <raw idea text, verbatim>

Do not categorize, prioritize, or ask clarifying questions beyond step 1.
The whole point is near-zero interruption to the current flow.

## Triage (explicit, on demand)

Trigger: the user runs `/ideas-triage`.

Steps:

1. Read `docs/slate/ideas/inbox.md` in full (it's meant to stay short between triage
   passes).
2. Group the lines by area: frontend, backend, db, ux, other. Propose a
   priority (low/med/high) per group based on your judgment of impact/effort.
3. Present the grouped list to the user and ask, per idea (or per group if
   they're fine batching): promote, archive, or keep pending.
4. For each `promote`: invoke `breaking-down-features` to create the
   `FEAT-XXX` entry, then log the idea in `docs/slate/ideas/triaged.md` with
   `Outcome: promoted:FEAT-XXX`, and remove that line from `docs/slate/ideas/inbox.md`.
5. For each `archive`: log with `Outcome: archived`, remove the line from
   `docs/slate/ideas/inbox.md`.
6. For each `keep pending`: log with `Outcome: kept-pending`, but leave the
   line in `docs/slate/ideas/inbox.md` untouched — it comes up again next triage.

See `docs/idea-format.md` for the exact entry formats.

## Triage is on-demand, never nagged

The inbox is a deposit, not a queue. SessionStart stays silent about it until it
crosses `SLATE_IDEAS_NAG_AT` (default 40). Do not prompt the user to run
`/ideas-triage`: a reminder that gets ignored every session trains them to skip
that whole region of the startup message. If something in the inbox needs
attention today, it is because it was MISFILED (see step 1) — surface that one
entry, not the backlog.

## Anti-patterns

- DO NOT file a known defect as an idea. If it is already broken, it is a bug.
- DO NOT append without grepping first. Duplicates are the inbox's failure mode.
- DO NOT categorize or prioritize at capture time — that's triage's job.
- DO NOT edit or delete existing entries in `docs/slate/ideas/triaged.md`. It is
  append-only.
- DO NOT silently drop a `kept-pending` idea from `inbox.md` — only
  `promoted` and `archived` outcomes remove the line.
- DO NOT invent a `FEAT-XXX` ID yourself when promoting — always go through
  `breaking-down-features` so ID assignment stays centralized.
