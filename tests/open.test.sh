#!/usr/bin/env bash
# deck-open pushes and opens a PR/MR only for a pr-mode gig that is ready for it.
. "$(dirname "$0")/lib.sh"

# A pr-mode gig in review with its PR title and body written.
ready_pr_job() {
  make_project api pr
  make_review_job api-job api
  echo "Add the thing" >"$DECK/data/jobs/api-job/pr-title.txt"
  echo "Body." >"$DECK/data/jobs/api-job/pr-body.md"
}

remote_has_branch() { git --git-dir="$T/remotes/api.git" rev-parse --verify --quiet "refs/heads/$1" >/dev/null; }

nothing_pushed_or_opened() {
  ! remote_has_branch deck/api-job || fail "the branch was pushed"
  expect_not_called "gh pr create"
}

test_refuses_recon() {
  make_project api pr
  make_review_job probe api recon
  run open probe
  expect_refused "only gigs open PRs/MRs"
}

test_refuses_local_mode() {
  make_project app local
  make_review_job app-job app
  run open app-job
  expect_refused "only pr-mode gigs open PRs/MRs"
}

test_refuses_job_not_in_review() {
  ready_pr_job
  deck job set api-job status running
  run open api-job
  expect_refused "job api-job is running, not review"
  nothing_pushed_or_opened
}

test_refuses_missing_worktree() {
  ready_pr_job
  git -C "$(project_path api)" worktree remove --force "$(job_value api-job worktree)"
  run open api-job
  expect_refused "is gone"
  nothing_pushed_or_opened
}

test_refuses_worktree_on_wrong_branch() {
  ready_pr_job
  git -C "$(job_value api-job worktree)" checkout --quiet -b other
  run open api-job
  expect_refused "is not on deck/api-job"
  nothing_pushed_or_opened
}

test_refuses_dirty_worktree() {
  ready_pr_job
  echo "unsaved" >"$(job_value api-job worktree)/scratch.txt"
  run open api-job
  expect_refused "has uncommitted changes"
  nothing_pushed_or_opened
}

test_refuses_branch_without_commits() {
  ready_pr_job
  git -C "$(job_value api-job worktree)" reset --quiet --hard main
  run open api-job
  expect_refused "has no commits beyond main"
  nothing_pushed_or_opened
}

test_refuses_missing_pr_title_or_body() {
  ready_pr_job
  rm "$DECK/data/jobs/api-job/pr-title.txt"
  run open api-job
  expect_refused "missing $DECK/data/jobs/api-job/pr-title.txt"
  echo "Add the thing" >"$DECK/data/jobs/api-job/pr-title.txt"
  : >"$DECK/data/jobs/api-job/pr-body.md"
  run open api-job
  expect_refused "pr-body.md"
  nothing_pushed_or_opened
}

test_refuses_closed_pr() {
  ready_pr_job
  forge_pr CLOSED SUCCESS
  run open api-job
  expect_refused "is closed; not reopening"
  nothing_pushed_or_opened
}

test_opens_pr_when_ready() {
  ready_pr_job
  run open api-job; expect_ok "open"
  remote_has_branch deck/api-job || fail "branch was not pushed"
  expect_called "gh pr create --head deck/api-job --base main --title Add the thing"
  expect_eq "$(job_value api-job pr_url)" "https://github.com/example/proj/pull/7" "pr_url"
}

test_pushes_new_commits_to_open_pr() {
  ready_pr_job
  forge_pr OPEN PENDING
  run open api-job; expect_ok "open"
  expect_out "pushed new commits to https://github.com/example/proj/pull/7"
  remote_has_branch deck/api-job || fail "branch was not pushed"
  expect_not_called "gh pr create"
}

# The worker-side guard: a worker (DECK_JOB set) can't open a PR through deck-forge.
test_forge_open_refuses_workers() {
  ready_pr_job
  wt=$(job_value api-job worktree)
  rc=0
  OUT=$(cd "$wt" && DECK_JOB=api-job DECK_FORGE=github "$DECK/bin/deck-forge" open --title t --body-file "$DECK/data/jobs/api-job/pr-body.md" 2>&1) || rc=$?
  expect_refused "workers do not push or open PRs/MRs"
  nothing_pushed_or_opened
}

run_tests "${1:-}"
