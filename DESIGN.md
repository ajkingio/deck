# fixer — design

fixer is a lightweight agent distro inspired by [firstmate](https://github.com/kunchenguid/firstmate).
Clone it, launch a supported agent inside Herdr, and that agent becomes your **Fixer**: the one agent you talk to, which hires runners to do the work and reports back only outcomes and decisions.

Status: draft. Decisions below are agreed unless marked **open**.

## Goals

- **Clone and go.** No install step. `git clone`, start `herdr`, start your agent inside it, answer a few onboarding questions.
- **Lightweight.** The always-loaded contract (`AGENTS.md`) stays under ~1,500 words. Mechanics live in a handful of small scripts.
- **One persona.** The Fixer, in `persona.md`. No theme system: a client who wants another voice edits that file.
- **Learns, with consent.** fixer proposes what to remember and which skills to create; nothing is written without the user's approval.

## Non-goals (things firstmate has that fixer deliberately drops)

Session backends other than Herdr, harnesses beyond the three below, secondmates/remote homes, quota-aware dispatch, Relay (X/Discord), voice, the no-mistakes pipeline, Gerrit/Forgejo/external forges, the zero-token watcher daemon.

## Roles

| Neutral term (AGENTS.md, scripts) | In chat (`persona.md`) |
| --- | --- |
| operator, the main agent | **the Fixer** |
| user | **client** |
| worker (runner) | merc |
| ship task | gig |
| scout task | recon |
| worktree | safehouse |
| backlog | job board |
| memory entry | engram |

Themes were tried and removed (2026-11-10): a theme picker, four themes, per-theme launcher aliases, command names, band labels and animations added a lot of machinery for little value in a project meant to be minimal. The cyberpunk fixer persona stayed.

## Hard rules

1. **Strict delegation.** The Fixer never writes to a project. All project work — even trivial — goes to a runner in its own worktree. The Fixer reads projects and maintains only its own `data/`, `state/`, `config/`.
2. **No push, PR/MR, or merge without the client's explicit word.** Runners only commit locally; `fixer-open` pushes and opens the PR/MR on approval, and merges always pin the reviewed head commit.
3. **Never tear down unlanded work.** `fixer-teardown` refuses if the branch has unpushed or unmerged commits or uncommitted changes.
4. **Runners never address the client.** Everything flows through the Fixer.
5. **Report outcomes faithfully.** Failures are stated plainly with evidence.

## Supported environment

- **Session backend: Herdr ≥ 0.9** (only). The Fixer must itself run inside a Herdr pane (`HERDR_ENV=1`) so runners appear in the same session the client watches. `fixer-spawn` refuses otherwise.
- **Harnesses: Claude Code, Codex, Grok**, each usable as the Fixer and as a runner. Runner harness is chosen per job, defaulting to `runner_harness` in `config/fixer.conf`, defaulting to the Fixer's own harness.
- **Usage:** fork the repo, clone the fork, run `herdr` in it, run the agent inside Herdr.
- **Forges: GitHub (`gh`) and GitLab (`glab`)**, including self-hosted GitLab.
- **Other:** `git`, `jq`.

## Repository layout

```
AGENTS.md              the contract (neutral terms)
persona.md             the Fixer's voice, chat only
CLAUDE.md              @AGENTS.md   (Codex and Grok read AGENTS.md natively)
DESIGN.md              this file
.agents/skills/        shared skills; .claude/skills -> ../.agents/skills
templates/             gig-brief.md, recon-brief.md
bin/
  fixer-doctor         dependency + environment check
  fixer-spawn          worktree + agent start + brief + job record
  fixer-wait           block until any runner changes state or appends a status line
  fixer-sitrep         snapshot of every job
  fixer-forge          gh/glab adapter (see Forges); refuses `open` from a runner
  fixer-open           push + open the PR/MR, only on the client's word
  fixer-teardown       close workspace + remove worktree, refuses on unlanded work
  fixer-herdr-move     send Herdr's API-only workspace.move (used by fixer-spawn)
# gitignored, private to the client:
config/                client-name, harnesses, delivery default, lowkey
data/                  jobs.md, projects.md, profile.md, engrams/, proposals.md, reports/<id>.md
projects/              read-only clones
state/                 <job-id>.status append-only event lines
```

## Job lifecycle

1. **Intake.** Client asks; Fixer resolves the project, classifies as gig (ship) or recon (scout), files it on the job board.
2. **Brief.** Fixer fills a template with the client's intent, scope limits, delivery mode, and the engrams tagged for that project (this is how learning reaches runners, which load the project's instructions, not fixer's).
3. **Spawn.** `fixer-spawn`:
   `git worktree add -b fixer/<id> ~/.fixer/worktrees/<home>/<id>` →
   `herdr workspace create --cwd <worktree> --label "└ <id>" --env FIXER_JOB=<id> ...` →
   `fixer-herdr-move <ws> <index>` (best-effort) →
   `herdr agent start <id> --kind <harness> --pane <root-pane> -- <autonomy flags>` →
   `herdr agent prompt <id> "read your brief at ..."`.
   We don't use `herdr worktree create`: it also opens a workspace for the main repo when none exists, which teardown would then have to account for. With plain git plus `workspace create`, each job owns exactly one workspace.
   Herdr has no nested workspaces, so runner workspaces are grouped visually instead: each is labelled `└ <id>` and moved to the end of the block of `└ ` workspaces right after the Fixer's own, newest last. The Fixer's workspace is resolved live from `HERDR_PANE_ID` (`herdr pane get`), never by its label, since labels aren't unique. `workspace.move` has no CLI, so `bin/fixer-herdr-move` sends that one request over `HERDR_SOCKET_PATH`. A failed move only warns. The Herdr agent name stays the bare `<id>`, so every `herdr agent …` call is unaffected; teardown accepts both `└ <id>` and the older plain `<id>` label.
   Worktrees live outside the fixer repo because Claude Code loads `CLAUDE.md` from parent directories, so a worktree inside fixer would make the runner act as a Fixer.
4. **Report.** The runner appends one line to `state/<id>.status`: `done <url|sha>`, `blocked <question>`, or `failed <reason>`. Recon also writes `data/reports/<id>.md`. Herdr's own `blocked` state catches approval dialogs the runner can't report itself.
5. **Relay.** Fixer tells the client the outcome or decision, optionally with `herdr notification show`.
6. **Land.** On the client's word: `fixer-forge merge` (pr mode) or a local fast-forward merge (local mode).
7. **Teardown.** `fixer-teardown` only after work has landed.

Delivery modes per project: `pr` (runner commits; client reviews, says "open it" for `fixer-open`, then merges or says "merge it") and `local` (merge branch locally on approval).

## Forges

`bin/fixer-forge` is the single place that knows gh vs glab. Runners call it by absolute path (passed in the brief), so briefs are forge-agnostic.

**Detection**, per project, in order:
1. Explicit `forge=github|gitlab` in `data/projects.md`.
2. Remote host `github.com` → github.
3. Remote host `gitlab.com`, or any host `glab auth status` reports as authenticated → gitlab.
4. Otherwise: ask the client once and record it.

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

`fixer-doctor` checks the CLI for each registered project's forge is installed and authenticated for that host.

## Supervision per harness

- **Claude Code:** `fixer-wait` runs as a background command; Claude is re-invoked when it exits. First-class.
- **Grok:** background notification around `fixer-wait`, same shape. Needs verification on a machine with Grok installed.
- **Codex:** no background re-invocation. v1 uses bounded foreground waits when the client is idle; the client can't chat during a wait. A Stop-hook integration is a later improvement.

## Skills (v1)

- **onboarding** — the first session after `./setup`: a short tour and the first project.
- **/sitrep** — what changed, what's running, what needs the client (merges firstmate's `/ahoy` and `/bearings`).
- **/debrief** — run the learning loop on demand.

