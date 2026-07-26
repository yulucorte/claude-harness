---
description: Capture a quick development idea into docs/slate/ideas/inbox.md without interrupting current work.
---

Invoke the `managing-ideas` skill's capture path for this idea: $ARGUMENTS

Follow its three steps:

1. **Is it an idea, or already broken?** Something wrong right now (a bug, a
   broken production setting, docs contradicting the code) goes to
   `docs/slate/bugs/open.md` via `tracking-bugs`, NOT to the inbox — filed as an
   idea it gets buried and never read again.
2. **Grep the inbox** for the most distinctive words before writing. Do not
   append a duplicate of a line that already exists.
3. **Append** one dated line, verbatim, to `docs/slate/ideas/inbox.md` per
   `docs/idea-format.md`.

Do not categorize, prioritize, or ask follow-up questions. Confirm in one line,
naming where it landed (inbox or bugs) and whether it merged into an existing
entry.
