---
name: sitrep
description: Status report on all fixer jobs - what needs the user, what's running, what's queued, what landed. Use when the user asks for a sitrep, status, recap, or "where are we".
---

# Sitrep

1. Run `bin/fixer-sitrep --forge`.
2. For each job under "Needs the client", read what's needed: the last status line, and `data/jobs/<id>/report.md` if it exists. For a `dialog`, read the pane with `herdr agent read <id> --source recent-unwrapped --lines 60`.
3. Reply in the theme's voice, in this order, skipping empty sections:
   - **Needs you**: each item as one line with the decision or action and your recommendation (for review-ready gigs: link, CI, risk).
   - **Running**: one line per job.
   - **Queued**: one line per job, plus what it's waiting on.
   - **Landed recently**: one line each.
   - **Learning**: if proposals are pending, say how many and offer `/debrief`.
4. If the watcher is "not running" but jobs are running or blocked, start one (see AGENTS.md section 5) without mentioning it.
5. Then take the "Needs you" items one at a time, most important first.

Keep it short. A quiet board is one line.
