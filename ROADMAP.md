# deck — roadmap: Pi and local models

This is the working plan for running deck on Pi and on locally served models. It is self-contained: a fresh operator on another machine (for example the Mac mini `tempo`) can read it and pick up the work without the MacBook's private `data/`.

Last updated: 2026-11-13.

## Goal

Make Pi a first-class harness in deck alongside Claude Code. Then add a `local` profile where the operator and workers run Pi against models served from the user's Mac mini (`tempo`) over Tailscale, with web search and other needed tools added to Pi.

Herdr stays the multiplexer until Rex is out of beta. Rex comes later, behind an adapter.

## Done (on `main`)

| Item | Where |
| --- | --- |
| Watcher Stop-hook guard for Claude operators | `bin/deck-turnend-guard`, `.claude/settings.json` |
| Behaviour test suite | `bin/deck-test`, `tests/` |
| pr-mode teardown refuses commits made after a PR merged | `bin/deck-teardown`, `tests/teardown.test.sh` |
| Relaunch and interrupt in place | `deck-spawn --relaunch`, `deck-tell --interrupt`, `gone` status |
| Pi as the **operator** harness | `.pi/extensions/deck-operator.ts` (watcher, settle backstop, write guard); `deck_harness=pi`; Pi trust in `deck-trust`; `/scan` and `/defrag` prompts |
| Pi as a **worker** harness | `pi` in `DECK_HARNESSES`; `deck-spawn` passes `--append-system-prompt templates/worker-system.md --name <id> --approve`, with `--approve` only when Pi trusts the project's main checkout (nothing written to `trust.json`); optional `pi_worker_model` and `pi_worker_thinking` in `config/deck.conf` (passed as `--model`/`--thinking`); `deck-tell --interrupt` sends `esc`; relaunch, setup and doctor support; `tests/pi.test.sh` |

## In progress

Nothing.

## Next, in order

### 1. Local-model trial (recon)

**Prerequisite:** Ollama on `tempo` reachable from the MacBook over Tailscale. On tempo, set `OLLAMA_HOST=0.0.0.0`; from the MacBook, check `curl http://tempo:11434/api/tags`. As of 2026-11-13 it did not answer.

**Prerequisite:** a live check of Pi workers in Herdr, which the test suite only covers against a stub. Run `herdr integration install pi`, then one real Pi gig through `deck-spawn`, `deck-tell --interrupt` (Escape should stop a turn mid-tool) and `deck-spawn --relaunch`, confirming Herdr detects the worker's working, idle and done states.

Steps:

1. Pull 2–3 candidate coding models on tempo. Favour mixture-of-experts models around the 30B class; a ~70B at 4-bit fits but is slow.
2. Add an Ollama provider to Pi's `models.json` pointing at `http://tempo:11434`.
3. Re-run an already-landed gig with a Pi worker on each model: `deck-teardown-pr-guard` (make `deck-teardown` refuse pr-mode branches with commits beyond the merged head). Pass/fail is `tests/teardown.test.sh`.
4. Report, per model: pass/fail, wall time, retries, and failure modes.

### 2. Web tools for Pi

Web search and page fetch, via a deck Pi extension or an MCP server (Pi has built-in MCP support). Self-hosted SearXNG is preferred for a private, local setup; a hosted API (Brave, Exa, Tavily) is the alternative. Then inventory any other tools gigs need.

### 3. Code-enforced confirmation for push, open, merge and discard

`deck-open`, `deck-land` and `deck-teardown --discard` should require the user's explicit confirmation in code, so a weaker local model can't take these actions on its own. Today they rely on the operator following AGENTS.md §2.

### 4. `local` profile

A config profile with:

- `deck_harness=pi`, `worker_harness=pi`
- Pi model = the tempo Ollama model
- the web tools from step 2 enabled
- `deck-doctor` checks tempo is reachable before launch and says so plainly when it isn't

Per-job `--harness claude` stays available for hard gigs.

### 5. Later: multiplexer adapter, then Rex

Put every Herdr call in `deck-lib.sh` behind `mux_*` functions, then add a Rex adapter once Rex leaves beta.

## Facts and constraints

| | |
| --- | --- |
| MacBook | Apple M5, 32 GB |
| `tempo` | Mac mini, M4 Pro, 64 GB, on the user's tailnet. The model server; also runs its own deck session |
| Concurrency | Expect about 2–3 concurrent workers per loaded model on tempo, not Claude-level parallelism |

- **Pi has no approval prompts and no write sandbox.** The operator write guard covers write/edit tools and shell redirects/`tee`. It does not catch `cp`, `mv`, `sed -i`, scripts, or `git commit` inside a project.
- **Connectors don't carry over.** Pi doesn't get Claude's claude.ai MCP connectors (Linear, Jira, Gmail, ...); each needs its own setup in Pi. Until then, connector-heavy gigs use Claude workers.
- Fuller analyses live in the MacBook's private job reports (`deck-pi-rex-plan`, `firstmate-gap-review`). Everything needed to act is summarised here.

## Open decisions

- Which models to standardise on (after the trial).
- SearXNG or a hosted search API.
- Whether to tighten the bash write guard: block any non-read-only bash command that mentions a protected path.
- Whether Pi workers get a tool_call guard that blocks writes outside their worktree and job dir (Pi workers have no approvals or sandbox).
- Which connectors are worth setting up in Pi.
- When to move to Rex.

## Picking this up on tempo

1. Pull the fork's `main`.
2. Run `bin/deck-test`.
3. Read this file.
4. Start with the first **Next** item whose prerequisite is met.

Projects, jobs and proposals are per-machine. Register projects with `bin/deck-project add` as needed.
