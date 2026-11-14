#!/usr/bin/env bash
# The core happy path: job new -> spawn -> deck-report done -> deck-wait.
. "$(dirname "$0")/lib.sh"

test_new_spawn_report_wait() {
  make_project app local
  trust_claude app
  run job new app-fix --project app --kind gig --title "Fix it"; expect_ok "job new"
  expect_status app-fix queued
  fill_brief app-fix

  export HERDR_ENV=1
  run spawn app-fix; expect_ok "spawn"
  expect_status app-fix running
  wt=$(job_value app-fix worktree)
  [ -d "$wt" ] || fail "worktree $wt was not created"
  case $wt in "$T"/*) ;; *) fail "worktree $wt is outside the sandbox" ;; esac
  expect_eq "$(git -C "$wt" symbolic-ref --short HEAD)" deck/app-fix "worktree branch"
  expect_eq "$(job_value app-fix workspace)" ws-1 "workspace"
  expect_called "herdr workspace create --cwd $wt --label └ app-fix"
  expect_called "herdr agent start app-fix --kind claude --pane pane-1"
  expect_called "herdr agent prompt app-fix You are worker app-fix"

  run report app-fix done "branch ready abc1234"; expect_ok "report"
  run wait --once; expect_ok "wait"
  expect_eq "$OUT" "app-fix done branch ready abc1234" "wait output"
  expect_status app-fix review
  expect_called "herdr notification show app-fix: done"

  # The event is consumed: no job is running any more.
  run wait --once
  expect_eq "$OUT" "none no running jobs to watch" "second wait"
}

test_wait_reports_blocked_and_failed() {
  make_project app local
  make_review_job one app; deck job set one status running
  make_review_job two app; deck job set two status running
  echo working >"$T/herdr/agents/one"; echo working >"$T/herdr/agents/two"
  deck report one blocked "which database?" >/dev/null
  deck report two failed "tests do not build" >/dev/null
  run wait --timeout 5; expect_ok "wait"
  expect_out "one blocked which database?"
  expect_out "two failed tests do not build"
  expect_status one blocked
  expect_status two failed
  [ ! -f "$DECK/state/wait.pid" ] || fail "wait left its lock behind"
}

test_wait_reports_gone_worker_once() {
  make_project app local
  make_review_job gone-job app; deck job set gone-job status running
  run wait --once; expect_ok
  expect_eq "$OUT" "gone-job gone worker agent is no longer running" "wait output"
  expect_status gone-job gone
  # Announced once; a gone job isn't live, so there is nothing left to watch.
  run wait --once
  expect_eq "$OUT" "none no running jobs to watch" "second wait"
}

test_wait_refuses_second_watcher() {
  sleep 30 & pid=$!
  echo $pid >"$DECK/state/wait.pid"
  run wait --timeout 1
  kill $pid 2>/dev/null
  expect_eq "$rc" 3 "exit code"
  expect_out "already watching"
}

test_report_rejects_unknown_event() {
  make_project app local
  deck job new app-x --project app --kind gig >/dev/null
  run report app-x finished "all good"
  expect_refused "event must be done, blocked or failed"
  expect_eq "$(wc -c <"$DECK/data/jobs/app-x/status.log" | tr -d ' ')" 0 "status.log size"
}

run_tests "${1:-}"
