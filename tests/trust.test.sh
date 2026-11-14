#!/usr/bin/env bash
# deck-trust: the read-only check, and --grant only with the user's word.
. "$(dirname "$0")/lib.sh"

claude_json() { printf '%s\n' "$HOME/.claude.json"; }

test_check_reports_untrusted() {
  make_project app local
  echo '{"projects":{}}' >"$(claude_json)"
  run trust app --harness claude --check
  expect_eq "$rc" 1 "exit code"
  expect_out "app is NOT trusted by claude (run: bin/deck-trust app --grant --harness claude)"
  expect_eq "$(cat "$(claude_json)")" '{"projects":{}}' "claude.json"
}

test_check_reports_trusted() {
  make_project app local
  trust_claude app
  run trust app --harness claude --check; expect_ok "check"
  expect_out "app is trusted by claude"
}

test_check_all() {
  make_project app local
  make_project lib local
  trust_claude app
  run trust --all --harness claude --check
  expect_eq "$rc" 1 "exit code"
  expect_out "lib is NOT trusted"
  case $OUT in *"app is NOT"*) fail "app is trusted but was reported: $OUT" ;; esac
}

test_yes_requires_grant() {
  make_project app local
  run trust app --harness claude --yes
  expect_refused "--yes only goes with --grant"
}

test_check_and_grant_dont_mix() {
  make_project app local
  run trust app --harness claude --check --grant
  expect_refused "--check and --grant don't mix"
}

test_grant_refuses_without_yes_or_terminal() {
  make_project app local
  echo '{"projects":{}}' >"$(claude_json)"
  run trust app --harness claude --grant   # run() feeds stdin from /dev/null
  expect_refused "--grant needs the user's yes"
  expect_eq "$(cat "$(claude_json)")" '{"projects":{}}' "claude.json"
}

test_grant_yes_writes_only_the_trust_key() {
  make_project app local
  p=$(project_path app)
  echo '{"theme":"dark","projects":{"/other":{"hasTrustDialogAccepted":false}}}' >"$(claude_json)"
  run trust app --harness claude --grant --yes; expect_ok "grant"
  expect_out "app is trusted by claude"
  expect_eq "$(jq -r --arg p "$p" '.projects[$p].hasTrustDialogAccepted' "$(claude_json)")" true "trust key"
  expect_eq "$(jq -r '.theme' "$(claude_json)")" dark "other keys"
  expect_eq "$(jq -r '.projects["/other"].hasTrustDialogAccepted' "$(claude_json)")" false "other project"
  [ -f "$(claude_json).deck-bak" ] || fail "no backup written"
}

test_grant_refuses_unregistered_path() {
  mkdir -p "$T/loose"; git -C "$T/loose" init --quiet
  echo '{"projects":{}}' >"$(claude_json)"
  run trust --path "$T/loose" --harness claude --grant --yes
  expect_refused "--grant only trusts registered projects"
}

test_grant_refuses_missing_claude_config() {
  make_project app local
  run trust app --harness claude --grant --yes
  expect_refused "run claude once first"
  [ ! -f "$(claude_json)" ] || fail "claude.json was created"
}

test_grant_refuses_grok() {
  make_project app local
  run trust app --harness grok --grant --yes
  expect_refused "doesn't know Grok's trusted_folders.toml format"
}

run_tests "${1:-}"
