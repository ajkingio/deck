---
name: vuln-tickets
description: Work a batch of VULN Jira tickets (FOSSA dependency findings) from a JQL query through to merged fixes and closed tickets. Use when the user asks to fix, remediate, or close their open VULN tickets, or gives a VULN JQL query.
---

# VULN tickets

Jira reads can use the Splunk Atlassian MCP; Jira writes go through the `ghost jira` CLI (see the `jira-via-ghost` engram). Nothing goes to a forge or Jira without the user's word.

## 1. Read the tickets

Run the user's JQL. FOSSA tickets carry a table in the description: `originPath` (manifest), `dependency`, `current_version`, `remediation` (fix version), `severity`, and a FOSSA URL whose path names the repo host and path (`github.com/splunk/<repo>` or `cd.splunkdev.com/<group>/<repo>`). Large results: save to a file and slice with `jq`.

Set aside tickets that are not FOSSA dependency findings, are already in Security Validation, or name no repo. List them for the user and ask.

## 2. Group by repo

One repo = one gig. Register any missing repo with `bin/deck-project add` (reuse a clean local clone if one exists; set `--forge` from the host). Check trust with `bin/deck-trust <p> --check`; grant only on the user's word.

## 3. Brief each gig

All of a repo's tickets in one branch. The brief gives a table of ticket, package, current, fix version, severity, due date, and manifest, and asks the worker to:

- check `main` first (scans go stale) and record the version resolved today; skip a ticket only if it is already fixed;
- npm: upgrade the direct parent that pulls the package in, refresh the lockfile with the repo's npm, use `overrides` only as a last resort, flag major bumps and engine changes, verify with `npm ls` and `npm audit` before and after;
- Python: raise the floor in every manifest that pins the package, keep existing caps, verify in a throwaway venv (`pip check`, imports, tests);
- run the repo's own tests and build, and say what was already failing on main;
- reference every ticket key in the commit and PR/MR title, and give a per-ticket status (fixed / already fixed / not fixed + why).

Spawn the gigs in parallel; they touch different repos.

## 4. Review and open

On each `done`, read the report and the diff against `origin/main`. Show the user one summary table: repo, tickets, change, anything to know (major bumps, engine changes, overlapping Dependabot PRs). On their word, `bin/deck-open` each job, then comment on every ticket with `ghost jira comment <key> "<text>"`: the PR/MR link, old → new version, how verified. Ghost uses Jira wiki syntax (`{{code}}`), not Markdown.

## 5. Close

When the PRs/MRs are merged (`bin/deck-forge -C <worktree> status`) and the user says close:

```
ghost jira batch-close <key> <key> ... --vex-status resolved --vex-justification upgraded_to_safe_version --dry-run
ghost jira batch-close <key> <key> ... --vex-status resolved --vex-justification upgraded_to_safe_version --continue-on-error
```

Pass keys as separate arguments (the Bash tool is zsh; an unquoted `$VAR` won't split). Re-run the user's JQL to confirm, then `bin/deck-teardown` each job.
