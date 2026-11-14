#!/usr/bin/env bash
# Pi as the operator: launch, trust, doctor, deck-allow, refusing Pi workers,
# and the Pi extension (.pi/extensions/deck-operator.ts, driven through node).
. "$(dirname "$0")/lib.sh"

pi_dir() { printf '%s\n' "$HOME/.pi/agent"; }
pi_trust() { printf '%s\n' "$(pi_dir)/trust.json"; }

use_pi_operator() {
  printf 'deck_harness=pi\n' >>"$DECK/config/deck.conf"
  printf '#!/bin/bash\nprintf "pi %%s\\n" "$*" >>"$STUB_DIR/calls.log"\n[ "${1:-}" != --version ] || echo 1.5.2\nexit 0\n' >"$T/stubs/pi"
  chmod +x "$T/stubs/pi"
}

# ---------------------------------------------------------------- launch

test_launch_starts_pi_operator_and_greets_it() {
  use_pi_operator
  DECK_LAUNCH_NO_ATTACH=1 run launch; expect_ok "launch"
  expect_out "starting Herdr session 'deck' and pi"
  expect_called "herdr --session deck agent start deck --kind pi --pane pane-1"
  # The greeting goes out from the background once the operator is idle.
  i=0
  until grep -qF "herdr --session deck agent prompt deck jacking in" "$T/calls.log"; do
    i=$((i + 1)); [ $i -lt 50 ] || fail "greeting never sent; calls: $(cat "$T/calls.log")"
    sleep 0.1
  done
}

test_launch_refuses_unknown_operator_harness() {
  printf 'deck_harness=bogus\n' >>"$DECK/config/deck.conf"
  DECK_LAUNCH_NO_ATTACH=1 run launch
  expect_refused "deck_harness=bogus"
  expect_not_called "agent start"
}

# ---------------------------------------------------------------- trust

test_trust_check_pi_reads_closest_decision() {
  make_project app local
  p=$(project_path app)
  mkdir -p "$(pi_dir)"
  printf '{"%s": true}\n' "$(dirname "$p")" >"$(pi_trust)"
  run trust app --harness pi --check; expect_ok "check via a trusted ancestor"
  expect_out "app is trusted by pi"
  printf '{"%s": true, "%s": false}\n' "$(dirname "$p")" "$p" >"$(pi_trust)"
  run trust app --harness pi --check
  expect_eq "$rc" 1 "exit code with a closer untrusted decision"
  expect_out "app is NOT trusted by pi (run: bin/deck-trust app --grant --harness pi)"
}

test_trust_grant_pi_writes_only_the_trust_key() {
  make_project app local
  p=$(project_path app)
  mkdir -p "$(pi_dir)"
  echo '{"/elsewhere": true, "/nope": false}' >"$(pi_trust)"
  run trust app --harness pi --grant --yes; expect_ok "grant"
  expect_out "app is trusted by pi"
  expect_eq "$(jq -r --arg p "$p" '.[$p]' "$(pi_trust)")" true "trust key"
  expect_eq "$(jq -c 'del(.[$p])' --arg p "$p" "$(pi_trust)")" '{"/elsewhere":true,"/nope":false}' "other keys"
  [ -f "$(pi_trust).deck-bak" ] || fail "no backup written"
}

test_trust_grant_pi_creates_the_file() {
  make_project app local
  mkdir -p "$(pi_dir)"
  run trust app --harness pi --grant --yes; expect_ok "grant"
  expect_eq "$(jq -r --arg p "$(project_path app)" '.[$p]' "$(pi_trust)")" true "trust key"
}

test_trust_grant_pi_keeps_an_untrusted_decision() {
  make_project app local
  mkdir -p "$(pi_dir)"
  printf '{"%s": false}\n' "$(project_path app)" >"$(pi_trust)"
  run trust app --harness pi --grant --yes
  expect_refused "already has a decision"
  expect_eq "$(jq -r --arg p "$(project_path app)" '.[$p]' "$(pi_trust)")" false "decision"
}

test_trust_grant_pi_refuses_without_pi_config() {
  make_project app local
  run trust app --harness pi --grant --yes
  expect_refused "run pi once first"
  [ ! -e "$(pi_dir)" ] || fail "$(pi_dir) was created"
}

# ---------------------------------------------------------------- doctor

test_doctor_warns_about_pi_trust_and_integration() {
  use_pi_operator
  run doctor --brief
  expect_out "WARN  pi doesn't trust $DECK"
  expect_out "WARN  Herdr's Pi integration isn't installed"
  expect_out "herdr integration install pi"
}

test_doctor_passes_pi_checks() {
  use_pi_operator
  mkdir -p "$(pi_dir)"
  printf '{"%s": true}\n' "$DECK" >"$(pi_trust)"
  echo "pi: current (v1) (~/.pi/agent/extensions/herdr-agent-state.ts)" >"$T/herdr/integrations"
  run doctor
  expect_out "OK    pi 1.5.2"
  expect_out "OK    pi trusts the deck folder"
  expect_out "OK    Herdr's Pi integration is installed"
}

test_doctor_fails_when_pi_operator_is_missing() {
  printf 'deck_harness=pi\n' >>"$DECK/config/deck.conf"
  run doctor --brief
  expect_out "FAIL  the operator harness is pi, but pi is not installed"
}

test_doctor_skips_pi_checks_for_claude_operator() {
  run doctor
  case $OUT in *"pi trusts"*|*"Pi integration"*) fail "pi checks ran for a claude operator: $OUT" ;; esac
}

# ---------------------------------------------------------------- workers, deck-allow

test_job_refuses_pi_worker() {
  make_project app local
  run job new app-job --project app --kind gig --harness pi
  expect_refused "pi runs the operator only for now"
  [ ! -d "$DECK/data/jobs/app-job" ] || fail "job was created"
}

test_spawn_refuses_pi_worker() {
  make_project app local
  deck job new app-job --project app --kind gig >/dev/null
  fill_brief app-job
  deck job set app-job harness pi
  HERDR_ENV=1 run spawn app-job
  expect_refused "can't run a worker"
  expect_not_called "agent start"
}

test_allow_is_a_no_op_on_pi() {
  use_pi_operator
  run allow; expect_ok "allow"
  expect_out "nothing to do on Pi"
  [ ! -e "$DECK/.claude/settings.local.json" ] || fail "settings.local.json was written"
}

# ---------------------------------------------------------------- the extension

test_extension() {
  command -v node >/dev/null 2>&1 || skip "node is not installed"
  node -e 'process.exit(process.features.typescript ? 0 : 1)' 2>/dev/null ||
    skip "this node can't load TypeScript directly (needs 22.18+)"
  mkdir -p "$DECK/.pi/extensions"
  cp "$DECK_SRC/.pi/extensions/deck-operator.ts" "$DECK/.pi/extensions/"
  NODE_NO_WARNINGS=1 node "$DECK_SRC/tests/pi-operator.test.mjs" "$DECK" "$T" >"$T/out" 2>&1 || fail "$(cat "$T/out")"
}

run_tests "${1:-}"
