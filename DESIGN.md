# fixer — design

fixer is a lightweight agent distro inspired by [firstmate](https://github.com/kunchenguid/firstmate).
Clone it, launch a supported agent inside Herdr, and that agent becomes your **Fixer**: the one agent you talk to, which hires runners to do the work and reports back only outcomes and decisions.

Status: draft. Decisions below are agreed unless marked **open**.

## Goals

- **Clone and go.** No install step. `git clone`, start `herdr`, start your agent inside it, answer a few onboarding questions.
- **Lightweight.** The always-loaded contract (`AGENTS.md`) stays under ~1,500 words. Mechanics live in a handful of small scripts.
- **Themeable.** cyberpunk-netrunner by default; the user picks a theme in `./setup`.
- **Learns, with consent.** fixer proposes what to remember and which skills to create; nothing is written without the user's approval.

## Non-goals (things firstmate has that fixer deliberately drops)

Session backends other than Herdr, harnesses beyond the three below, secondmates/remote homes, quota-aware dispatch, Relay (X/Discord), voice, calm mode, the no-mistakes pipeline, Gerrit/Forgejo/external forges, the zero-token watcher daemon.

## Roles

| Neutral term (AGENTS.md, scripts) | cyberpunk-netrunner (default) | cyberpunk-fixer |
| --- | --- | --- |
| operator, the main agent | **the deck** (the cyberdeck's AI) | **the Fixer** |
| user | **netrunner** | **client** |
| worker | daemon | merc |
| ship task | run | gig |
| scout task | scan | recon |
| worktree | subnet | safehouse |
| backlog | queue | job board |
| memory entry | shard | engram |
| hard rules | ICE | — |
| launcher / greeting | `jackin` / "jack in" | `holocall` / "got a job for you" |

The split came from the launcher: a client doesn't jack in, a netrunner does. So the netrunner theme makes the user the netrunner and the agent their deck, and the original broker persona became its own theme, where the client reaches their Fixer by holocall.

## Hard rules

1. **Strict delegation.** The Fixer never writes to a project. All project work — even trivial — goes to a runner in its own worktree. The Fixer reads projects and maintains only its own `data/`, `state/`, `config/`.
2. **No merge without the client's explicit word.** Merges always pin the reviewed head commit.
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
AGENTS.md              the contract (theme-neutral)
CLAUDE.md              @AGENTS.md   (Codex and Grok read AGENTS.md natively)
DESIGN.md              this file
themes/                cyberpunk-netrunner.md, cyberpunk-fixer.md, nautical.md, plain.md, <custom>.md
.agents/skills/        shared skills; .claude/skills -> ../.agents/skills
templates/             gig-brief.md, recon-brief.md
bin/
  fixer-doctor         dependency + environment check
  fixer-spawn          worktree + agent start + brief + job record
  fixer-wait           block until any runner changes state or appends a status line
  fixer-sitrep         snapshot of every job
  fixer-forge          gh/glab adapter (see Forges)
  fixer-teardown       close workspace + remove worktree, refuses on unlanded work
# gitignored, private to the client:
config/                theme, client-name, runner-harness, delivery default
data/                  jobs.md, projects.md, profile.md, engrams/, proposals.md, reports/<id>.md
projects/              read-only clones
state/                 <job-id>.status append-only event lines
```

## Job lifecycle

1. **Intake.** Client asks; Fixer resolves the project, classifies as gig (ship) or recon (scout), files it on the job board.
2. **Brief.** Fixer fills a template with the client's intent, scope limits, delivery mode, and the engrams tagged for that project (this is how learning reaches runners, which load the project's instructions, not fixer's).
3. **Spawn.** `fixer-spawn`:
   `git worktree add -b fixer/<id> ~/.fixer/worktrees/<home>/<id>` →
   `herdr workspace create --cwd <worktree> --label <id> --env FIXER_JOB=<id> ...` →
   `herdr agent start <id> --kind <harness> --pane <root-pane> -- <autonomy flags>` →
   `herdr agent prompt <id> "read your brief at ..."`.
   We don't use `herdr worktree create`: it also opens a workspace for the main repo when none exists, which teardown would then have to account for. With plain git plus `workspace create`, each job owns exactly one workspace.
   Worktrees live outside the fixer repo because Claude Code loads `CLAUDE.md` from parent directories, so a worktree inside fixer would make the runner act as a Fixer.
4. **Report.** The runner appends one line to `state/<id>.status`: `done <url|sha>`, `blocked <question>`, or `failed <reason>`. Recon also writes `data/reports/<id>.md`. Herdr's own `blocked` state catches approval dialogs the runner can't report itself.
5. **Relay.** Fixer tells the client the outcome or decision, optionally with `herdr notification show`.
6. **Land.** On the client's word: `fixer-forge merge` (pr mode) or a local fast-forward merge (local mode).
7. **Teardown.** `fixer-teardown` only after work has landed.

Delivery modes per project: `pr` (open PR/MR; client merges or says "merge it") and `local` (merge branch locally on approval).

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

## Themes

A theme file defines role names, vocabulary, and tone. Theme affects chat only — never commits, PR/MR text, briefs, or code. Slang drops entirely for bad news. Slash commands keep neutral names; a theme may not rename them.

Onboarding (runs automatically when `config/` is absent): pick a theme (or describe one and the Fixer writes `themes/<name>.md`), name to address the client by, `fixer-doctor`, first project and delivery mode.

## Skills (v1)

- **onboarding** — automatic first-run setup.
- **/sitrep** — what changed, what's running, what needs the client (merges firstmate's `/ahoy` and `/bearings`).
- **/debrief** — run the learning loop on demand.
- **/retheme** — switch theme.

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
| Claude | `--permission-mode auto --add-dir <jobdir> --append-system-prompt-file templates/runner-system.md -n <id>` | Folder trust: answered by the client via `fixer-trust` |
| Codex | `-s workspace-write -a never --add-dir <jobdir> -c sandbox_workspace_write.network_access=true --disable hooks` | Folder trust: answered by the client via `fixer-trust` |
| Grok | `--always-approve` | Folder trust: answered by the client via `fixer-trust` (unverified) |

**Folder trust.** Verified on Claude Code 2.1.322: trust does *not* carry over to subfolders (a new worktree under the trusted `~/workspace` still showed the dialog), but it *is* keyed on the main repository (a worktree of a trusted repo, outside any trusted folder, opened with no dialog). Codex records trust for the repository root too. So the client trusts each project once with `fixer-trust`, which opens the agent in the project checkout so they answer the real dialog. fixer never edits harness config and never presses keys on a trust dialog; `fixer-spawn` refuses a project that isn't trusted yet.

**Permissions.** `fixer-allow`, run by the client with Claude Code's `!` prefix, adds allow rules for the routine scripts to the gitignored `.claude/settings.local.json`. `fixer-land`, `fixer-teardown`, `fixer-project add` and `fixer-trust` always ask.

## Verified (2026-11-10, Herdr 0.9.5)

- Claude Code 2.1.322 as runner, gig in local mode: spawn, the watcher waking on `done`, review, the land and teardown refusals, landing, teardown. No leftovers.
- Codex 0.167.0 as runner, recon: trust dialog, sandboxed `fixer-report`, `blocked` answered via `fixer-tell`, report, teardown.
- Not yet verified: `pr` mode against real GitHub/GitLab, Grok, Codex or Grok as the Fixer.

## Decisions

- Learned skills, brief patches and custom themes are committed to the client's fork. Upstream never edits `learned/`. Profile and engrams stay private in `data/`.

## Setup and launch

- **`./setup`** (run once after cloning, outside the agent): dependencies, theme, client name, Fixer and runner harness, delivery default, Herdr agent hooks (`herdr integration install`), gh/glab logins, `upstream` remote (guessed from the fork's parent via gh), `fixer-allow`, folder trust for the fixer repo and any projects (`fixer-trust` in foreground mode), then the launcher alias. Re-runnable; current values are the defaults. Writes `onboarded=no` so the first session runs the in-chat welcome.
- **Theme frontmatter** carries `launcher` (alias name), `greeting` (the opening line), `client_title`, `crew_label` (the calm band's title) and `calm` (the spinner animation). cyberpunk-netrunner: `jackin` / "jack in" / DAEMONS; cyberpunk-fixer: `holocall` / "got a job for you" / MERCS; nautical: `ahoy` / "ahoy" / CREW; plain: `fixer` / "start" / WORKERS.
- **`bin/fixer-launcher install|remove|show`** writes the alias to `~/.zshrc`, `~/.bashrc`, or a fish `conf.d` file, fenced by markers naming this clone's path. `/retheme` reruns `install`, so the alias follows the theme.
- **`bin/fixer-launch`** (what the alias runs): if the Herdr session `fixer` (config `herdr_session`) exists, ask open / new / cancel. New replaces it: live runners are listed and must be confirmed by typing `replace`, since stopping the session ends their panes (worktrees and job records survive). A fresh start runs a headless `herdr --session fixer server`, creates one `fixer` workspace at the repo, closes the server's default workspace, runs `<harness> "<greeting>"` in it, and attaches. A second session alongside was rejected: two Fixers on one job board would both supervise and land.
- The Fixer is started with `herdr agent start fixer --kind <harness> -- "<greeting>"`, not `pane run`: a command typed into a shell that is still running its startup files gets lost. The server's default workspace is closed only once its shell is idle, because killing a shell mid-startup can leave pyenv's rehash lock behind and stall every later shell. Verified 2026-11-10: fresh start in 5.5s, one `fixer` workspace, `claude 'jack in'` running.

## Calm mode (Claude Code)

A mod at `.claude/mods/fixer-calm`, auto-loaded through `.agents/skills/fixer-calm` (a symlink, the same pattern firstmate uses). It does nothing unless `config/fixer.conf` exists. On by default: only `calm=off` turns it off.

| Hook | With calm on |
| --- | --- |
| `ui.render` ToolUse / ToolResult / ToolGroup | drawn as nothing (passes through when `isExpanded`, i.e. ctrl+o) |
| `ui.render` UserMessage | the watcher's task-notification row (its description starts `fixer-wait:`) drawn as nothing |
| `ui.render` Spinner | an animation from `hooks/animations.ts` (pure functions of width and frame): `hex-stream`, `ice-breach`, `glitch` (cycles the theme's `calm_words`), `tide`, `pulse`, or `stock`. The client's pick (`calm_animation=`) wins over the theme's `calm:` default |
| `ui.render` AbovePrompt | crew band (titled by the theme's `crew_label`) from `data/jobs/*/job.conf`, refined by `herdr agent list` (a runner at a dialog shows `DIALOG`) |
| `$.session.append` system notice | one dim note per new `status.log` line; display-only, the model never reads it |
| `/calm` + the theme's `calm_command` (`/ghost`, `/lowkey`, `/focus`) | toggles `calm=` in `config/fixer.conf`; with an argument it switches the animation (`calm_animation=`, turning quiet mode on), `list` shows them; confirms with a toast; `command.describe` lists only the current theme's name, and an earlier theme's name stays usable but hidden (commands can't be unregistered) |

Polls job files every 3s; the animation timer runs only during a turn. Seen status-log counts are kept in `$.store` so a restart doesn't replay old events. Assistant narration is not hidden: the API gives no reliable way to tell a mid-turn note from the final reply, and the contract already tells the Fixer not to narrate.

Verified: `claude plugin validate`, `tsc` against the 2.1.322 types, and `claude plugin test` (4 tests). Not yet seen live in a session.

## Open questions

- Whether Claude Code asks the client before auto-loading a project's mod, or needs a flag, on current builds. Check during the first live onboarding.
