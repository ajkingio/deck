#!/usr/bin/env bash
# Pi as the operator and as a worker: launch, trust, doctor, deck-allow, spawn,
# relaunch and interrupt for Pi workers, and the Pi extension
# (.pi/extensions/deck-operator.ts, driven through node).
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

# ---------------------------------------------------------------- workers

PI_HELP='Options:
  --model <pattern>              Model pattern or ID
  --append-system-prompt <text>  Append text or file contents to the system prompt
  --name, -n <name>              Set session display name
  --thinking <level>             Set thinking level
  --approve, -a                  Trust project-local files for this run
  --no-approve, -na              Ignore project-local files for this run'

# A pi stub that answers --help with $STUB_DIR/pi-help (default: $PI_HELP).
use_pi_stub() {
  printf '%s\n' "$PI_HELP" >"$T/pi-help"
  cat >"$T/stubs/pi" <<'EOF2'
#!/bin/bash
printf 'pi %s\n' "$*" >>"$STUB_DIR/calls.log"
case ${1:-} in
  --help) cat "$STUB_DIR/pi-help" ;;
  --version) echo 1.5.2 ;;
esac
exit 0
EOF2
  chmod +x "$T/stubs/pi"
}

# A queued pi job on project <name> (default app), trusted by pi unless told not to.
pi_job() { # [project] [untrusted]
  local proj=${1:-app}
  use_pi_stub
  [ -f "$DECK/data/projects/$proj.conf" ] || make_project "$proj" local
  if [ "${2:-}" != untrusted ]; then
    mkdir -p "$(pi_dir)"
    printf '{"%s": true}\n' "$(project_path "$proj")" >"$(pi_trust)"
  fi
  deck job new app-job --project "$proj" --kind gig --harness pi >/dev/null || fail "deck-job refused a pi worker"
  fill_brief app-job
  export HERDR_ENV=1
}

pi_start_args() { # the arguments deck passed to pi through herdr agent start
  grep -F "herdr agent start app-job --kind pi" "$T/calls.log" | tail -n1 | sed 's/.* -- //'
}

test_job_accepts_pi_worker() {
  make_project app local
  run job new app-job --project app --kind gig --harness pi; expect_ok "job new"
  expect_eq "$(job_value app-job harness)" pi "harness"
}

test_spawn_starts_pi_worker() {
  pi_job
  run spawn app-job; expect_ok "spawn"
  expect_status app-job running
  expect_called "herdr agent start app-job --kind pi --pane pane-1"
  expect_eq "$(pi_start_args)" "--append-system-prompt $DECK/templates/worker-system.md --name app-job --approve" "pi arguments"
  expect_called "--env DECK_JOB=app-job"
  expect_called "herdr agent prompt app-job You are worker app-job"
}

test_spawn_passes_pi_model_and_thinking() {
  pi_job
  printf 'pi_worker_model=anthropic/claude-sonnet-5-5\npi_worker_thinking=high\n' >>"$DECK/config/deck.conf"
  run spawn app-job; expect_ok "spawn"
  expect_eq "$(pi_start_args)" "--append-system-prompt $DECK/templates/worker-system.md --name app-job --approve --model anthropic/claude-sonnet-5-5 --thinking high" "pi arguments"
}

test_spawn_refuses_untrusted_pi_project() {
  pi_job app untrusted
  run spawn app-job
  expect_refused "bin/deck-trust app --grant --harness pi"
  expect_status app-job queued
  [ ! -e "$(job_value app-job worktree)" ] || fail "a worktree was created"
  expect_not_called "agent start"
  # A trusted ancestor with a closer untrusted decision is still untrusted.
  mkdir -p "$(pi_dir)"
  printf '{"%s": true, "%s": false}\n' "$(dirname "$(project_path app)")" "$(project_path app)" >"$(pi_trust)"
  run spawn app-job
  expect_refused "doesn't trust project app"
  expect_not_called "agent start"
}

test_spawn_writes_no_worktree_trust() {
  pi_job
  before=$(cat "$(pi_trust)")
  run spawn app-job; expect_ok "spawn"
  expect_eq "$(cat "$(pi_trust)")" "$before" "trust.json"
}

