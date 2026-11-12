---
name: defrag
description: Review what deck has learned and decide what to keep - proposals for the user profile, engrams, new skills, and brief improvements. Use when the user runs /defrag, asks what deck has learned, or wants to review or prune memory.
---

# Defrag

The learning loop: gather signals, propose, and apply only what the user approves.

## 1. Gather

- Pending items in `data/proposals.md`.
- Since the last defrag (timestamp in `state/last-defrag`, or all time): the **Friction** and **Follow-ups** sections of each `data/jobs/*/report.md`, and the user's corrections in this conversation.
- Repetition: three or more jobs with a similar title or brief suggest a skill.
- Pruning: profile and engrams that contradict newer facts, refer to files or projects that no longer exist, or push the budget over (profile ≤ 300 words; engrams ≤ 40 files).

Draft new proposals from what you find. Don't propose anything already in `data/proposals.md` as `[rejected]`.

## 2. Proposal format

Append each one to `data/proposals.md`:

```
## P<n> <kind>: <one-line title> [pending]
- target: <file it would change>
- why: <the evidence: which job, which correction>
- change: <exact text to add, edit, or remove>
```

Kinds and where they land:

| kind | target | tracked? |
| --- | --- | --- |
| `profile` | `data/profile.md`: how the user likes to work | private |
| `engram` | `data/engrams/<slug>.md`: a fact about a project or the user's setup | private |
| `brief-patch` | `learned/brief-addendum.md`: a standing instruction for every worker | committed to fork |
| `skill` | `.agents/skills/<name>/SKILL.md`: a reusable procedure | committed to fork |
| `prune` | removes or rewrites an existing entry | as the target |

Engram file shape:

```
---
scope: global | <project-name>
audience: worker | operator | both
created: <YYYY-MM-DD>
why: <one line>
---
<the fact, one to three sentences>
```

`audience: worker` engrams are pasted into every brief for that scope, so keep them short and useful to a stranger. `operator` engrams are for you only (printed at session start). Engrams written before the rename may say `runner` or `fixer` instead; they mean `worker` and `operator`.

## 3. Review with the user

Present proposals one at a time, in the persona's voice: the title, the why, and the exact change. The user accepts, edits, or rejects.

- **Accept or edit**: apply the change, then mark the proposal `[accepted]`. For tracked targets (`brief-patch`, `skill`), commit right away: `git add <files> && git commit -m "learned: <title>"`. Offer to push to their fork; never push without a yes.
- **Reject**: mark it `[rejected]` and keep it, so it isn't proposed again.
- **Later**: leave it `[pending]`.

A new skill should be small: a frontmatter `name` and a `description` that says when to use it, then the steps. Neutral language, no persona slang.

## 4. Finish

Write the current UTC time to `state/last-defrag`. Summarize in one line what was kept.
