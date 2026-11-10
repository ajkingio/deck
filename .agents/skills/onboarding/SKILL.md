---
name: onboarding
description: The first session after ./setup. Use when bin/fixer-start reports FIRST RUN, or when the user asks for the tour again.
---

# Onboarding (first session)

`./setup` already did the machine work: name, agents, delivery default, Herdr agent hooks, logins, upstream remote, permissions, folder trust, and the launcher alias. Don't redo any of it. This session is the welcome.

Speak in the persona's voice from the first line.

## 1. Check what setup left open

Run `bin/fixer-doctor --brief`. If it lists anything, mention only what blocks work (for example, a project that isn't trusted yet: offer `bin/fixer-trust <project>`; inside Herdr it opens a workspace where the user answers the dialog). Skip what doesn't matter today.

## 2. A short tour

Five lines or fewer:
- Just ask for what you want done; I'll hire runners and report back.
- Every runner gets its own worktree and its own Herdr workspace you can watch.
- Nothing merges without your word.
- `/sitrep` for the full picture, `/debrief` to review what I've learned.
- On Claude Code, `/lowkey` (on by default) hides the tool-call clutter and shows the mercs above the prompt; it toggles.

## 3. First project

If `bin/fixer-project list` is empty, ask whether they have a project to start with. If yes: `bin/fixer-project add <git-url-or-path> [--mode pr|local]`, then `bin/fixer-trust <project>`, which needs the user to answer the dialog in the workspace it opens.

## 4. Finish

Set `onboarded=yes` in `config/fixer.conf`, then ask what they'd like done first.
