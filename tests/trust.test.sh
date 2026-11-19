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

# ---------------------------------------------------------------- --revoke

test_revoke_and_grant_dont_mix() {
  make_project app local
  run trust app --harness claude --grant --revoke --yes
  expect_refused "--grant and --revoke don't mix"
}

test_revoke_refuses_all() {
  make_project app local
  run trust --all --harness claude --revoke --yes
  expect_refused "--revoke takes one project or --path, not --all"
}

test_revoke_refuses_without_yes_or_terminal() {
  make_project app local
  trust_claude app
  before=$(cat "$(claude_json)")
  run trust app --harness claude --revoke   # run() feeds stdin from /dev/null
  expect_refused "--revoke needs the user's yes"
  expect_eq "$(cat "$(claude_json)")" "$before" "claude.json"
}

test_revoke_check_reports_only() {
  make_project app local
  trust_claude app
  before=$(cat "$(claude_json)")
  run trust app --harness claude --revoke --check; expect_ok "check"
  expect_out "app is trusted by claude (--revoke would remove it)"
  expect_eq "$(cat "$(claude_json)")" "$before" "claude.json"
  [ ! -f "$(claude_json).deck-bak" ] || fail "backup written by a check"
}

test_revoke_untrusted_changes_nothing() {
  make_project app local
  p=$(project_path app)
  printf '{"projects":{"%s":{"hasTrustDialogAccepted":false}}}\n' "$p" >"$(claude_json)"
  before=$(cat "$(claude_json)")
  run trust app --harness claude --revoke --yes; expect_ok "revoke"
  expect_out "app is not trusted by claude; nothing to revoke"
  expect_eq "$(cat "$(claude_json)")" "$before" "claude.json"
}

test_revoke_refuses_grok() {
  make_project app local
  mkdir -p "$HOME/.grok"
  printf '"%s" = true\n' "$(project_path app)" >"$HOME/.grok/trusted_folders.toml"
  run trust app --harness grok --revoke --yes
  expect_refused "doesn't know Grok's trusted_folders.toml format"
  expect_eq "$(cat "$HOME/.grok/trusted_folders.toml")" "\"$(project_path app)\" = true" "grok store"
}

test_claude_grant_then_revoke_restores_config() {
  make_project app local
  echo '{"theme":"dark","projects":{"/other":{"hasTrustDialogAccepted":true}}}' | jq . >"$(claude_json)"
  before=$(jq -S . "$(claude_json)")
  run trust app --harness claude --grant --yes; expect_ok "grant"
  run trust app --harness claude --revoke --yes; expect_ok "revoke"
  expect_out "app is no longer trusted by claude"
  expect_eq "$(jq -S . "$(claude_json)")" "$before" "claude.json"
  [ -f "$(claude_json).deck-bak" ] || fail "no backup written"
}

test_claude_revoke_keeps_the_folder_entry() {
  make_project app local
  p=$(project_path app)
  printf '{"projects":{"%s":{"hasTrustDialogAccepted":true,"allowedTools":["Bash"]}}}\n' "$p" >"$(claude_json)"
  run trust app --harness claude --revoke --yes; expect_ok "revoke"
  expect_eq "$(jq -c --arg p "$p" '.projects[$p]' "$(claude_json)")" '{"allowedTools":["Bash"]}' "folder entry"
}

test_codex_grant_then_revoke_restores_config() {
  make_project app local
  mkdir -p "$HOME/.codex"
  printf 'model = "o3"\n\n[projects."/other"]\ntrust_level = "trusted"\n' >"$HOME/.codex/config.toml"
  before=$(cat "$HOME/.codex/config.toml")
  run trust app --harness codex --grant --yes; expect_ok "grant"
  run trust app --harness codex --revoke --yes; expect_ok "revoke"
  expect_out "app is no longer trusted by codex"
  expect_eq "$(cat "$HOME/.codex/config.toml")" "$before" "config.toml"
}

test_pi_grant_then_revoke_restores_config() {
  make_project app local
  mkdir -p "$HOME/.pi/agent"
  echo '{"/other":true}' >"$HOME/.pi/agent/trust.json"
  before=$(jq -S . "$HOME/.pi/agent/trust.json")
  run trust app --harness pi --grant --yes; expect_ok "grant"
  run trust app --harness pi --revoke --yes; expect_ok "revoke"
  expect_eq "$(jq -S . "$HOME/.pi/agent/trust.json")" "$before" "trust.json"
}

test_pi_revoke_refuses_parent_folder_trust() {
  make_project app local
  mkdir -p "$HOME/.pi/agent"
  printf '{"%s":true}\n' "$T/src" >"$HOME/.pi/agent/trust.json"
  before=$(cat "$HOME/.pi/agent/trust.json")
  run trust app --harness pi --revoke --yes
  expect_refused "through a parent folder's record"
  expect_eq "$(cat "$HOME/.pi/agent/trust.json")" "$before" "trust.json"
}

test_revoke_by_path_after_remove() {
  make_project app local
  p=$(project_path app)
  trust_claude app
  run project remove app; expect_ok "remove"
  run trust --path "$p" --harness claude --revoke --yes; expect_ok "revoke"
  expect_eq "$(jq -c '.projects' "$(claude_json)")" '{}' "projects"
}

run_tests "${1:-}"
