#!/usr/bin/env bash
# deck-project remove: deregister only, never while jobs are open, never deck.
. "$(dirname "$0")/lib.sh"

test_remove_deregisters_and_keeps_files() {
  make_project app local
  p=$(project_path app)
  run project remove app; expect_ok "remove"
  expect_out "removed app"
  [ ! -f "$DECK/data/projects/app.conf" ] || fail "project record still there"
  [ -f "$p/README.md" ] || fail "project files were touched"
}

test_remove_unknown_project() {
  run project remove nope
  expect_refused "no such project: nope"
}

test_remove_refuses_unfinished_jobs() {
  make_project app local
  deck job new app-a --project app --kind gig >/dev/null
  deck job new app-b --project app --kind gig >/dev/null
  deck job set app-b status review
  run project remove app
  expect_refused "unfinished jobs: app-a(queued) app-b(review)"
  [ -f "$DECK/data/projects/app.conf" ] || fail "project record was removed"
}

test_remove_allows_finished_jobs() {
  make_project app local
  make_project lib local
  for s in landed closed cancelled; do
    deck job new "app-$s" --project app --kind gig >/dev/null
    deck job set "app-$s" status "$s"
  done
  deck job new lib-a --project lib --kind gig >/dev/null
  run project remove app; expect_ok "remove"
}

test_remove_refuses_deck_itself() {
  make_project deck local
  run project remove deck
  expect_refused "deck itself"
  [ -f "$DECK/data/projects/deck.conf" ] || fail "deck's record was removed"
}

test_remove_keeps_a_clone_and_says_where() {
  make_project app local
  deck project add "file://$(project_path app)" --name clone --mode local >/dev/null
  run project remove clone; expect_ok "remove"
  expect_out "deck cloned it there; delete $DECK/projects/clone yourself"
  [ -d "$DECK/projects/clone/.git" ] || fail "clone was deleted"
}

test_remove_mentions_remaining_trust() {
  make_project app local
  trust_claude app
  run project remove app; expect_ok "remove"
  expect_out "still trusted by: claude"
  expect_out "--revoke"
}

run_tests "${1:-}"
