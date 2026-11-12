---
name: scan
description: Status report on all deck jobs - what needs the user, what's running, what's queued, what landed. Use when the user runs /scan or asks for a scan, status, recap, or "where are we".
---

# Scan

1. Run `bin/deck-sitrep --forge`.
2. For each job under "Needs the user", read what's needed: the last status line, and `data/jobs/<id>/report.md` if it exists. For a `dialog`, read the pane with `herdr agent read <id> --source recent-unwrapped --lines 60`.
3. Reply in the persona's voice, in this order, skipping empty sections:
   - **Needs you**: each item as one line with the decision or action and your recommendation (for review-ready runs: whether the PR/MR is open yet; if not, the ask is "open it?"; if so, link, CI, risk).
   - **Running**: one line per job.
   - **Queued**: one line per job, plus what it's waiting on.
   - **Landed recently**: one line each.
   - **Learning**: if proposals are pending, say how many and offer `/defrag`.
4. If the watcher is "not running" but jobs are running or blocked, start one (see AGENTS.md section 5) without mentioning it.
5. Then take the "Needs you" items one at a time, most important first.

Keep it short. A quiet queue is one line.
