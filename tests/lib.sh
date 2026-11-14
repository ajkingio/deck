# Test helpers for deck's behaviour tests. Source this from tests/<name>.test.sh.
# Written for the bash 3.2 that ships with macOS: no associative arrays, no mapfile.
#
# Each test is a function named test_<name>. run_tests runs every one in its own
# subshell with a fresh sandbox:
#   $T        the sandbox root (a temp dir, removed afterwards)
#   $DECK     a deck home: copies of the repo's bin/ and templates/, empty config/ data/ state/
#   HOME      $T/home, with its own .gitconfig
#   PATH      $T/stubs (herdr, gh, glab, claude) + $T/tools (git, jq) + the system dirs
# The stubs return canned output and append each call to $T/calls.log. Nothing
# reaches the real ~/.deck, the real Herdr session, the user's config, or the network.

set -u

DECK_SRC=${DECK_TEST_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}

# ---------------------------------------------------------------- sandbox

sandbox() {
  local v tool
  # Forget anything that could point at the real deck, Herdr, harness or git config.
  for v in $(env | sed -n 's/^\(HERDR_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(DECK_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(FIXER_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do
    case $v in DECK_TEST_SRC|DECK_SRC) ;; *) unset "$v" ;; esac
  done
  unset CLAUDE_CONFIG_DIR CODEX_HOME GROK_HOME TMUX

  T=$(mktemp -d "${TMPDIR:-/tmp}/deck-test.XXXXXX") || exit 1
  T=$(cd "$T" && pwd -P)
  DECK=$T/deck
  mkdir -p "$DECK/config" "$DECK/data/jobs" "$DECK/data/projects" "$DECK/state" \
    "$T/home" "$T/stubs" "$T/tools" "$T/worktrees" "$T/herdr/agents" "$T/forge"
  cp -R "$DECK_SRC/bin" "$DECK/bin"
  cp -R "$DECK_SRC/templates" "$DECK/templates"
  printf 'client_name=tester\nworker_harness=claude\nnotify=on\n' >"$DECK/config/deck.conf"
  : >"$T/calls.log"

  for tool in git jq; do
    v=$(command -v "$tool") || { echo "deck-test: $tool is required" >&2; exit 1; }
    ln -s "$v" "$T/tools/$tool"
  done
  write_stubs

  export HOME="$T/home"
  export PATH="$T/stubs:$T/tools:/usr/bin:/bin:/usr/sbin:/sbin"
  export DECK_WORKTREES="$T/worktrees"
  export DECK_WAIT_INTERVAL=1
  export STUB_DIR="$T"
  export GIT_CONFIG_NOSYSTEM=1
  git config --global user.name "deck test"
  git config --global user.email "test@example.invalid"
  git config --global init.defaultBranch main
  git config --global commit.gpgsign false
  git config --global advice.detachedHead false
}

cleanup_sandbox() {
  case ${T:-} in */deck-test.*) rm -rf "$T" ;; esac
}

# Stubs read and write state under $STUB_DIR, so a test can set canned answers.
write_stubs() {
  cat >"$T/stubs/herdr" <<'EOF'
#!/bin/bash
# herdr stub. Agents are files under $STUB_DIR/herdr/agents/<name> holding an agent_status.
printf 'herdr %s\n' "$*" >>"$STUB_DIR/calls.log"
a="$STUB_DIR/herdr/agents"
case "$1 $2" in
  "workspace create")
    # Canned ids from $STUB_DIR/herdr/new-workspace ("<ws> <pane>"), else ws-1/pane-1.
    set -- ws-1 pane-1
    [ ! -f "$STUB_DIR/herdr/new-workspace" ] || set -- $(cat "$STUB_DIR/herdr/new-workspace")
    printf '{"result":{"workspace":{"workspace_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$1" "$2" ;;
  "workspace list")
    if [ -f "$STUB_DIR/herdr/workspaces.json" ]; then cat "$STUB_DIR/herdr/workspaces.json"
    else echo '{"result":{"workspaces":[]}}'; fi ;;
  "workspace close") ;;
  "agent start")
    # $STUB_DIR/herdr/start-fails holds an error code to fail with.
    if [ -f "$STUB_DIR/herdr/start-fails" ]; then
      printf '{"error":{"code":"%s"}}\n' "$(cat "$STUB_DIR/herdr/start-fails")"; exit 1
    fi
    echo "working" >"$a/$3" ;;
  "agent send-keys") [ -f "$a/$3" ] || { echo '{"error":{"code":"agent_not_found"}}'; exit 1; } ;;
  "agent get")
    [ -f "$a/$3" ] || { echo '{"error":{"code":"agent_not_found"}}'; exit 1; }
    printf '{"result":{"agent":{"agent":"claude","agent_status":"%s","state_change_seq":1}}}\n' "$(cat "$a/$3")" ;;
  "agent prompt") ;;
  "notification show") ;;
  "pane get")
    # $STUB_DIR/herdr/panes/<pane> holds that pane's workspace id; others are the operator's.
    w=ws-operator
    [ ! -f "$STUB_DIR/herdr/panes/$3" ] || w=$(cat "$STUB_DIR/herdr/panes/$3")
    printf '{"result":{"pane":{"workspace_id":"%s"}}}\n' "$w" ;;
  *) echo "herdr stub: unhandled: $*" >&2; exit 1 ;;