## Learning loop (propose and approve)

**Signals:** client corrections and rejections during a job; a mandatory *friction* section in every runner's final report; repeated job shapes.

**Proposal kinds** (queued in `data/proposals.md`):
- `profile` — how the client likes to work → `data/profile.md`
- `engram` — a fact, tagged by project or global → `data/engrams/<slug>.md`
- `skill` — a new skill after a pattern recurs ~3 times → `.agents/skills/<name>/`
- `brief-patch` — an improvement to a runner brief template

**Rules:** proposals surface only at natural pauses (after a job lands, or in `/sitrep`), never mid-flow. The client accepts, edits, or rejects each. Rejections are recorded so the same proposal doesn't come back. Memory has a word budget; `/debrief` also proposes pruning stale or contradicted entries.

## Runner launch

| Harness | Flags | Startup dialogs |
| --- | --- | --- |
| Claude | `--permission-mode auto --add-dir <jobdir> --append-system-prompt-file templates/runner-system.md -n <id>` | Folder trust: granted on the client's word (`fixer-trust --grant`), or answered by them via `fixer-trust` |
| Codex | `-a never --disable hooks -c default_permissions="fixer_runner" -c permissions.fixer_runner={extends=":workspace", network={enabled=true}, filesystem={<jobdir>, <git common dir>, <worktree git dir> = "write"}}`. A permissions profile, not `-s workspace-write --add-dir`: Codex keeps a worktree's gitdir read-only even as an extra writable root, so commits and fetches failed. Codex ignores the profile if `sandbox_mode` is set in its config. | Folder trust: granted on the client's word (`fixer-trust --grant`), or answered by them via `fixer-trust` |
| Grok | `--always-approve` | Folder trust: answered by the client via `fixer-trust` (unverified) |

