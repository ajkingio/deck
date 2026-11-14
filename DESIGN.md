# deck — design

deck (formerly fixer) is a lightweight agent distro inspired by [firstmate](https://github.com/kunchenguid/firstmate).
Clone it, launch a supported agent inside Herdr, and that agent becomes your **Deck**: the one agent you talk to, which launches workers to do the work and reports back only outcomes and decisions.

Status: draft. Decisions below are agreed unless marked **open**.

## Goals

- **Clone and go.** No install step. `git clone`, start `herdr`, start your agent inside it, answer a few onboarding questions.
- **Lightweight.** The always-loaded contract (`AGENTS.md`) stays under ~1,500 words. Mechanics live in a handful of small scripts.
- **One persona.** The Deck, in `persona.md`. No theme system: a user who wants another voice edits that file.
- **Learns, with consent.** deck proposes what to remember and which skills to create; nothing is written without the user's approval.

## Non-goals (things firstmate has that deck deliberately drops)

Session backends other than Herdr, harnesses beyond the three below, secondmates/remote homes, quota-aware dispatch, Relay (X/Discord), voice, the no-mistakes pipeline, Gerrit/Forgejo/external forges, the zero-token watcher daemon.

## Roles

| Neutral term (AGENTS.md, scripts) | In chat (`persona.md`) |
| --- | --- |
| operator, the main agent | **the Deck** (the netrunner's cyberdeck onboard AI) |
| user | **netrunner** |
| worker | daemon |
| ship task (kind `gig`) | run |
| scout task (kind `recon`) | probe |
| worktree | sandbox |
| backlog | the queue |
| memory entry | engram |
| teardown | derez |

The neutral side is what AGENTS.md, the scripts and job records use: the kind values stay `gig` and `recon`, and subagents are "workers", so "runner" never collides with the netrunner. Only chat uses the theme names. The Claude Code mod that keeps the transcript quiet is **Ghost** (`/ghost`).

Themes were tried and removed (2026-11-10): a theme picker, four themes, per-theme launcher aliases, command names, band labels and animations added a lot of machinery for little value in a project meant to be minimal. One cyberpunk persona stayed.

Renamed from fixer to deck (2026-11-12): the Fixer became the Deck, the client the netrunner, mercs daemons, lowkey Ghost, `holocall` `jackin`, and `bin/fixer-*` `bin/deck-*`. Clones set up before the rename keep working until `bin/deck-migrate` moves their private state (see Setup and launch).

## Hard rules

1. **Strict delegation.** The operator never writes to a project. All project work — even trivial — goes to a worker in its own worktree. The operator reads projects and maintains only its own `data/`, `state/`, `config/`.
2. **No push, PR/MR, or merge without the user's explicit word.** Workers only commit locally; `deck-open` pushes and opens the PR/MR on approval, and merges always pin the reviewed head commit.
3. **Never tear down unlanded work.** `deck-teardown` refuses if the branch has unpushed or unmerged commits or uncommitted changes.
4. **Workers never address the user.** Everything flows through the operator.
5. **Report outcomes faithfully.** Failures are stated plainly with evidence.

## Supported environment

- **Session backend: Herdr ≥ 0.9** (only). The operator must itself run inside a Herdr pane (`HERDR_ENV=1`) so workers appear in the same session the user watches. `deck-spawn` refuses otherwise.
- **Harnesses: Claude Code, Codex, Grok, Pi**, each usable as the operator and as a worker. Worker harness is chosen per job, defaulting to `worker_harness` in `config/deck.conf`, defaulting to the operator's own harness.
- **Usage:** fork the repo, clone the fork, run `herdr` in it, run the agent inside Herdr.
- **Forges: GitHub (`gh`) and GitLab (`glab`)**, including self-hosted GitLab.
- **Other:** `git`, `jq`.

## Repository layout

```
AGENTS.md              the contract (neutral terms)
persona.md             the Deck's voice, chat only
CLAUDE.md              @AGENTS.md   (Codex and Grok read AGENTS.md natively)
DESIGN.md              this file
.agents/skills/        shared skills; .claude/skills -> ../.agents/skills
.claude/settings.json  registers the Stop hook (deck-turnend-guard)
.pi/extensions/        deck-operator.ts: the Pi operator's watcher, settle backstop and write guard
.pi/prompts/           /scan and /defrag for Pi (they point at the skills)
templates/             gig-brief.md, recon-brief.md, worker-system.md
bin/
  deck-doctor          dependency + environment check
  deck-spawn           worktree + agent start + brief + job record
  deck-wait            block until any worker changes state or appends a status line
  deck-turnend-guard   Claude Code Stop hook: blocks turn end while jobs are live and no deck-wait runs
  deck-sitrep          snapshot of every job
  deck-forge           gh/glab adapter (see Forges); refuses `open` from a worker
  deck-open            push + open the PR/MR, only on the user's word
  deck-teardown        close workspace + remove worktree, refuses on unlanded work
  deck-herdr-move      send Herdr's API-only workspace.move (used by deck-spawn)
  deck-migrate         one-time move of a pre-rename clone's private state (run by the user)
# gitignored, private to the user:
config/                deck.conf: user name, harnesses, delivery default, ghost
data/                  jobs.md, projects.md, profile.md, engrams/, proposals.md, reports/<id>.md
projects/              read-only clones
state/                 <job-id>.status append-only event lines
```

## Job lifecycle

1. **Intake.** User asks; the operator resolves the project, classifies as gig (ship) or recon (scout), files it on the backlog.
2. **Brief.** The operator fills a template with the user's intent, scope limits, delivery mode, and the engrams tagged for that project (this is how learning reaches workers, which load the project's instructions, not deck's).
3. **Spawn.** `deck-spawn`:
   `git worktree add -b deck/<id> ~/.deck/worktrees/<home>/<id>` →
   `herdr workspace create --cwd <worktree> --label "└ <id>" --env DECK_JOB=<id> ...` →
   `deck-herdr-move <ws> <index>` (best-effort) →
   `herdr agent start <id> --kind <harness> --pane <root-pane> -- <autonomy flags>` →
   `herdr agent prompt <id> "read your brief at ..."`.
   We don't use `herdr worktree create`: it also opens a workspace for the main repo when none exists, which teardown would then have to account for. With plain git plus `workspace create`, each job owns exactly one workspace.
   Herdr has no nested workspaces, so worker workspaces are grouped visually instead: each is labelled `└ <id>` and moved to the end of the block of `└ ` workspaces right after the operator's own, newest last. The operator's workspace is resolved live from `HERDR_PANE_ID` (`herdr pane get`), never by its label, since labels aren't unique. `workspace.move` has no CLI, so `bin/deck-herdr-move` sends that one request over `HERDR_SOCKET_PATH`. A failed move only warns. The Herdr agent name stays the bare `<id>`, so every `herdr agent …` call is unaffected; teardown accepts both `└ <id>` and the older plain `<id>` label.
   Worktrees live outside the deck repo because Claude Code loads `CLAUDE.md` from parent directories, so a worktree inside deck would make the worker act as an operator.
4. **Report.** The worker appends one line to `state/<id>.status`: `done <url|sha>`, `blocked <question>`, or `failed <reason>`. Recon also writes `data/reports/<id>.md`. Herdr's own `blocked` state catches approval dialogs the worker can't report itself.
5. **Relay.** The operator tells the user the outcome or decision, optionally with `herdr notification show`.
6. **Land.** On the user's word: `deck-forge merge` (pr mode) or a local fast-forward merge (local mode).
7. **Teardown.** `deck-teardown` only after work has landed.

Delivery modes per project: `pr` (worker commits; user reviews, says "open it" for `deck-open`, then merges or says "merge it") and `local` (merge branch locally on approval).

## Forges

`bin/deck-forge` is the single place that knows gh vs glab. Workers call it by absolute path (passed in the brief), so briefs are forge-agnostic.

**Detection**, in order:
1. Explicit `DECK_FORGE=github|gitlab` environment override.
2. The project's `forge=` in `data/projects/<name>.conf`, passed via `DECK_FORGE` by job callers (`deck-open`, `deck-land`, `deck-teardown`, and `deck-sitrep --forge`).
3. Remote host `github.com` → github, `gitlab.com` → gitlab.
4. Otherwise, authenticated `glab auth status --hostname <host>` → gitlab, then authenticated `gh auth status --hostname <host>` → github.
5. If still unknown, fail and request `DECK_FORGE=github|gitlab`.

Registration uses host detection when `--forge` is omitted. `detect` does not require authentication for a known forge. Other verbs check the selected CLI's authentication for the remote host before any push or forge operation; failures name the CLI, host, and login command.

**Verbs:**

| Verb | GitHub | GitLab |
| --- | --- | --- |
| `open` | `git push -u` then `gh pr create --title --body-file --base` | `glab mr create --title --description-file --target-branch --push --yes` |
| `status` | `gh pr view --json state,mergeable,statusCheckRollup,reviewDecision,headRefOid` | `glab mr view -F json` + `glab ci status` |
| `merge <sha>` | `gh pr merge --match-head-commit <sha> --squash|--merge` | `glab mr merge --sha <sha> --auto-merge=false --yes` |
| `url` | `gh pr view --json url` | `glab mr view -F json` → `web_url` |

Gotchas baked into the adapter:
- `glab mr merge` defaults `--auto-merge` to **true**, which would schedule a merge rather than merge now. Always pass `--auto-merge=false`.
- `glab mr create --fill` pushes implicitly; the adapter pushes explicitly instead so push failures surface on their own.
- Merge method follows the project's setting unless `data/projects.md` overrides it.

`deck-doctor` checks the CLI for each registered project's forge is installed and authenticated for that host.

## Supervision per harness

- **Claude Code:** `deck-wait` runs as a background command; Claude is re-invoked when it exits. First-class. `deck-turnend-guard`, a Stop hook, backs this up: it blocks a turn from ending while jobs are `running`/`blocked` and `state/wait.pid` names no live deck-wait. It allows when `stop_hook_active` is set, after 3 blocks in 10 minutes, on any error, and in linked worktrees or homes without `data/jobs`, so it is inert for workers on deck itself.
- **Grok:** background notification around `deck-wait`, same shape. Needs verification on a machine with Grok installed.
- **Pi:** no background shell command, so the project extension `.pi/extensions/deck-operator.ts` owns the watcher. In the operator's home (same scope rule as `deck-turnend-guard`) it runs `bin/deck-wait` as a child process whenever jobs are `running`/`blocked`, checked at session start, when a turn settles and after each exit; delivers the events as a follow-up user message; and restarts it. An "already watching" exit is retried every 30s; other failures back off. `agent_before_settle` is the backstop: it starts a watcher if none is alive. Pi never asks before a tool runs, so the extension also enforces hard rule 1 with a `tool_call` gate: `write`/`edit`, and bash output redirections and `tee`, are blocked under `projects/`, registered project paths, job worktrees and the deck repo, except the deck repo's `config/`, `data/`, `state/`, `learned/` and `.agents/skills/` (the last two for accepted `/defrag` proposals). Other bash writes are not caught. It loads only when Pi trusts the deck folder (`deck-trust --path <deck> --grant --harness pi` writes `~/.pi/agent/trust.json`). `deck-allow` is a no-op on Pi.
- **Codex:** no background re-invocation. v1 uses bounded foreground waits when the user is idle; the user can't chat during a wait. A Stop-hook integration is a later improvement.

## Skills (v1)

- **onboarding** — the first session after `./setup`: a short tour and the first project.
- **/scan** — what changed, what's running, what needs the user (merges firstmate's `/ahoy` and `/bearings`).
- **/defrag** — run the learning loop on demand.

## Learning loop (propose and approve)

**Signals:** user corrections and rejections during a job; a mandatory *friction* section in every worker's final report; repeated job shapes.

**Proposal kinds** (queued in `data/proposals.md`):
- `profile` — how the user likes to work → `data/profile.md`
- `engram` — a fact, tagged by project or global → `data/engrams/<slug>.md`
- `skill` — a new skill after a pattern recurs ~3 times → `.agents/skills/<name>/`
- `brief-patch` — an improvement to a worker brief template

**Rules:** proposals surface only at natural pauses (after a job lands, or in `/scan`), never mid-flow. The user accepts, edits, or rejects each. Rejections are recorded so the same proposal doesn't come back. Memory has a word budget; `/defrag` also proposes pruning stale or contradicted entries.

## Worker launch

| Harness | Flags | Startup dialogs |
| --- | --- | --- |
| Claude | `--permission-mode auto --add-dir <jobdir> --append-system-prompt-file templates/worker-system.md -n <id>` | Folder trust: granted on the user's word (`deck-trust --grant`), or answered by them via `deck-trust` |
| Codex | `-a never --disable hooks -c default_permissions="deck_worker" -c permissions.deck_worker={extends=":workspace", network={enabled=true}, filesystem={<jobdir>, <git common dir>, <worktree git dir> = "write"}}`. A permissions profile, not `-s workspace-write --add-dir`: Codex keeps a worktree's gitdir read-only even as an extra writable root, so commits and fetches failed. Codex ignores the profile if `sandbox_mode` is set in its config. | Folder trust: granted on the user's word (`deck-trust --grant`), or answered by them via `deck-trust` |
| Grok | `--always-approve` | Folder trust: answered by the user via `deck-trust` (unverified) |
| Pi | `--append-system-prompt templates/worker-system.md --name <id> --approve`, plus `--model <pi_worker_model>` and `--thinking <pi_worker_thinking>` when those are set in `config/deck.conf`. Each flag is checked against `pi --help` before the worktree is made. Pi has no approvals and no sandbox. | Pi keys trust by path (closest saved decision wins), so the main checkout's trust doesn't reach `~/.deck/worktrees`. `--approve` trusts project-local files for that run only, without writing `trust.json`, and is passed only when `harness_trusts pi` says the main checkout is trusted; otherwise spawn refuses with the `deck-trust --grant --harness pi` hint. On the deck project, the worker's `--approve` loads `.pi/extensions/deck-operator.ts`, which stays inert in a linked worktree. |

**Folder trust.** Verified on Claude Code 2.1.322: trust does *not* carry over to subfolders (a new worktree under the trusted `~/workspace` still showed the dialog), but it *is* keyed on the main repository (a worktree of a trusted repo, outside any trusted folder, opened with no dialog). Codex records trust for the repository root too. So each project is trusted once, for its main checkout, in one of two ways. `deck-trust <project> --grant` writes the harness's own trust record: `projects[path].hasTrustDialogAccepted = true` in `${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json` (jq, temp file and rename, checked that no other key changed), or an appended `[projects."<path>"] trust_level = "trusted"` table in `${CODEX_HOME:-~/.codex}/config.toml`. It backs the file up to `<file>.deck-bak`, refuses anything but a registered project's main checkout, refuses when the harness already holds a different record for that path (such as `untrusted`), and reads the trust back with `harness_trusts`. It does not write Grok's store yet. Plain `deck-trust <project>` opens the agent in the checkout so the user answers the real dialog instead.

deck edits harness trust config only on the user's explicit word, per project: `--grant` asks "Trust <project> (<path>) for <harness>? [y/N]" on the terminal, or takes `--yes` when the user runs it themselves (`!` in Claude Code), answers yes in `./setup`, or names that project to the operator in their current request. With no terminal and no `--yes` it refuses, and `deck-allow` never auto-allows it. deck never presses keys on a trust dialog; `deck-spawn` refuses a project that isn't trusted yet.

**Permissions.** `deck-allow`, run by the user with Claude Code's `!` prefix, adds allow rules for the routine scripts to the gitignored `.claude/settings.local.json`. `deck-land`, `deck-teardown`, `deck-project add` and `deck-trust` (including `--grant`) always ask.

## Verified (2026-11-10, Herdr 0.9.5)

- Claude Code 2.1.322 as worker, gig in local mode: spawn, the watcher waking on `done`, review, the land and teardown refusals, landing, teardown. No leftovers.
- Codex 0.167.0 as worker, recon: trust dialog, sandboxed `deck-report`, `blocked` answered via `deck-tell`, report, teardown.
- Not yet verified: `pr` mode against real GitHub/GitLab, Grok, Codex or Grok as the operator.

## Decisions

- deck is a project of itself (`deck`, local mode, registered by `./setup`). Changes to its tracked files are gigs, so the operator never does work directly, not even on its own code or contract; only private state and the exact text of accepted `/defrag` proposals are written directly. Local-mode spawns branch from the local base, not `origin/<base>`, because landing merges back into the local checkout.

- Learned skills and brief patches are committed to the user's fork. Upstream never edits `learned/`. Profile and engrams stay private in `data/`.

## Setup and launch

- **`./setup`** (run once after cloning, outside the agent): dependencies, user name, operator and worker harness, delivery default, Herdr agent hooks (`herdr integration install`), gh/glab logins, `upstream` remote (guessed from the fork's parent via gh), `deck-allow`, folder trust for the deck repo and any projects ("Trust <p> for <harness> now?" runs `deck-trust --grant`, with `deck-trust`'s foreground dialog as the fallback), then the launcher alias. Re-runnable; current values are the defaults. Writes `onboarded=no` so the first session runs the in-chat welcome. Refuses on a clone that still has the pre-rename `config/fixer.conf` and asks for `bin/deck-migrate` first.
- **Backward compatibility.** Until `bin/deck-migrate` runs, the scripts read `config/fixer.conf` when `config/deck.conf` is missing (with a one-line warning), read the old config keys `fixer_harness`, `runner_harness` and `lowkey` when the new ones are absent, accept the old engram audiences `runner` and `fixer` and the old `FIXER:FILL` markers, and `deck-forge` treats a worker's `FIXER_JOB` like `DECK_JOB`. Ghost reads the same fallback config and its `lowkey=` key. Existing jobs keep the branch, worktree and Herdr label recorded in their `job.conf`.
- **`bin/deck-migrate [--dry-run]`**, run by the user in a normal terminal, moves what lives outside the tracked files, each step printed and asked y/N, and safe to run again: `config/fixer.conf` → `config/deck.conf` with the old keys renamed (and the Herdr session `fixer` → `deck`); `state/last-debrief` → `state/last-defrag`; `~/.fixer/worktrees` → `~/.deck/worktrees`, refused while any worktree in it is still live; the project record `fixer` → `deck`, its path set to wherever the clone is; the Claude Code allow rules in `.claude/settings.local.json`; the `holocall` alias → `jackin`. It prints the `mv` for the repo folder (it can't move the folder it runs from), and after the move, run again from the new folder, it updates the paths, re-grants folder trust for claude and codex through `deck-trust --path <new> --grant`, offers to copy the Claude Code project memory folder to the new path's slug, and prints the `gh repo rename` / `git remote set-url` commands without running them.
- **Launcher:** the alias is `jackin` and the opening line "jacking in" (`DECK_ALIAS` / `DECK_GREETING` in `bin/deck-lib.sh`).
- **`bin/deck-launcher install|remove|show|status|conflicts`** writes the alias to `~/.zshrc`, `~/.bashrc`, or a fish `conf.d` file, fenced by markers naming this clone's path.
- **`bin/deck-launch`** (what the alias runs): if the Herdr session `deck` (config `herdr_session`) exists, ask open / new / cancel. New replaces it: live workers are listed and must be confirmed by typing `replace`, since stopping the session ends their panes (worktrees and job records survive). A fresh start runs a headless `herdr --session deck server`, creates one `deck` workspace at the repo, closes the server's default workspace, runs `<harness> "<greeting>"` in it, and attaches. A second session alongside was rejected: two operators on one backlog would both supervise and land.
- The operator is started with `herdr agent start deck --kind <harness> -- "<greeting>"`, not `pane run`: a command typed into a shell that is still running its startup files gets lost. The server's default workspace is closed only once its shell is idle, because killing a shell mid-startup can leave pyenv's rehash lock behind and stall every later shell. Verified 2026-11-10 (before the rename): fresh start in 5.5s, one workspace, the operator running.

## Ghost (Claude Code)

A mod at `.claude/mods/deck-ghost`, auto-loaded through `.agents/skills/deck-ghost` (a symlink, the same pattern firstmate uses). It does nothing unless `config/deck.conf` exists. On by default: only `ghost=off` turns it off.

| Hook | With ghost on |
| --- | --- |
| `ui.render` ToolUse / ToolResult / ToolGroup | drawn as nothing (passes through when `isExpanded`, i.e. ctrl+o) |
| `ui.render` UserMessage | the watcher's task-notification row (its description starts `deck-wait:`) drawn as nothing |
| `ui.render` Spinner | the `▌DAEMONS` row (when any worker is live) above the hex stream (`hooks/hexstream.ts`, a pure function of width and frame) |
| `ui.render` AbovePrompt | between turns (`!isWorking`): the `▌DAEMONS` row from `data/jobs/*/job.conf`, refined by `herdr agent list` (a worker at a dialog shows `DIALOG`), and under it, while a worker is working and the band isn't collapsed, the hex stream in a dimmer teal sized to `bodyColumns`. During a turn it draws nothing: the Spinner carries the row |
| `turn.step` + `ui.render` AssistantMessage | short mid-turn narration drawn as nothing (`hooks/narration.ts`) |
| `$.session.append` system notice | one dim note per new `status.log` line; display-only, the model never reads it |
| `/ghost` | toggles `ghost=` in `config/deck.conf`, confirms with a toast |

Polls job files every 3s. The status items always sit above the animation: in a turn the Spinner draws the DAEMONS row and then the stream, and the band stays empty so the row never shows twice; between turns the band draws the row and then the stream. (The engine draws the Spinner above the band, so the row moves into the Spinner rather than the band drawing above it.) Worker reports are transcript notices, so they're above both already.

A worker is *working* when its job status is `starting`/`running` and Herdr doesn't see its pane `blocked`, `idle` or `done`; without Herdr the job status alone decides. Blocked, dialog, review/reported and failed workers stay in the band but don't animate it. The 120ms frame timer runs while ghost is on and a turn is running or a worker is working, and stops otherwise. It is re-checked on turn start/complete/abort, after each poll (so it stops at most 3s after the last worker reports), and on `/ghost`. The frame counter is never reset, so the stream resumes where it stopped. Seen status-log counts are kept in `$.store` so a restart doesn't replay old events.

Narration hiding follows firstmate's Calm. A `turn.step` hook watches each main-agent step's text blocks without changing the stream. Text from a step that stopped for tools (`stopReason` `tool_use`, or `max_tokens` with tool calls) is a working note unless it has a newline or is 240+ characters trimmed. Matching `AssistantMessage` rows draw as nothing. Text that was ever a final reply stays visible, and a restored transcript is classified the same way at session start from `$.session.messages()`. It is display-only: the model's context is unchanged. The 2.1.322 `AssistantMessage` props carry no `isExpanded`, so the hook passes when one is sent, but ctrl+o may not reveal hidden notes on this build. A note can show briefly while it streams, before its step ends and the redraw hides it.

Before the rename it was called lowkey (`/lowkey`, `lowkey=`, the `▌MERCS` band); a config without `ghost=` falls back to `lowkey=`, and one without `config/deck.conf` to `config/fixer.conf`, which `/ghost` then writes.

Verified: `claude plugin validate`, `tsc` against the 2.1.322 types, and `claude plugin test` (20 tests). Not yet seen live in a session.

## Open questions

- Whether Claude Code asks the user before auto-loading a project's mod, or needs a flag, on current builds. Check during the first live onboarding.
