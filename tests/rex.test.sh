#!/usr/bin/env bash
# Rex as the multiplexer: mux selection, and the Rex backend's spawn, tell,
# interrupt, wait, peek, relaunch, teardown, doctor, launch and trial paths.
. "$(dirname "$0")/lib.sh"

use_rex() { printf 'mux=rex\n' >>"$DECK/config/deck.conf"; export REX_SESSION=session:op; }

# A queued claude job with a filled brief on a trusted project.
ready_job() {
  make_project app local
  trust_claude app
  deck job new app-job --project app --kind gig >/dev/null
  fill_brief app-job
}

# A job spawned under Rex, its worker idle at the brief.
spawned_job() {
  use_rex
  ready_job
  run spawn app-job; expect_ok "spawn"
  : >"$T/calls.log"
}

# ---------------------------------------------------------------- selection

test_default_mux_is_herdr() {
  ready_job
  export HERDR_ENV=1
  run spawn app-job; expect_ok "spawn"
  expect_called "herdr workspace create"
  expect_not_called "rex "
  expect_eq "$(job_value app-job mux)" herdr "recorded mux"
}

test_config_selects_rex() {
  use_rex
  ready_job
  run spawn app-job; expect_ok "spawn"
  expect_not_called "herdr "
  expect_called "rex window new -s session:op └ app-job"
  expect_eq "$(job_value app-job mux)" rex "recorded mux"
  expect_eq "$(job_value app-job mux_session)" session:op "recorded session"
}

test_env_overrides_config() {
  use_rex
  ready_job
  export DECK_MUX=herdr HERDR_ENV=1
  run spawn app-job; expect_ok "spawn"
  expect_called "herdr workspace create"
  expect_not_called "rex window new"
  expect_eq "$(job_value app-job mux)" herdr "recorded mux"
}

test_unknown_mux_refused() {
  ready_job
  export DECK_MUX=tmux
  run spawn app-job
  expect_refused "unknown multiplexer 'tmux'"
  expect_status app-job queued
}

test_job_keeps_its_mux_when_config_changes() {
  spawned_job
  sed -i '' 's/^mux=rex$/mux=herdr/' "$DECK/config/deck.conf"
  rex_state app-job blocked:permission
  run wait --once
  expect_eq "$OUT" "app-job dialog worker is waiting at an approval or question dialog" "wait"
  expect_not_called "herdr "
}

# ---------------------------------------------------------------- spawn

test_spawn_refuses_outside_rex() {
  printf 'mux=rex\n' >>"$DECK/config/deck.conf"
  ready_job
  run spawn app-job
  expect_refused "not running inside Rex"
  expect_status app-job queued
  [ ! -e "$(job_value app-job worktree)" ] || fail "a worktree was created"
  expect_not_called "rex window new"
}

test_spawn_uses_configured_session_outside_rex() {
  printf 'mux=rex\nrex_session=deck-trial\n' >>"$DECK/config/deck.conf"
  ready_job
  run spawn app-job; expect_ok "spawn"
  expect_called "rex window new -s deck-trial └ app-job"
}

test_spawn_runs_harness_in_tab_and_sends_brief() {
  spawned_job
  run spawn app-job --resume
  expect_refused "--resume is only for a job stuck in 'starting'"
  expect_status app-job running
  expect_eq "$(job_value app-job workspace)" window:1 "tab"
  expect_eq "$(job_value app-job pane)" block:1 "block"
  wt=$(job_value app-job worktree)
  [ -d "$wt" ] || fail "no worktree at $wt"
  grep -F "rex window new -s session:op └ app-job" "$T/calls.log" >/dev/null || true
}

test_spawn_command_line() {
  use_rex
  ready_job
  run spawn app-job; expect_ok "spawn"
  expect_out "spawned app-job: harness=claude mux=rex tab=window:1 block=block:1"
  expect_called "--keep-open"
  expect_called "DECK_JOB=app-job"
  expect_called "PI_PROGRAM_STATUS=1"
  expect_called "$T/stubs/claude --permission-mode auto"
  expect_called "-n app-job"
  expect_not_called "--settings"
  expect_called "rex api call -s session:op block.event -"
  expect_called "Read your brief at $DECK/data/jobs/app-job/brief.md"
  expect_called "rex send-key -s session:op -b block:1 enter"
}

test_spawn_hooks_fallback() {
  use_rex
  printf 'rex_claude_hooks=on\n' >>"$DECK/config/deck.conf"
  ready_job
  run spawn app-job; expect_ok "spawn"
  expect_called "--settings $DECK/templates/rex-claude-hooks.json"
}

test_spawn_stops_at_startup_dialog_then_resume() {
  use_rex
  ready_job
  echo blocked:question >"$T/rex/start-state"
  run spawn app-job
  expect_refused "stopped at a startup dialog in Rex tab window:1"
  expect_out "bin/deck-peek app-job"
  expect_status app-job starting
  expect_eq "$(job_value app-job pane)" block:1 "block recorded"
  expect_not_called "block.event"
  run spawn app-job --resume
  expect_refused "still at a dialog"
  rex_state app-job idle
  run spawn app-job --resume; expect_ok "resume"
  expect_status app-job running
  expect_eq "$(grep -c 'rex window new' "$T/calls.log")" 1 "tabs opened"
  expect_called "Read your brief"
}

