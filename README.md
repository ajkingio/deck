# fixer

**Talk to one agent. It hires the crew.**

fixer turns the coding agent you already use into the one agent you talk to: your deck, your Fixer, or your first mate, depending on the theme. You say what you want; it hires runner agents to do the work, each in its own git worktree and its own [Herdr](https://herdr.dev) workspace, supervises them, and comes back with finished PRs, merged branches, or investigation reports. It only interrupts you for real decisions, and nothing merges without your word.

It's a lightweight take on [firstmate](https://github.com/kunchenguid/firstmate): the same idea, cut down to a starting point you can read in an afternoon and make your own. It ships with two cyberpunk themes (netrunner by default, and fixer), a nautical one and a plain one, and you can write your own.

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
   Setup checks your machine and asks for a theme, what to call you, and which agent to use. It also offers Herdr's agent hooks, GitHub/GitLab logins, an `upstream` remote, fewer permission prompts, and folder trust for fixer and your projects. Last, it installs your launcher alias. Anything that touches files outside this folder is asked about first, and you can rerun it any time.
3. Open a new terminal and launch:
   ```sh
   jackin
   ```
   That opens a Herdr session named `fixer` in this folder and starts your agent with "jack in". If a `fixer` session already exists, it asks whether to open it or start a new one. Starting a new one replaces the old session, and it asks again first if runners are still live in it.

The alias comes from the theme, and `/retheme` updates it:

| Theme | You are | The agent is | Its crew | Launcher |
| --- | --- | --- | --- | --- |
| `cyberpunk-netrunner` (default) | the netrunner | your deck | daemons | `jackin` |
| `cyberpunk-fixer` | the client | your Fixer | mercs | `holocall` |
| `nautical` | the captain | the first mate | the crew | `ahoy` |
| `plain` | you | a coordinator | workers | `fixer` |

Then just ask:

```
> add rate limiting to the login endpoint in api, and figure out why the nightly export is slow

  Two daemons uploaded, runner. `api-rate-limit` is on the run; `api-export-scan` is tracing the export.
  ...
  Breach complete: PR's up, CI green. https://github.com/you/api/pull/42 (rate limiting, low risk).
  Scan's back: the export does one query per row. Upload a daemon to batch it?

> merge it, and yes
```

Each worker (a daemon, in this theme) shows up as its own Herdr workspace named after its job, so you can watch any of them or step in.

## Commands

| | |
| --- | --- |
| `/sitrep` | What needs you, what's running, what's queued, what landed |
| `/debrief` | Review what the Fixer wants to remember, and approve or reject each item |
| `/retheme` | Change the theme |
| `/ghost` | Quiet mode (Claude Code only): hide tool-call clutter, animate the working row, show the crew. Named by the theme; `/calm` works in every theme |

Codex uses `$sitrep` instead of `/sitrep`.

### Quiet mode

Quiet mode (Claude Code) turns the transcript into just the conversation. Each theme names its command, and `/calm` works in all of them:

| Theme | Command |
| --- | --- |
| cyberpunk-netrunner | `/ghost` |
| cyberpunk-fixer | `/lowkey` |
| nautical | `/calm` |
| plain | `/focus` |

With it on:

- Tool calls, their results, and the watcher's wake-ups are hidden. ctrl+o still shows everything, and the model's context isn't touched.
- The "working…" spinner becomes the theme's animation. Both cyberpunk themes use a hex stream with a glitch column sweeping across it.
- A band above the prompt lists live workers under the theme's name for them: `▌DAEMONS ▸ api-rate-limit ⟨running⟩ ▸ api-export-scan ⟨BLOCKED⟩`.
- A dim note lands in the transcript when a runner reports: `⚡ api-rate-limit: done · https://…`. Only you see it; the model doesn't.

The choice is saved as `calm=on|off` in `config/fixer.conf`. Quiet mode is a Claude Code mod (`.claude/mods/fixer-calm`) built on Claude Code's early-access mod API, so it can break when Claude Code updates. A custom theme sets its command with `calm_command:`, its band title with `crew_label:`, and its animation with `calm: hex-stream` (anything else keeps the stock spinner).

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

- **Gigs** produce changes, delivered as a PR/MR (`pr` mode) or a local branch merged on your word (`local` mode).
- **Recon** produces a report and no code.
- **Hard rules:** the Fixer never edits your projects itself, never merges without your explicit word, and never throws away unlanded work.

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
| `AGENTS.md`, `bin/`, `templates/`, `themes/`, `.agents/skills/` | the tool | yes |
| `learned/`, new skills, custom themes | what your Fixer learned | yes, to your fork |
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