esac
EOF
  cat >"$T/stubs/gh" <<'EOF'
#!/bin/bash
# gh stub. `pr view` prints $STUB_DIR/forge/pr.json, or fails like gh does with no PR.
printf 'gh %s\n' "$*" >>"$STUB_DIR/calls.log"
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr view") [ -f "$STUB_DIR/forge/pr.json" ] || { echo "no pull requests found" >&2; exit 1; }
             cat "$STUB_DIR/forge/pr.json" ;;
  "pr create") echo "https://github.com/example/proj/pull/7" ;;
  "pr merge") [ ! -f "$STUB_DIR/forge/merge-fails" ] || exit 1 ;;
  "repo view") echo '{"squashMergeAllowed":true}' ;;
  *) echo "gh stub: unhandled: $*" >&2; exit 1 ;;
esac
EOF
  cat >"$T/stubs/glab" <<'EOF'
#!/bin/bash
printf 'glab %s\n' "$*" >>"$STUB_DIR/calls.log"
echo "glab stub: not used by these tests" >&2
exit 1
EOF
  cat >"$T/stubs/claude" <<'EOF'
#!/bin/bash
printf 'claude %s\n' "$*" >>"$STUB_DIR/calls.log"
exit 0
EOF
  chmod +x "$T/stubs/"*
}

# Canned `gh pr view` answer. state: OPEN|MERGED|CLOSED; ci: SUCCESS|FAILURE|PENDING|"" (no checks).
forge_pr() { # <state> <ci> [head-sha]
  local checks="[]"
  [ -z "$2" ] || checks="[{\"conclusion\":\"$2\"}]"
  [ "$2" != PENDING ] || checks='[{"state":"PENDING"}]'
  printf '{"state":"%s","url":"https://github.com/example/proj/pull/7","headRefOid":"%s","mergeable":"MERGEABLE","statusCheckRollup":%s}\n' \
    "$1" "${3:-abc123}" "$checks" >"$T/forge/pr.json"
}

# ---------------------------------------------------------------- fixtures

# A throwaway project. local: a plain repo. pr: a repo whose origin is a local
# bare repo (file://, so pushes and fetches work offline), recorded as GitHub.
make_project() { # <name> <local|pr>
  local name=$1 mode=$2 src="$T/src/$1"
  mkdir -p "$src"
  git -C "$src" init --quiet
  echo "# $name" >"$src/README.md"
  git -C "$src" add README.md
  git -C "$src" commit --quiet -m "initial"
  if [ "$mode" = pr ]; then
    git init --quiet --bare "$T/remotes/$name.git"
    git -C "$src" remote add origin "file://$T/remotes/$name.git"
    git -C "$src" push --quiet origin main
    deck project add "$src" --name "$name" --mode pr --forge github --base main >/dev/null
  else
    deck project add "$src" --name "$name" --mode local --base main >/dev/null
  fi
}

project_path() { conf_value "$DECK/data/projects/$1.conf" path; }

# Mark <project> trusted by Claude in the sandbox HOME.
trust_claude() { # <project>
  printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$(project_path "$1")" >"$HOME/.claude.json"
}

# Fill the DECK:FILL markers of a job's brief.
fill_brief() { # <id>
  sed 's/<!-- DECK:FILL[^>]*-->/filled in by the test/' "$DECK/data/jobs/$1/brief.md" >"$T/brief.tmp"
  mv "$T/brief.tmp" "$DECK/data/jobs/$1/brief.md"
}

