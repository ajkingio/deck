# fixer

**Talk to one agent. It hires the crew.**

fixer turns the coding agent you already use into your **Fixer**: the one agent you talk to. You're the client. You say what you want; the Fixer hires merc agents to do the work, each in its own git worktree and its own [Herdr](https://herdr.dev) workspace, supervises them, and comes back with finished PRs, merged branches, or investigation reports. It only interrupts you for real decisions, and nothing merges without your word.

It's a lightweight take on [firstmate](https://github.com/kunchenguid/firstmate): the same idea, cut down to a starting point you can read in an afternoon and make your own. The Fixer's voice lives in `persona.md`; edit it if you want a different one.

There's nothing to install. The repo is the tool: an `AGENTS.md` contract, a few skills, and a handful of small shell scripts.

## Requirements

- [Herdr](https://herdr.dev) 0.9 or newer
- One of: [Claude Code](https://claude.com/claude-code), [Codex](https://github.com/openai/codex), Grok
- `git` and `jq`
- For PRs: `gh` (GitHub) and/or `glab` (GitLab, including self-hosted), logged in

## Quick start

1. **Fork** this repo on GitHub (fixer commits what it learns to your fork).
2. Clone your fork and run setup in a normal terminal:
   ```sh
   git clone https://github.com/<you>/fixer
   cd fixer
   ./setup
   ```
   Setup checks your machine and asks what to call you and which agent to use. It also offers Herdr's agent hooks, GitHub/GitLab logins, an `upstream` remote, fewer permission prompts, and folder trust for fixer and your projects. Last, it installs the `holocall` alias. Anything that touches files outside this folder is asked about first, and you can rerun it any time.
3. Launch:
   ```sh
   holocall
   ```
   That opens a Herdr session named `fixer` in this folder and starts your agent with "got a job for you". If a `fixer` session already exists, it asks whether to open it or start a new one. Starting a new one replaces the old session, and it asks again first if mercs are still live in it.

Then just ask:

```
> add rate limiting to the login endpoint in api, and figure out why the nightly export is slow

  Two jobs posted, client. Merc `api-rate-limit` is on the gig; `api-export-recon` is digging into the export.
  ...
  Preem. PR's up and CI is green: https://github.com/you/api/pull/42 (rate limiting, low risk).
  Recon's back: the export does one query per row. Want a gig to batch it?

> merge it, and yes
```

Each merc shows up as its own Herdr workspace named after its job, so you can watch any of them or step in.

## Commands

| | |
| --- | --- |
| `/sitrep` | What needs you, what's running, what's queued, what landed |
| `/debrief` | Review what the Fixer wants to remember, and approve or reject each item |
| `/lowkey` | Claude Code only, on by default: hide tool-call clutter and show the mercs. Toggles |

Codex uses `$sitrep` instead of `/sitrep`.

### Lowkey

With `/lowkey` on (Claude Code), the transcript is just the conversation:

- Tool calls, their results, and the watcher's wake-ups are hidden. ctrl+o still shows everything, and the model's context isn't touched.
- The "working…" spinner becomes a hex stream: two rows of drifting hex with a neon-green glitch column sweeping across.
- A band above the prompt lists live mercs: `▌MERCS ▸ api-rate-limit ⟨running⟩ ▸ api-export-recon ⟨BLOCKED⟩`.
- A dim note lands in the transcript when a merc reports: `⚡ api-rate-limit: done · https://…`. Only you see it; the model doesn't.

It's saved as `lowkey=on|off` in `config/fixer.conf`. Lowkey is a Claude Code mod (`.claude/mods/fixer-lowkey`) built on Claude Code's early-access mod API, so it can break when Claude Code updates.

## How it works

```
 you ──chat──▶ Fixer (your agent, in this repo, inside Herdr)
                 │  fixer-job new → brief.md
                 │  fixer-spawn   → git worktree + Herdr workspace + runner agent
                 │  fixer-wait    → wakes the Fixer when a runner reports or gets stuck
                 ▼
     runner A   runner B   runner C      each: own worktree, own workspace
        │          │          │
        └─ fixer-report done/blocked/failed ─▶ Fixer ─▶ you
```

- **Gigs** produce changes, delivered as a PR/MR opened on your word after you review the commits (`pr` mode) or a local branch merged on your word (`local` mode).
- **Recon** produces a report and no code.
- **Hard rules:** the Fixer never edits your projects itself, never pushes, opens a PR/MR, or merges without your explicit word, and never throws away unlanded work.

## Learning

As you work, the Fixer notices your corrections and what runners struggled with (every runner report has a *Friction* section). At natural pauses it proposes things to remember:

- **profile**: how you like to work (private)
- **engrams**: facts about your projects, passed to future runners (private)
- **brief patches**: standing instructions for every runner (committed to your fork)
- **skills**: reusable procedures, once a pattern has repeated (committed to your fork)

Nothing is saved without your yes, and rejected proposals aren't suggested again.

## What lives where

| Path | What | Committed? |
| --- | --- | --- |
| `AGENTS.md`, `persona.md`, `bin/`, `templates/`, `.agents/skills/` | the tool | yes |
| `learned/`, new skills | what your Fixer learned | yes, to your fork |
| `config/`, `data/`, `state/`, `projects/` | your settings, jobs, memory, clones | no (gitignored) |
| `~/.fixer/worktrees/` | runner worktrees | outside the repo |

## Runner permissions

Runners work unattended, so they launch with autonomy turned on, inside their own worktree:

- **Claude Code:** `--permission-mode auto` (set `claude_permission_mode` in `config/fixer.conf` to change it).
- **Codex:** `--sandbox workspace-write --ask-for-approval never` with network access, and Codex hooks turned off for runners.
- **Grok:** `--always-approve`.

**Folder trust.** Each harness asks once whether you trust a repository, and a runner can't answer that. When you register a project, `bin/fixer-trust <project>` opens your runner's agent in it, in a Herdr workspace named `trust-<project>`, and you answer the dialog yourself. All three harnesses key trust on the main checkout, so that one answer covers every runner worktree. fixer never edits your harness config to skip the dialog.

**Fewer prompts for the Fixer (Claude Code).** Onboarding offers `! bin/fixer-allow`, which you run yourself. It lets the Fixer run its routine scripts without asking, by writing the gitignored `.claude/settings.local.json`. Merging, teardown, cloning and trust always still ask. `bin/fixer-allow --remove` undoes it.

## Staying up to date

```sh
git remote add upstream https://github.com/<upstream-owner>/fixer
git pull upstream main
```

Upstream never edits `learned/`, so what your Fixer learned won't conflict.

## Status

Early. Claude Code has been tested end to end with Herdr 0.9.5. Codex and Grok follow the same design but haven't been tested yet; see `DESIGN.md`.

## License

MIT