test_spawn_harness_exits_at_start() {
  use_rex
  ready_job
  echo exited >"$T/rex/start-state"
  run spawn app-job
  expect_refused "claude failed to start in Rex"
  expect_called "rex window close -s session:op window:1"
  expect_eq "$(job_value app-job pane)" "" "pane cleared"
  echo idle >"$T/rex/start-state"
  run spawn app-job --resume; expect_ok "resume"
  expect_status app-job running
  expect_eq "$(job_value app-job pane)" block:2 "new block"
}

test_spawn_groups_tab_after_operator() {
  use_rex
  export REX_BLOCK=block:7
  # The operator's own tab, then an unrelated one.
  echo deck >"$T/rex/windows/7"; echo idle >"$T/rex/blocks/7"
  echo 8 >"$T/rex/counter"
  echo notes >"$T/rex/windows/8"; echo idle >"$T/rex/blocks/8"
  ready_job
  run spawn app-job; expect_ok "spawn"
  expect_called "rex api call -s session:op session.move_window -"
  expect_called '{"window_id":"window:9","before_window_id":"window:8"}'
}

# ---------------------------------------------------------------- tell

test_tell_pastes_message() {
  spawned_job
  run tell app-job "use sqlite"; expect_ok "tell"
  expect_called '"type":"paste","payload":{"text":"Message from deck: use sqlite"}'
  expect_called "rex send-key -s session:op -b block:1 enter"
  expect_out "told app-job"
}

test_tell_refused_at_dialog() {
  spawned_job
  rex_state app-job blocked:permission
  run tell app-job "use sqlite"
  expect_refused "is at a dialog; read it with: bin/deck-peek app-job"
  expect_not_called "block.event"
}

test_tell_refused_when_gone() {
  spawned_job
  rex_state app-job exited
  run tell app-job "use sqlite"
  expect_refused "could not reach worker app-job (agent_not_found)"
}

test_tell_reopens_review_job() {
  spawned_job
  deck report app-job done "branch ready" >/dev/null
  deck wait --once >/dev/null
  expect_status app-job review
  rex_state app-job done
  run tell app-job "rename the flag"; expect_ok "tell"
  expect_out "app-job: review -> running"
}

test_interrupt_sends_esc_when_working() {
  spawned_job
  export DECK_INTERRUPT_SETTLE=0
  rex_state app-job working
  run tell app-job --interrupt "stop and rethink"; expect_ok "interrupt"
  expect_called "rex send-key -s session:op -b block:1 esc"
  expect_called "Message from deck: stop and rethink"
  expect_out "interrupted and told app-job"
}

test_interrupt_skipped_when_idle() {
  spawned_job
  run tell app-job --interrupt; expect_ok "interrupt"
  expect_out "worker app-job is idle, not mid-turn"
  expect_not_called "send-key -s session:op -b block:1 esc"
}

test_interrupt_refused_at_dialog() {
  spawned_job
  rex_state app-job blocked:question
  run tell app-job --interrupt
  expect_refused "is at a dialog, and esc could answer it"
}

# ---------------------------------------------------------------- wait

test_wait_working_no_event() {
  spawned_job
  rex_state app-job working
  run wait --once
  expect_eq "$OUT" "no events" "wait"
}

test_wait_silent_harness_no_event() {
  spawned_job
  rex_state app-job silent    # codex, grok: alive, no reports
  run wait --once
  expect_eq "$OUT" "no events" "wait"
}

test_wait_idle_once() {
  spawned_job
  rex_state app-job done
  run wait --once
  expect_eq "$OUT" "app-job idle worker stopped without reporting" "first wait"
  run wait --once
  expect_eq "$OUT" "no events" "second wait"
}

test_wait_dialog_once() {
  spawned_job
  rex_state app-job blocked:permission
  run wait --once
  expect_eq "$OUT" "app-job dialog worker is waiting at an approval or question dialog" "first wait"
  run wait --once
  expect_eq "$OUT" "no events" "second wait"
  expect_not_called "herdr notification"
}

test_wait_error_counts_as_stopped() {
  spawned_job
  rex_state app-job error
  run wait --once
  expect_eq "$OUT" "app-job idle worker stopped without reporting" "wait"
}

test_wait_gone_when_program_exits() {
  spawned_job
  rex_state app-job exited
  run wait --once
  expect_eq "$OUT" "app-job gone worker agent is no longer running" "wait"
  expect_status app-job gone
}

test_wait_gone_when_tab_closed() {
  spawned_job
  rm -f "$T/rex/blocks/1" "$T/rex/windows/1"
  run wait --once
  expect_eq "$OUT" "app-job gone worker agent is no longer running" "wait"
}

test_wait_reports_before_state() {
  spawned_job
  deck report app-job blocked "which database?" >/dev/null
  run wait --once
  expect_eq "$OUT" "app-job blocked which database?" "wait"
  expect_status app-job blocked
}

# ---------------------------------------------------------------- peek, sitrep

