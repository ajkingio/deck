#!/usr/bin/env bash
# deck-teardown refuses unlanded or dirty work unless told --discard.
. "$(dirname "$0")/lib.sh"

branch_exists() { git -C "$(project_path "$1")" rev-parse --verify --quiet "refs/heads/$2" >/dev/null; }

land_locally() { # <id> <project>: merge deck/<id> into main the way deck-land does
  git -C "$(project_path "$2")" merge --quiet --no-edit --no-ff "deck/$1"
}

test_refuses_unlanded_local_work() {
  make_project app local
  make_review_job app-job app
  wt=$(job_value app-job worktree)
  run teardown app-job
  expect_refused "has not landed; refusing"
  [ -d "$wt" ] || fail "worktree was removed"
  branch_exists app deck/app-job || fail "branch was deleted"
  expect_status app-job review
}

test_refuses_landed_but_dirty_worktree() {
  make_project app local
  make_review_job app-job app
  land_locally app-job app
  wt=$(job_value app-job worktree)
  echo "unsaved" >"$wt/scratch.txt"
  run teardown app-job
  expect_refused "has uncommitted changes; refusing"
  [ -f "$wt/scratch.txt" ] || fail "uncommitted file was lost"
}

test_allows_landed_local_work() {
  make_project app local
  make_review_job app-job app
  land_locally app-job app
  wt=$(job_value app-job worktree)
  run teardown app-job; expect_ok "teardown"
  [ ! -d "$wt" ] || fail "worktree still there"
  ! branch_exists app deck/app-job || fail "landed branch was not deleted"
  expect_status app-job closed
}

test_discard_keeps_branch() {
  make_project app local
  make_review_job app-job app
  wt=$(job_value app-job worktree)
  echo "unsaved" >"$wt/scratch.txt"
  run teardown app-job --discard; expect_ok "teardown --discard"
  [ ! -d "$wt" ] || fail "worktree still there"
  branch_exists app deck/app-job || fail "--discard deleted the branch"
  expect_out "kept branch deck/app-job"
  expect_status app-job cancelled
}

test_refuses_recon_without_report() {
  make_project app local
  make_review_job probe app recon
  run teardown probe
  expect_refused "has not landed; refusing"
  echo "# findings" >"$DECK/data/jobs/probe/report.md"
  run teardown probe; expect_ok "teardown with report"
  expect_status probe closed
}

test_refuses_pr_work_until_merged() {
  make_project api pr
  make_review_job api-job api
  wt=$(job_value api-job worktree)
  head=$(git -C "$wt" rev-parse HEAD)
  forge_pr OPEN SUCCESS "$head"
  run teardown api-job
  expect_refused "has not landed; refusing"
  [ -d "$wt" ] || fail "worktree was removed"
  rm "$T/forge/pr.json"
  run teardown api-job
  expect_refused "has not landed; refusing"
  forge_pr MERGED SUCCESS "$head"
  run teardown api-job; expect_ok "teardown after merge"
  expect_status api-job closed
}

test_allows_pr_work_when_branch_is_merged_head() {
  make_project api pr
  make_review_job api-job api
  wt=$(job_value api-job worktree)
  forge_pr MERGED SUCCESS "$(git -C "$wt" rev-parse HEAD)"
  run teardown api-job; expect_ok "teardown"
  [ ! -d "$wt" ] || fail "worktree still there"
  ! branch_exists api deck/api-job || fail "landed branch was not deleted"
  expect_status api-job closed
}

# In pr mode the forge's "merged" covers only the merged head. A commit the
# worker made after the merge (never pushed) has not landed.
test_refuses_pr_commits_made_after_merge() {
  make_project api pr
  make_review_job api-job api
  wt=$(job_value api-job worktree)
  merged=$(git -C "$wt" rev-parse HEAD)
  forge_pr MERGED SUCCESS "$merged"
  echo "late" >"$wt/late.txt"; git -C "$wt" add late.txt; git -C "$wt" commit --quiet -m "after merge"
  late=$(git -C "$wt" rev-parse HEAD)
  run teardown api-job
  expect_refused "commits that were not merged"
  expect_out "after merge"
  expect_out "--discard"
  [ -d "$wt" ] || fail "worktree was removed"
  expect_eq "$(git -C "$(project_path api)" rev-parse deck/api-job)" "$late" "deck/api-job"
  expect_status api-job review

  run teardown api-job --discard; expect_ok "teardown --discard"
  [ ! -d "$wt" ] || fail "worktree still there"
  branch_exists api deck/api-job || fail "--discard deleted the branch"
  expect_status api-job cancelled
}

test_closes_only_its_own_workspace() {
  make_project app local
  make_review_job app-job app
  land_locally app-job app
  deck job set app-job workspace ws-9
  echo '{"result":{"workspaces":[{"workspace_id":"ws-9","label":"something else"}]}}' >"$T/herdr/workspaces.json"
  run teardown app-job; expect_ok
  expect_out "leaving it open"
  expect_not_called "herdr workspace close"

  make_review_job app-two app
  land_locally app-two app
  deck job set app-two workspace ws-8
  echo '{"result":{"workspaces":[{"workspace_id":"ws-8","label":"└ app-two"}]}}' >"$T/herdr/workspaces.json"
  run teardown app-two; expect_ok
  expect_called "herdr workspace close ws-8"
}

run_tests "${1:-}"