# A job as if a worker had finished: worktree on deck/<id> with one commit, status review.
# Built without deck-spawn, so it needs no Herdr.
make_review_job() { # <id> <project> [gig|recon]
  local id=$1 project=$2 kind=${3:-gig} wt
  deck job new "$id" --project "$project" --kind "$kind" --harness claude >/dev/null
  wt=$(job_value "$id" worktree)
  mkdir -p "$(dirname "$wt")"
  git -C "$(project_path "$project")" worktree add --quiet -b "deck/$id" "$wt" main
  echo "work for $id" >"$wt/$id.txt"
  git -C "$wt" add "$id.txt"
  git -C "$wt" commit --quiet -m "work for $id"
  deck job set "$id" status review
}

# ---------------------------------------------------------------- running deck

# Run bin/deck-<cmd> from the sandbox. Output goes to $T/out; status to $rc.
deck() { # <cmd> [args...]
  local cmd=$1; shift
  "$DECK/bin/deck-$cmd" "$@"
}

run() { # <cmd> [args...]   capture output and status instead of failing
  local cmd=$1; shift
  rc=0
  "$DECK/bin/deck-$cmd" "$@" >"$T/out" 2>&1 </dev/null || rc=$?
  OUT=$(cat "$T/out")
}

conf_value() { grep -E "^$2=" "$1" 2>/dev/null | tail -n1 | cut -d= -f2-; }
job_value() { conf_value "$DECK/data/jobs/$1/job.conf" "$2"; }

# ---------------------------------------------------------------- assertions

fail() { printf '    %s\n' "$*" >&2; exit 1; }

# Mark the current test as an expected failure (a real bug, recorded for its own fix).
xfail() { printf '    xfail: %s\n' "$*" >&2; exit 78; }
skip() { printf '    skip: %s\n' "$*" >&2; exit 77; }

expect_ok() { # [label]
  [ "$rc" = 0 ] || fail "${1:-command} failed (exit $rc): $OUT"
}
expect_refused() { # <substring of the refusal> [label]
  [ "$rc" != 0 ] || fail "${2:-command} should have refused but exited 0: $OUT"
  expect_out "$1"
}
expect_out() { # <substring>
  case $OUT in *"$1"*) ;; *) fail "expected output to contain '$1', got: $OUT" ;; esac
}
expect_eq() { # <actual> <expected> [label]
  [ "$1" = "$2" ] || fail "${3:-value}: expected '$2', got '$1'"
}
expect_called() { # <substring of a stub call>
  grep -qF -- "$1" "$T/calls.log" || fail "expected a stub call containing '$1'; calls: $(cat "$T/calls.log")"
}
expect_not_called() { # <substring>
  ! grep -qF -- "$1" "$T/calls.log" || fail "did not expect a stub call containing '$1'"
}
expect_status() { # <id> <status>
  expect_eq "$(job_value "$1" status)" "$2" "status of $1"
}

# ---------------------------------------------------------------- runner

# Run every test_* function (or just <only>) in this file. Prints one line per
# test: "ok", "FAIL", "skip" or "xfail". Exits non-zero if any failed.
run_tests() { # [only]
  local fn name status failed=0 log ran=0
  log=$(mktemp "${TMPDIR:-/tmp}/deck-test-log.XXXXXX")
  for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
    name=${fn#test_}
    [ -z "${1:-}" ] || [ "$1" = "$name" ] || [ "$1" = "$fn" ] || continue
    status=0 ran=1
    ( sandbox; trap cleanup_sandbox EXIT; "$fn" ) >"$log" 2>&1 || status=$?
    case $status in
      0) printf '  ok     %s\n' "$name" ;;
      77) printf '  skip   %s\n' "$name"; sed 's/^/  /' "$log" | grep 'skip:' ;;
      78) printf '  xfail  %s\n' "$name"; sed 's/^/  /' "$log" | grep 'xfail:' ;;
      *) printf '  FAIL   %s\n' "$name"; sed 's/^/    | /' "$log"; failed=1 ;;
    esac
  done
  rm -f "$log"
  if [ $ran = 0 ]; then echo "  no test named '$1' in this file" >&2; return 1; fi
  return $failed
}