test_peek_reads_tab() {
  spawned_job
  run peek app-job --lines 1; expect_ok "peek"
  expect_eq "$OUT" "last line" "peek"
  expect_called "rex capture -s session:op -b block:1 --trim --unwrap"
}

test_sitrep_shows_rex_state() {
  spawned_job
  rex_state app-job working
  run sitrep; expect_ok "sitrep"
  expect_out "(rex: working)"
}

# ---------------------------------------------------------------- relaunch

test_relaunch_opens_new_tab_and_closes_old() {
  spawned_job
  rex_state app-job exited
  deck wait --once >/dev/null
  expect_status app-job gone
  run spawn app-job --relaunch --note "tests were half done"; expect_ok "relaunch"
  expect_called "rex window close -s session:op window:1"
  expect_eq "$(job_value app-job workspace)" window:2 "new tab"
  expect_eq "$(job_value app-job pane)" block:2 "new block"
  expect_status app-job running
  expect_called "rex send-key -s session:op -b block:2 enter"
  expect_called "tests were half done"
}

test_relaunch_refused_while_alive() {
  spawned_job
  run spawn app-job --relaunch
  expect_refused "a live agent still owns job app-job in Rex"
}

# ---------------------------------------------------------------- teardown

test_teardown_closes_own_tab() {
  spawned_job
  deck job set app-job status review
  run teardown app-job --discard; expect_ok "teardown"
  expect_called "rex window close -s session:op window:1"
}

test_teardown_leaves_relabelled_tab() {
  spawned_job
  echo "my notes" >"$T/rex/windows/1"
  run teardown app-job --discard; expect_ok "teardown"
  expect_out "Rex tab window:1 is now labelled 'my notes'"
  expect_not_called "rex window close"
}

# ---------------------------------------------------------------- doctor, launch, trial

test_doctor_rex() {
  use_rex
  run doctor
  expect_out "OK    multiplexer: rex"
  expect_out "OK    rex 0.1.0-preview.15 (API revision 13), server running"
  expect_out "OK    running inside Rex (session session:op)"
  case $OUT in *herdr*) fail "doctor mentioned herdr under rex: $OUT" ;; esac
}

test_doctor_rex_missing() {
  printf 'mux=rex\n' >>"$DECK/config/deck.conf"
  rm "$T/stubs/rex"
  run doctor
  expect_out "FAIL  rex is not installed"
  expect_out "FAIL  not running inside Rex"
}

test_launch_inside_rex_opens_deck_tab() {
  use_rex
  run launch </dev/null; expect_ok "launch"
  expect_called "rex window new -s session:op deck"
  expect_out "ready: the 'deck' tab in this Rex session"
  expect_not_called "herdr "
}

test_trial_seeds_separate_home() {
  # A "main" deck home to copy from.
  main=$T/main
  mkdir -p "$main/config" "$main/data/projects" "$main/data/engrams" "$main/data/jobs/old-job"
  printf 'client_name=tester\nworker_harness=claude\nmux=herdr\nherdr_session=deck\nonboarded=no\n' >"$main/config/deck.conf"
  echo "name=app" >"$main/data/projects/app.conf"
  echo "likes tea" >"$main/data/profile.md"
  echo "job" >"$main/data/jobs/old-job/job.conf"
  rm -f "$DECK/config/deck.conf"
  run trial --from "$main"; expect_ok "trial"
  c=$DECK/config/deck.conf
  expect_eq "$(conf_value "$c" mux)" rex "mux"
  expect_eq "$(conf_value "$c" onboarded)" yes "onboarded"
  expect_eq "$(conf_value "$c" herdr_session)" deck-trial "herdr session"
  expect_eq "$(conf_value "$c" rex_session)" deck-trial "rex session"
  expect_eq "$(conf_value "$c" client_name)" tester "copied key"
  [ -f "$DECK/data/projects/app.conf" ] || fail "project not copied"
  [ -f "$DECK/data/profile.md" ] || fail "profile not copied"
  [ ! -e "$DECK/data/jobs/old-job" ] || fail "a job was copied"
  [ -f "$DECK/state/operator-home" ] || fail "no operator-home marker"
  run trial --from "$main"
  expect_refused "already has config/deck.conf"
  run trial --from "$main" --mux herdr --force; expect_ok "reseed"
  expect_eq "$(conf_value "$c" mux)" herdr "mux after reseed"
}

test_turnend_guard_honours_trial_marker() {
  # A linked-worktree home with a live job and no watcher.
  printf 'gitdir: /elsewhere\n' >"$DECK/.git"
  mkdir -p "$DECK/data/jobs/live"; printf 'status=running\n' >"$DECK/data/jobs/live/job.conf"
  out=$(echo '{"stop_hook_active":false}' | "$DECK/bin/deck-turnend-guard")
  expect_eq "$out" "" "unmarked linked worktree allows"
  : >"$DECK/state/operator-home"
  out=$(echo '{"stop_hook_active":false}' | "$DECK/bin/deck-turnend-guard")
  case $out in *'"decision":"block"'*) ;; *) fail "marked trial home should block, got: $out" ;; esac
}

run_tests "${1:-}"
