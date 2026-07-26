---
description: Triage the ideas inbox — group by area, propose priority, and promote/archive/keep-pending each idea.
---

Invoke the `managing-ideas` skill's triage path.

Read `docs/slate/ideas/inbox.md` and, before anything else, do two passes that
cost nothing and save the whole session:

1. **Misfiled entries.** Anything already broken (bug, wrong production setting,
   docs contradicting the code) is not an idea. Pull it out first and file it via
   `tracking-bugs` — those are the entries that were costing something while they
   sat in the inbox.
2. **Duplicates.** Merge lines that describe the same thing, keeping the richer
   wording. Report how many were collapsed.

Then group what remains by area (frontend/backend/db/ux/other), propose a
priority per group, and walk me through each idea asking whether to promote it
to a feature (via `breaking-down-features`), archive it, or leave it pending.

Batch aggressively: offer whole-group decisions and stop asking one by one once I
answer the same way twice. Log every decision to `docs/slate/ideas/triaged.md`
per `docs/idea-format.md`.
