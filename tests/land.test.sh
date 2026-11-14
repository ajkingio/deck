#!/usr/bin/env bash
# deck-land refuses unless the job and its checkout or PR are in a mergeable state.
. "$(dirname "$0")/lib.sh"

main_sha() { git -C "$(project_path "$1")" rev-parse main; }

# ---- local mode

test_local_refuses_job_not_in_review() {
  make_project app local
  make_review_job app-job app
  deck job set app-job status running
  before=$(main_sha app)
  run land app-job
  expect_refused "job app-job is running, not review"
  expect_eq "$(main_sha app)" "$before" "main"
}

test_local_refuses_recon() {
  make_project app local
  make_review_job probe app recon
  run land probe
  expect_refused "only gigs land"
}

test_local_refuses_dirty_checkout() {
  make_project app local
  make_review_job app-job app
  before=$(main_sha app)
  echo "user's edit" >>"$(project_path app)/README.md"
  run land app-job
  expect_refused "has uncommitted changes; not merging"
  expect_eq "$(main_sha app)" "$before" "main"
  expect_status app-job review
}

test_local_refuses_wrong_branch() {
  make_project app local
  make_review_job app-job app
  before=$(main_sha app)
  git -C "$(project_path app)" checkout --quiet -b elsewhere
  run land app-job
  expect_refused "is on 'elsewhere', not 'main'; not merging"
  expect_eq "$(main_sha app)" "$before" "main"
}

test_local_refuses_conflict_and_leaves_checkout_clean() {
  make_project app local
  make_review_job app-job app
  wt=$(job_value app-job worktree)
  echo "worker" >"$wt/README.md"; git -C "$wt" commit --quiet -am "worker edit"
  p=$(project_path app)
  echo "user" >"$p/README.md"; git -C "$p" commit --quiet -am "user edit"
  before=$(main_sha app)
  run land app-job
  expect_refused "conflicts; nothing changed"
  expect_eq "$(main_sha app)" "$before" "main"
  expect_eq "$(git -C "$p" status --porcelain)" "" "checkout status"
  expect_status app-job review
}

test_local_lands_clean_branch() {
  make_project app local
  make_review_job app-job app
  run land app-job; expect_ok "land"
  expect_status app-job landed
  git -C "$(project_path app)" merge-base --is-ancestor deck/app-job main || fail "branch not merged into main"
}

# ---- pr mode

test_pr_refuses_failing_ci() {
  make_project api pr
  make_review_job api-job api
  forge_pr OPEN FAILURE
  run land api-job
  expect_refused "CI is failing"
  expect_not_called "gh pr merge"
  expect_status api-job review
}

test_pr_refuses_without_pr() {
  make_project api pr
  make_review_job api-job api
  run land api-job
  expect_refused "no PR/MR open for deck/api-job yet"
  expect_not_called "gh pr merge"
}

test_pr_refuses_closed_pr() {
  make_project api pr
  make_review_job api-job api
  forge_pr CLOSED SUCCESS
  run land api-job
  expect_refused "is closed"
  expect_not_called "gh pr merge"
}

test_pr_merges_pinned_head_when_green() {
  make_project api pr
  make_review_job api-job api
  forge_pr OPEN SUCCESS deadbeef
  run land api-job; expect_ok "land"
  expect_called "gh pr merge deck/api-job --match-head-commit deadbeef --squash"
  expect_status api-job landed
  expect_eq "$(job_value api-job landed_sha)" deadbeef "landed_sha"
}

test_pr_reports_failed_merge() {
  make_project api pr
  make_review_job api-job api
  forge_pr OPEN SUCCESS
  : >"$T/forge/merge-fails"
  run land api-job
  expect_refused "merge failed"
  expect_status api-job review
}

run_tests "${1:-}"
