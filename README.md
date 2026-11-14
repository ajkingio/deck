# deck

**Jack in. Talk to one agent. It runs the daemons.**

deck turns the coding agent you already use into your **Deck**: the onboard AI of your cyberdeck, and the one agent you talk to. You're the netrunner. You say what you want; the Deck launches daemons (worker agents) to do the work, each in its own git worktree and its own [Herdr](https://herdr.dev) workspace, watches them, and comes back with finished PRs, merged branches, or investigation reports. It only interrupts you for real decisions, and nothing merges without your word.

It's a lightweight take on [firstmate](https://github.com/kunchenguid/firstmate): the same idea, cut down to a starting point you can read in an afternoon and make your own. The Deck's voice lives in `persona.md`; edit it if you want a different one. deck was called **fixer** until 2026-11-12; if your clone predates that, see [Coming from fixer](#coming-from-fixer).

There's nothing to install. The repo is the tool: an `AGENTS.md` contract, a few skills, and a handful of small shell scripts.

## Requirements

- [Herdr](https://herdr.dev) 0.9 or newer
- One of: [Claude Code](https://claude.com/claude-code), [Codex](https://github.com/openai/codex), Grok, Pi
- `git` and `jq`
- For PRs: `gh` (GitHub) and/or `glab` (GitLab, including self-hosted), logged in

## Quick start

1. **Fork** this repo on GitHub (deck commits what it learns to your fork).
2. Clone your fork and run setup in a normal terminal:
   ```sh
   git clone https://github.com/<you>/deck
   cd deck
   ./setup
   ```
   Setup checks your machine and asks what to call you and which agent to use. It also offers Herdr's agent hooks, GitHub/GitLab logins, an `upstream` remote, fewer permission prompts, and folder trust for deck and your projects. Last, it installs the `jackin` alias. Anything that touches files outside this folder is asked about first, and you can rerun it any time.
3. Launch:
   ```sh
   jackin
   ```
   That opens a Herdr session named `deck` in this folder and starts your agent with "jacking in". If a `deck` session already exists, it asks whether to open it or start a new one. Starting a new one replaces the old session, and it asks again first if daemons are still live in it.

Then just ask:

```
> add rate limiting to the login endpoint in api, and figure out why the nightly export is slow

  Two jobs in the queue, netrunner. Daemon `api-rate-limit` is on the run; `api-export-probe` is digging into the export.
  ...
  Preem. PR's up and CI is green: https://github.com/you/api/pull/42 (rate limiting, low risk).
  Probe's back: the export does one query per row. Want a run to batch it?

> merge it, and yes
```

Each daemon shows up as its own Herdr workspace, labelled `└ <job>` and grouped right under the Deck's, so you can watch any of them or step in.

## Commands

| | |
| --- | --- |
| `/scan` | What needs you, what's running, what's queued, what landed |
| `/defrag` | Review what the Deck wants to remember, and approve or reject each item |
| `/ghost` | Claude Code only, on by default: hide tool-call clutter and show the daemons. Toggles |

Codex uses `$scan` instead of `/scan`.

### Ghost

With `/ghost` on (Claude Code), the transcript is just the conversation:

- Tool calls, their results, and the watcher's wake-ups are hidden. ctrl+o still shows everything, and the model's context isn't touched.
- The "working…" spinner becomes a hex stream: two rows of drifting teal hex with a yellow glitch column sweeping across.
- A band above the prompt lists live daemons: `▌DAEMONS ▸ api-rate-limit ⟨running⟩ ▸ api-export-probe ⟨BLOCKED⟩`.
- A dim note lands in the transcript when a daemon reports: `⚡ api-rate-limit: done · https://…`. Only you see it; the model doesn't.

It's saved as `ghost=on|off` in `config/deck.conf`. Ghost is a Claude Code mod (`.claude/mods/deck-ghost`) built on Claude Code's early-access mod API, so it can break when Claude Code updates.

## Glossary

The Deck talks in theme names; `AGENTS.md`, the scripts and the job records use the plain ones.

| Theme name | Neutral term | What it is and where it lives |
| --- | --- | --- |
| deck (the project) | — | This repo, formerly fixer. Scripts are `bin/deck-*`, sharing `bin/deck-lib.sh` |
| the Deck | operator | The one agent you talk to, running in this repo inside the Herdr session `deck`. Contract in `AGENTS.md`, voice in `persona.md` |
| netrunner | user | You. The Deck calls you by `client_name` in `config/deck.conf` |
| daemon | worker | An agent the Deck launches for one job, in its own worktree and Herdr workspace `└ <id>`. Started by `bin/deck-spawn`, reports through `bin/deck-report`, standing prompt in `templates/worker-system.md` |
| run | job of kind `gig` | A job that ships a change, as a PR/MR or a local merge. Brief from `templates/gig-brief.md` |
| probe | job of kind `recon` | A job that only writes a report. Brief from `templates/recon-brief.md` |
| the queue | backlog, job records | Every job in `data/jobs/<id>/` (`job.conf`, `brief.md`, `status.log`, `report.md`). Listed by `bin/deck-job list` and `bin/deck-sitrep` |
| sandbox | worktree | A daemon's own checkout, under `~/.deck/worktrees/`, on branch `deck/<id>` |
| derez | teardown | Closing a finished job's workspace and worktree: `bin/deck-teardown`, which refuses unlanded work |
| engram | memory entry | A fact the Deck keeps, in `data/engrams/<slug>.md` (private); `audience: worker` ones are pasted into briefs |
| scan | status report | `/scan`, the `scan` skill in `.agents/skills/scan/`, built on `bin/deck-sitrep` |
| defrag | learning review | `/defrag`, the `defrag` skill in `.agents/skills/defrag/`: proposals in `data/proposals.md` |
| ghost | quiet transcript mode | `/ghost`, the Claude Code mod in `.claude/mods/deck-ghost`; setting `ghost=` in `config/deck.conf` |
| `▌DAEMONS` | live-worker band | The row Ghost draws above the prompt from `data/jobs/*/job.conf` and Herdr |
| jack in | launch | The `jackin` alias, installed by `bin/deck-launcher`, runs `bin/deck-launch`, which opens each session with "jacking in" |

## How it works

```
 you ──chat──▶ Deck (your agent, in this repo, inside Herdr)
                 │  deck-job new → brief.md
                 │  deck-spawn   → git worktree + Herdr workspace + worker agent
                 │  deck-wait    → wakes the Deck when a worker reports or gets stuck
                 ▼
     worker A   worker B   worker C      each: own worktree, own workspace
        │          │          │
        └─ deck-report done/blocked/failed ─▶ Deck ─▶ you
```

- **Runs** (kind `gig`) produce changes, delivered as a PR/MR opened on your word after you review the commits (`pr` mode) or a local branch merged on your word (`local` mode).
- **Probes** (kind `recon`) produce a report and no code.
- **Hard rules:** the Deck never edits your projects itself, never pushes, opens a PR/MR, or merges without your word, and never throws away unlanded work. That includes deck itself: setup registers it as a local-mode project, so when you ask the Deck to change deck, a daemon does it on a branch for you to review.

## Learning

As you work, the Deck notices your corrections and what workers struggled with (every worker report has a *Friction* section). At natural pauses it proposes things to remember:

- **profile**: how you like to work (private)
- **engrams**: facts about your projects, passed to future workers (private)
- **brief patches**: standing instructions for every worker (committed to your fork)
- **skills**: reusable procedures, once a pattern has repeated (committed to your fork)

Nothing is saved without your yes, and rejected proposals aren't suggested again.

## What lives where

| Path | What | Committed? |
| --- | --- | --- |
| `AGENTS.md`, `persona.md`, `bin/`, `templates/`, `.agents/skills/` | the tool | yes |
| `learned/`, new skills | what your Deck learned | yes, to your fork |
| `config/`, `data/`, `state/`, `projects/` | your settings, jobs, memory, clones | no (gitignored) |
| `~/.deck/worktrees/` | worker worktrees | outside the repo |

## Worker permissions

Workers run unattended, so they launch with autonomy turned on, inside their own worktree:

- **Claude Code:** `--permission-mode auto` (set `claude_permission_mode` in `config/deck.conf` to change it).
- **Codex:** `--ask-for-approval never` with a workspace-write permissions profile that also lets it write the job folder and the worktree's git metadata, with network access, and Codex hooks turned off for workers.
- **Grok:** `--always-approve`.
- **Pi:** never asks before a tool runs and has no sandbox, so a Pi worker can write anywhere you can. It starts with `--approve` for its worktree (see folder trust below). It uses Pi's default model unless `config/deck.conf` sets `pi_worker_model` (passed as `--model`, e.g. `anthropic/claude-sonnet-5-5`) and `pi_worker_thinking` (passed as `--thinking`: `off`, `minimal`, `low`, `medium`, `high`, `xhigh` or `max`).

**Folder trust.** Each harness asks once whether you trust a repository, and a worker can't answer that. Claude Code, Codex and Grok key trust on the main checkout, so trusting a project once covers every worker worktree. Pi keys trust by path, so its trust doesn't reach worktrees; deck still trusts only the main checkout, and starts a Pi worker with `--approve` (trust for that run only, nothing written) when the checkout is trusted. Two ways to trust a project:

- `bin/deck-trust <project> --grant` writes the harness's own trust record for that project (Claude, Codex and Pi; it backs the file up first and never overrides a decision already recorded there). It asks "Trust <project> (<path>) for <harness>? [y/N]" for each one; `--all` walks every registered project that isn't trusted yet. To run it yourself from Claude Code, use `! bin/deck-trust <project> --grant --yes`.
- `bin/deck-trust <project>` opens your worker's agent in it, in a Herdr workspace named `trust-<project>`, and you answer the dialog yourself.

deck edits your harness's trust config only on your explicit word, per project: setup asks, or you name the project to the Deck. It never presses keys on a trust dialog.

**Fewer prompts for the Deck (Claude Code).** Onboarding offers `! bin/deck-allow`, which you run yourself. It lets the Deck run its routine scripts without asking, by writing the gitignored `.claude/settings.local.json`. Merging, teardown, cloning and trust always still ask. `bin/deck-allow --remove` undoes it.

## Coming from fixer

A clone set up before the rename keeps working: the scripts read `config/fixer.conf` (with a warning) until it's renamed, and Ghost reads the old `lowkey=` setting. To finish the move, from a normal terminal (not inside the Deck):

```sh
bin/deck-migrate --dry-run   # see every step first
bin/deck-migrate             # asks y/N before each one; safe to run again
```

It renames `config/fixer.conf` to `config/deck.conf` (and `lowkey=` to `ghost=`), moves `~/.fixer/worktrees` to `~/.deck/worktrees` once no worker worktrees are live there, renames the project record `fixer` to `deck`, updates the allow rules, and swaps the `holocall` alias for `jackin`. It then prints the `mv` for the repo folder itself; run that, `cd` into the new folder, and run `bin/deck-migrate` again to repoint the paths, re-grant folder trust, and copy Claude Code's project memory. It prints, but never runs, the commands to rename your GitHub fork.

## Staying up to date

```sh
git remote add upstream https://github.com/<upstream-owner>/deck
git pull upstream main
```

Upstream never edits `learned/`, so what your Deck learned won't conflict.

## Tests

`bin/deck-test` runs the behaviour tests in `tests/`: plain bash, no framework. They cover the safety refusals (teardown, land, open, spawn, trust) and the job → spawn → report → wait path.

```sh
bin/deck-test                                # everything
bin/deck-test land                           # one file: tests/land.test.sh
bin/deck-test land local_refuses_dirty_checkout   # one test
bin/deck-test --list                         # what's there
```

Each test runs in a throwaway sandbox (`tests/lib.sh`): a temp HOME, a temp deck home with copies of `bin/` and `templates/`, small git repos as projects, and stubs for `herdr`, `gh`, `glab` and `claude` that log their calls. It never touches your `~/.deck`, your Herdr session, your config or the network. A known bug is marked `xfail` until its fix lands; the run fails only on `FAIL`.

## Status

Early. Claude Code has been tested end to end with Herdr 0.9.5 (as fixer, before the rename). Codex and Grok follow the same design but haven't been tested yet; see `DESIGN.md`.

## License

MIT