**Folder trust.** Verified on Claude Code 2.1.322: trust does *not* carry over to subfolders (a new worktree under the trusted `~/workspace` still showed the dialog), but it *is* keyed on the main repository (a worktree of a trusted repo, outside any trusted folder, opened with no dialog). Codex records trust for the repository root too. So each project is trusted once, for its main checkout, in one of two ways. `fixer-trust <project> --grant` writes the harness's own trust record: `projects[path].hasTrustDialogAccepted = true` in `${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json` (jq, temp file and rename, checked that no other key changed), or an appended `[projects."<path>"] trust_level = "trusted"` table in `${CODEX_HOME:-~/.codex}/config.toml`. It backs the file up to `<file>.fixer-bak`, refuses anything but a registered project's main checkout, refuses when the harness already holds a different record for that path (such as `untrusted`), and reads the trust back with `harness_trusts`. It does not write Grok's store yet. Plain `fixer-trust <project>` opens the agent in the checkout so the client answers the real dialog instead.

fixer edits harness trust config only on the client's explicit word, per project: `--grant` asks "Trust <project> (<path>) for <harness>? [y/N]" on the terminal, or takes `--yes` when the client runs it themselves (`!` in Claude Code), answers yes in `./setup`, or names that project to the Fixer in their current request. With no terminal and no `--yes` it refuses, and `fixer-allow` never auto-allows it. fixer never presses keys on a trust dialog; `fixer-spawn` refuses a project that isn't trusted yet.

**Permissions.** `fixer-allow`, run by the client with Claude Code's `!` prefix, adds allow rules for the routine scripts to the gitignored `.claude/settings.local.json`. `fixer-land`, `fixer-teardown`, `fixer-project add` and `fixer-trust` (including `--grant`) always ask.

## Verified (2026-11-10, Herdr 0.9.5)

- Claude Code 2.1.322 as runner, gig in local mode: spawn, the watcher waking on `done`, review, the land and teardown refusals, landing, teardown. No leftovers.
- Codex 0.167.0 as runner, recon: trust dialog, sandboxed `fixer-report`, `blocked` answered via `fixer-tell`, report, teardown.
- Not yet verified: `pr` mode against real GitHub/GitLab, Grok, Codex or Grok as the Fixer.

## Decisions

- fixer is a project of itself (`fixer`, local mode, registered by `./setup`). Changes to its tracked files are gigs, so the Fixer never does work directly, not even on its own code or contract; only private state and the exact text of accepted `/debrief` proposals are written directly. Local-mode spawns branch from the local base, not `origin/<base>`, because landing merges back into the local checkout.

- Learned skills and brief patches are committed to the client's fork. Upstream never edits `learned/`. Profile and engrams stay private in `data/`.

## Setup and launch

