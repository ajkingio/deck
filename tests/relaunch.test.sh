#!/usr/bin/env bash
# deck-spawn --relaunch restarts a gone worker in place; deck-tell --interrupt stops a turn.
. "$(dirname "$0")/lib.sh"

# A job spawned for real (workspace ws-1, pane pane-1) whose worker committed
# once, then exited without reporting; deck-wait has noticed.
gone_job() {
  make_project app local
  trust_claude app
  deck job new app-job --project app --kind gig >/dev/null
  fill_brief app-job
  export HERDR_ENV=1
  deck spawn app-job >/dev/null 2>&1 || fail "initial spawn failed"
  wt=$(job_value app-job worktree)
  echo half >"$wt/half.txt"
  git -C "$wt" add half.txt
  git -C "$wt" commit --quiet -m "first half"
  commit=$(git -C "$wt" rev-parse HEAD)
  rm "$T/herdr/agents/app-job"
  deck wait --once >/dev/null
  : >"$T/calls.log"
}

test_gone_status_set_by_wait() {
  gone_job
  expect_status app-job gone
  expect_eq "$(job_value app-job herdr_flag)" gone "herdr_flag"
  run sitrep
  expect_out "app-job [gone]"
}

test_refuses_while_agent_is_live() {
  gone_job
  echo working >"$T/herdr/agents/app-job"
  run spawn app-job --relaunch
  expect_refused "a live agent still owns job app-job"
  expect_status app-job gone
  expect_not_called "herdr workspace create"
  expect_not_called "herdr agent start"
}

test_refuses_queued_job() {
  make_project app local
  trust_claude app
  deck job new app-job --project app --kind gig >/dev/null
  export HERDR_ENV=1
  run spawn app-job --relaunch
  expect_refused "has not been spawned yet"
  expect_status app-job queued
}

test_relaunch_reuses_worktree_and_branch() {
  gone_job
  echo "ws-2 pane-2" >"$T/herdr/new-workspace"
  run spawn app-job --relaunch; expect_ok "relaunch"
  expect_out "relaunched app-job"
  expect_eq "$(job_value app-job worktree)" "$wt" "worktree"
  expect_eq "$(git -C "$wt" symbolic-ref --short HEAD)" deck/app-job "branch"
  expect_eq "$(git -C "$wt" rev-parse HEAD)" "$commit" "branch head"
  [ -f "$wt/half.txt" ] || fail "the earlier worker's file is gone"
  # The old workspace is gone (the stub lists none), so a new one was made.
  expect_called "herdr workspace create --cwd $wt --label └ app-job"
  expect_called "herdr agent start app-job --kind claude --pane pane-2"
}

test_relaunch_reuses_live_pane() {
  gone_job
  printf '{"result":{"workspaces":[{"workspace_id":"ws-1","label":"└ app-job"}]}}\n' >"$T/herdr/workspaces.json"
  mkdir -p "$T/herdr/panes"; echo ws-1 >"$T/herdr/panes/pane-1"
  run spawn app-job --relaunch; expect_ok "relaunch"
  expect_not_called "herdr workspace create"
  expect_called "herdr agent start app-job --kind claude --pane pane-1"
}

test_preamble_has_note_and_messages() {
  gone_job
  printf '2026-01-01T00:00:00Z use the sqlite backend\n' >"$DECK/data/jobs/app-job/messages.log"
  run spawn app-job --relaunch --note "tests pass; docs left"; expect_ok "relaunch"
  expect_called "herdr agent prompt app-job You are worker app-job, hired by deck. You were relaunched"
  expect_called "git log $(job_value app-job base_sha)..HEAD"
  expect_called "$DECK/data/jobs/app-job/status.log"
  expect_called "Progress note from deck: tests pass; docs left"
  expect_called "use the sqlite backend"
}