test_spawn_refuses_pi_without_needed_flags() {
  pi_job
  printf '%s\n' "$PI_HELP" | grep -v -- --approve >"$T/pi-help"
  run spawn app-job
  expect_refused "doesn't support --approve"
  [ ! -e "$(job_value app-job worktree)" ] || fail "a worktree was created"
  printf '%s\n' "$PI_HELP" | grep -v -- --thinking >"$T/pi-help"
  printf 'pi_worker_thinking=high\n' >>"$DECK/config/deck.conf"
  run spawn app-job
  expect_refused "doesn't support --thinking"
  expect_not_called "agent start"
}

test_relaunch_pi_worker() {
  pi_job
  deck spawn app-job >/dev/null 2>&1 || fail "initial spawn failed"
  rm "$T/herdr/agents/app-job"
  deck wait --once >/dev/null
  expect_status app-job gone
  : >"$T/calls.log"
  run spawn app-job --relaunch --note "half done"; expect_ok "relaunch"
  expect_status app-job running
  expect_eq "$(pi_start_args)" "--append-system-prompt $DECK/templates/worker-system.md --name app-job --approve" "pi arguments"
  expect_called "You were relaunched"
}

test_interrupt_pi_worker_sends_escape() {
  pi_job
  deck spawn app-job >/dev/null 2>&1 || fail "spawn failed"
  : >"$T/calls.log"
  export DECK_INTERRUPT_SETTLE=0
  run tell app-job --interrupt "stop and rerun the tests"; expect_ok "interrupt"
  expect_called "herdr agent send-keys app-job esc"
  expect_called "Message from deck: stop and rerun the tests"
}

test_doctor_checks_pi_worker_trust() {
  use_pi_stub
  make_project app local
  printf 'worker_harness=pi\n' >>"$DECK/config/deck.conf"
  run doctor --brief
  expect_out "WARN  project app: not trusted by pi yet; workers can't start there (bin/deck-trust app --grant --harness pi)"
  expect_out "WARN  Herdr's Pi integration isn't installed"
  case $OUT in *"deck's Pi extension"*) fail "operator-only pi check ran for pi workers: $OUT" ;; esac
  mkdir -p "$(pi_dir)"
  printf '{"%s": true}\n' "$(project_path app)" >"$(pi_trust)"
  run doctor
  expect_out "OK    project app: trusted by pi"
  expect_out "OK    worker harness: pi"
}

# A Pi worker on the deck project runs with --approve in a linked worktree of
# deck, so Pi loads deck's own extension there. It must register nothing.
test_extension_inert_for_pi_worker_on_deck() {
  command -v node >/dev/null 2>&1 || skip "node is not installed"
  node -e 'process.exit(process.features.typescript ? 0 : 1)' 2>/dev/null ||
    skip "this node can't load TypeScript directly (needs 22.18+)"
  src="$T/src/deck"
  mkdir -p "$src/.pi/extensions" "$src/data/jobs"
  cp "$DECK_SRC/.pi/extensions/deck-operator.ts" "$src/.pi/extensions/"
  printf 'data/\n' >"$src/.gitignore"
  git -C "$src" init --quiet
  git -C "$src" add .gitignore .pi
  git -C "$src" commit --quiet -m "deck"
  deck project add "$src" --name deck --mode local --base main >/dev/null
  pi_job deck
  run spawn app-job; expect_ok "spawn"
  wt=$(job_value app-job worktree)
  ext="$wt/.pi/extensions/deck-operator.ts"
  [ -f "$ext" ] || fail "the worktree has no extension to test: $ext"
  # The operator's own checkout activates it; the worker's worktree must not.
  cat >"$T/inert.mjs" <<'EOF2'
import { pathToFileURL } from "node:url";
const [file] = process.argv.slice(2);
const m = await import(pathToFileURL(file).href);
const handlers = [];
m.default({ on: (name) => handlers.push(name), sendUserMessage: async () => {} });
console.log(handlers.length);
EOF2
  n=$(NODE_NO_WARNINGS=1 node "$T/inert.mjs" "$ext" 2>&1) || fail "node failed: $n"
  expect_eq "$n" 0 "handlers registered in the worker's worktree"
  n=$(NODE_NO_WARNINGS=1 node "$T/inert.mjs" "$src/.pi/extensions/deck-operator.ts" 2>&1) || fail "node failed: $n"
  [ "$n" -gt 0 ] || fail "the extension registered nothing in the operator's checkout either; the test proves nothing"
}

# ---------------------------------------------------------------- deck-allow

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
