#!/usr/bin/env bash
# deck-spawn refuses to hire a worker without its preconditions.
. "$(dirname "$0")/lib.sh"

# A queued job with a filled brief on a trusted project: everything spawn needs.
ready_job() {
  make_project app local
  trust_claude app
  deck job new app-job --project app --kind gig >/dev/null
  fill_brief app-job
  export HERDR_ENV=1
}

no_worktree_or_herdr() {
  [ ! -e "$(job_value app-job worktree)" ] || fail "a worktree was created"
  expect_not_called "herdr workspace create"
  expect_not_called "herdr agent start"
}

test_refuses_outside_herdr() {
  ready_job
  unset HERDR_ENV
  run spawn app-job
  expect_refused "not running inside Herdr"
  expect_status app-job queued
  no_worktree_or_herdr
}

test_refuses_unfilled_brief() {
  make_project app local
  trust_claude app
  deck job new app-job --project app --kind gig >/dev/null
  export HERDR_ENV=1
  run spawn app-job
  expect_refused "brief still has DECK:FILL markers"
  no_worktree_or_herdr
}

test_refuses_untrusted_project() {
  ready_job
  rm -f "$HOME/.claude.json"
  run spawn app-job
  expect_refused "doesn't trust project app"
  no_worktree_or_herdr
}

test_refuses_job_not_queued() {
  ready_job
  deck job set app-job status running
  run spawn app-job
  expect_refused "job app-job is running, not queued"
  no_worktree_or_herdr
}

test_refuses_missing_harness() {
  ready_job
  rm "$T/stubs/claude"
  run spawn app-job
  expect_refused "worker harness 'claude' is not installed"
  no_worktree_or_herdr
}

test_refuses_existing_worktree_path() {
  ready_job
  wt=$(job_value app-job worktree)
  mkdir -p "$wt"; echo keep >"$wt/precious.txt"
  run spawn app-job
  expect_refused "worktree path already exists"
  expect_eq "$(cat "$wt/precious.txt")" keep "existing file"
  expect_not_called "herdr workspace create"
}

test_refuses_unknown_job() {
  run spawn nope
  expect_refused "no such job: nope"
}

test_resume_only_for_starting_job() {
  ready_job
  run spawn app-job --resume
  expect_refused "--resume is only for a job stuck in 'starting'"
}

run_tests "${1:-}"