- **`./setup`** (run once after cloning, outside the agent): dependencies, client name, Fixer and runner harness, delivery default, Herdr agent hooks (`herdr integration install`), gh/glab logins, `upstream` remote (guessed from the fork's parent via gh), `fixer-allow`, folder trust for the fixer repo and any projects ("Trust <p> for <harness> now?" runs `fixer-trust --grant`, with `fixer-trust`'s foreground dialog as the fallback), then the launcher alias. Re-runnable; current values are the defaults. Writes `onboarded=no` so the first session runs the in-chat welcome.
- **Launcher:** the alias is `holocall` and the opening line "got a job for you" (`FIXER_ALIAS` / `FIXER_GREETING` in `bin/fixer-lib.sh`).
- **`bin/fixer-launcher install|remove|show`** writes the alias to `~/.zshrc`, `~/.bashrc`, or a fish `conf.d` file, fenced by markers naming this clone's path.
- **`bin/fixer-launch`** (what the alias runs): if the Herdr session `fixer` (config `herdr_session`) exists, ask open / new / cancel. New replaces it: live runners are listed and must be confirmed by typing `replace`, since stopping the session ends their panes (worktrees and job records survive). A fresh start runs a headless `herdr --session fixer server`, creates one `fixer` workspace at the repo, closes the server's default workspace, runs `<harness> "<greeting>"` in it, and attaches. A second session alongside was rejected: two Fixers on one job board would both supervise and land.
- The Fixer is started with `herdr agent start fixer --kind <harness> -- "<greeting>"`, not `pane run`: a command typed into a shell that is still running its startup files gets lost. The server's default workspace is closed only once its shell is idle, because killing a shell mid-startup can leave pyenv's rehash lock behind and stall every later shell. Verified 2026-11-10: fresh start in 5.5s, one `fixer` workspace, the Fixer running.

## Lowkey (Claude Code)

A mod at `.claude/mods/fixer-lowkey`, auto-loaded through `.agents/skills/fixer-lowkey` (a symlink, the same pattern firstmate uses). It does nothing unless `config/fixer.conf` exists. On by default: only `lowkey=off` turns it off.

| Hook | With lowkey on |
| --- | --- |
| `ui.render` ToolUse / ToolResult / ToolGroup | drawn as nothing (passes through when `isExpanded`, i.e. ctrl+o) |
| `ui.render` UserMessage | the watcher's task-notification row (its description starts `fixer-wait:`) drawn as nothing |
| `ui.render` Spinner | the `▌MERCS` row (when any merc is live) above the hex stream (`hooks/hexstream.ts`, a pure function of width and frame) |
| `ui.render` AbovePrompt | between turns (`!isWorking`): the `▌MERCS` row from `data/jobs/*/job.conf`, refined by `herdr agent list` (a merc at a dialog shows `DIALOG`), and under it, while a merc is working and the band isn't collapsed, the hex stream in a dimmer teal sized to `bodyColumns`. During a turn it draws nothing: the Spinner carries the row |
| `turn.step` + `ui.render` AssistantMessage | short mid-turn narration drawn as nothing (`hooks/narration.ts`) |
| `$.session.append` system notice | one dim note per new `status.log` line; display-only, the model never reads it |
| `/lowkey` | toggles `lowkey=` in `config/fixer.conf`, confirms with a toast |

Polls job files every 3s. The status items always sit above the animation: in a turn the Spinner draws the MERCS row and then the stream, and the band stays empty so the row never shows twice; between turns the band draws the row and then the stream. (The engine draws the Spinner above the band, so the row moves into the Spinner rather than the band drawing above it.) Merc reports are transcript notices, so they're above both already.

A merc is *working* when its job status is `starting`/`running` and Herdr doesn't see its pane `blocked`, `idle` or `done`; without Herdr the job status alone decides. Blocked, dialog, review/reported and failed mercs stay in the band but don't animate it. The 120ms frame timer runs while lowkey is on and a turn is running or a merc is working, and stops otherwise. It is re-checked on turn start/complete/abort, after each poll (so it stops at most 3s after the last merc reports), and on `/lowkey`. The frame counter is never reset, so the stream resumes where it stopped. Seen status-log counts are kept in `$.store` so a restart doesn't replay old events.

Narration hiding follows firstmate's Calm. A `turn.step` hook watches each main-agent step's text blocks without changing the stream. Text from a step that stopped for tools (`stopReason` `tool_use`, or `max_tokens` with tool calls) is a working note unless it has a newline or is 240+ characters trimmed. Matching `AssistantMessage` rows draw as nothing. Text that was ever a final reply stays visible, and a restored transcript is classified the same way at session start from `$.session.messages()`. It is display-only: the model's context is unchanged. The 2.1.322 `AssistantMessage` props carry no `isExpanded`, so the hook passes when one is sent, but ctrl+o may not reveal hidden notes on this build. A note can show briefly while it streams, before its step ends and the redraw hides it.

Verified: `claude plugin validate`, `tsc` against the 2.1.322 types, and `claude plugin test` (18 tests). Not yet seen live in a session.

## Open questions

- Whether Claude Code asks the client before auto-loading a project's mod, or needs a flag, on current builds. Check during the first live onboarding.
