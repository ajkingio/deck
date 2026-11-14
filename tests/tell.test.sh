#!/usr/bin/env bash
# deck-tell re-opens a job waiting on the operator, so deck-wait watches it again.
. "$(dirname "$0")/lib.sh"

# A gig whose worker reported done and deck-wait consumed it: status review.
reviewed_job() {
  make_project app local
  make_review_job app-job app
  deck job set app-job status running
  echo working >"$T/herdr/agents/app-job"
  deck report app-job done "branch ready abc1234" >/dev/null
  deck wait --once >/dev/null
  expect_status app-job review
  : >"$T/calls.log"
}

test_review_goes_running_on_delivery() {
  reviewed_job
  run tell app-job "rename the flag to --force"; expect_ok "tell"
  expect_out "app-job: review -> running"
  expect_out "told app-job"
  expect_status app-job running
  expect_eq "$(job_value app-job seen_lines)" 1 "seen_lines"
}

test_old_done_not_replayed_next_done_reported() {
  reviewed_job
  run tell app-job "rename the flag to --force"; expect_ok "tell"
  run wait --once
  expect_eq "$OUT" "no events" "wait after tell"
  deck report app-job done "branch ready def5678" >/dev/null
  run wait --once
  expect_eq "$OUT" "app-job done branch ready def5678" "wait after second done"
  expect_status app-job review
}

test_blocked_goes_running_on_delivery() {
  reviewed_job
  deck job set app-job status running
  deck report app-job blocked "which database?" >/dev/null
  deck wait --once >/dev/null
  expect_status app-job blocked
  run tell app-job "sqlite"; expect_ok "tell"
  expect_out "app-job: blocked -> running"
  expect_status app-job running
}

test_reported_recon_goes_running_on_delivery() {
  make_project app local
  make_review_job rec-job app recon
  deck job set rec-job status reported
  echo idle >"$T/herdr/agents/rec-job"
  run tell rec-job "and what about the cache?"; expect_ok "tell"
  expect_out "rec-job: reported -> running"
  expect_status rec-job running
}

test_no_change_when_refused_at_dialog() {
  reviewed_job
  echo agent_blocked >"$T/herdr/prompt-fails"
  run tell app-job "rename the flag"
  expect_refused "is at a dialog"
  expect_status app-job review
  case $OUT in *"-> running"*) fail "printed a status change on refusal: $OUT" ;; esac
}

test_no_change_when_delivery_fails() {
  reviewed_job
  echo agent_not_found >"$T/herdr/prompt-fails"
  run tell app-job "rename the flag"
  expect_refused "could not reach worker app-job"
  expect_status app-job review
}

test_no_change_on_bare_interrupt() {
  reviewed_job
  export DECK_INTERRUPT_SETTLE=0
  run tell app-job --interrupt; expect_ok "interrupt"
  expect_called "herdr agent send-keys app-job esc"
  expect_status app-job review
  case $OUT in *"-> running"*) fail "printed a status change: $OUT" ;; esac
}

test_other_statuses_untouched() {
  reviewed_job
  for s in queued starting gone landed closed cancelled failed; do
    deck job set app-job status "$s"
    run tell app-job "hello"; expect_ok "tell ($s)"
    expect_status app-job "$s"
  done
}

run_tests "${1:-}"
