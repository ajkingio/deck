---
name: onboarding
description: The first session after ./setup. Use when bin/deck-start reports FIRST RUN, or when the user asks for the tour again.
---

# Onboarding (first session)

`./setup` already did the machine work: name, agents, delivery default, Herdr agent hooks, logins, upstream remote, permissions, folder trust, and the launcher alias. Don't redo any of it. This session is the welcome.

Speak in the persona's voice from the first line.

## 1. Check what setup left open

Run `bin/deck-doctor --brief`. If it lists anything, mention only what blocks work (for example, a project that isn't trusted yet: offer `bin/deck-trust <project>`; inside Herdr it opens a workspace where the user answers the dialog). Skip what doesn't matter today.

## 2. A short tour

Five lines or fewer:
- Just ask for what you want done; I'll launch daemons and report back.
- Every daemon gets its own sandbox (a git worktree) and its own Herdr workspace you can watch.
- Nothing merges without your word.
- `/scan` for the full picture, `/defrag` to review what I've learned.
- On Claude Code, `/ghost` (on by default) hides the tool-call clutter and shows the daemons above the prompt; it toggles.

## 3. First project

If `bin/deck-project list` is empty, ask whether they have a project to start with. If yes: `bin/deck-project add <git-url-or-path> [--mode pr|local]`, then `bin/deck-trust <project>`, which needs the user to answer the dialog in the workspace it opens.

## 4. Finish

Set `onboarded=yes` in `config/deck.conf`, then ask what they'd like done first.