test_relaunch_updates_record() {
  gone_job
  deck report app-job blocked "old question" >/dev/null
  deck job set app-job seen_lines 1
  echo "ws-2 pane-2" >"$T/herdr/new-workspace"
  run spawn app-job --relaunch; expect_ok "relaunch"
  expect_status app-job running
  expect_eq "$(job_value app-job workspace)" ws-2 "workspace"
  expect_eq "$(job_value app-job pane)" pane-2 "pane"
  expect_eq "$(job_value app-job seen_lines)" 1 "seen_lines"
  expect_eq "$(job_value app-job herdr_flag)" "" "herdr_flag"
  [ -n "$(job_value app-job relaunched)" ] || fail "relaunched time not recorded"
  # The watcher picks the new worker up, and old reports aren't replayed.
  run wait --once
  expect_eq "$OUT" "no events" "wait after relaunch"
}

test_failed_start_leaves_record() {
  gone_job
  cp "$DECK/data/jobs/app-job/job.conf" "$T/before.conf"
  echo "ws-2 pane-2" >"$T/herdr/new-workspace"
  echo boom >"$T/herdr/start-fails"
  run spawn app-job --relaunch --note "half done"
  expect_refused "herdr agent start failed"
  expect_eq "$(cat "$DECK/data/jobs/app-job/job.conf")" "$(cat "$T/before.conf")" "job.conf"
  expect_called "herdr workspace close ws-2"
  expect_eq "$(git -C "$wt" rev-parse HEAD)" "$commit" "branch head"
}

test_startup_dialog_then_resume_finishes_relaunch() {
  gone_job
  echo agent_not_ready >"$T/herdr/start-fails"
  run spawn app-job --relaunch --note "half done"
  expect_refused "stopped at a startup dialog"
  expect_status app-job starting
  rm "$T/herdr/start-fails"; echo working >"$T/herdr/agents/app-job"
  run spawn app-job --resume; expect_ok "resume"
  expect_status app-job running
  expect_called "You were relaunched"
  expect_called "Progress note from deck: half done"
  expect_eq "$(job_value app-job relaunch_pending)" "" "relaunch_pending"
}

test_interrupt_sends_escape_for_claude() {
  gone_job
  echo working >"$T/herdr/agents/app-job"
  export DECK_INTERRUPT_SETTLE=0
  run tell app-job --interrupt "stop looping; run the tests once"; expect_ok "interrupt"
  expect_called "herdr agent send-keys app-job esc"
  expect_called "herdr agent prompt app-job Message from deck: stop looping; run the tests once"
  [ "$(grep -n 'send-keys' "$T/calls.log" | cut -d: -f1)" -lt "$(grep -n 'agent prompt' "$T/calls.log" | cut -d: -f1)" ] ||
    fail "the message went out before the interrupt"
}

test_interrupt_key_per_harness() {
  gone_job
  echo working >"$T/herdr/agents/app-job"
  export DECK_INTERRUPT_SETTLE=0
  deck job set app-job harness codex
  run tell app-job --interrupt; expect_ok "codex interrupt"
  expect_called "herdr agent send-keys app-job esc"
  deck job set app-job harness grok
  run tell app-job --interrupt; expect_ok "grok interrupt"
  expect_called "herdr agent send-keys app-job ctrl+c"
  expect_not_called "agent prompt"
  deck job set app-job harness mystery
  run tell app-job --interrupt
  expect_refused "no known interrupt key for harness 'mystery'"
}

test_interrupt_refuses_dialog_and_gone() {
  gone_job
  run tell app-job --interrupt
  expect_refused "no live agent"
  echo blocked >"$T/herdr/agents/app-job"
  run tell app-job --interrupt
  expect_refused "is at a dialog"
  expect_not_called "send-keys"
}

test_interrupt_skips_key_when_idle() {
  gone_job
  echo idle >"$T/herdr/agents/app-job"
  run tell app-job --interrupt "carry on"; expect_ok
  expect_out "no interrupt sent"
  expect_not_called "send-keys"
  expect_called "Message from deck: carry on"
}

run_tests "${1:-}"
