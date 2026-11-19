# Terminal multiplexer backends for deck. Sourced by deck-lib.sh; do not execute.
# Written for the bash 3.2 that ships with macOS.
#
# deck drives its workers through a terminal multiplexer: Herdr (the default)
# or Rex. Every call to either one goes through the mux_* functions here.
#
#   choosing:  config/deck.conf mux=herdr|rex, overridden by the DECK_MUX env var.
#              A job records the mux it was spawned under (job.conf mux=...), so
#              changing the setting never strands a live worker: every command
#              on an existing job uses that job's mux.
#
# Herdr: a worker is a Herdr agent named <id> in a workspace labelled "└ <id>".
#
# Rex: a worker is a Rex window (a tab) labelled "└ <id>" in the operator's Rex
# session ($REX_SESSION, else config rex_session). The window runs the harness
# directly (no shell), with --keep-open so its screen stays readable after it
# exits. job.conf records mux_session, workspace (the window id) and pane (the
# block id). Worker state comes from the Program Status Protocol (OSC 7501):
# Claude Code and Pi report working / blocked (kind permission|question) /
# done / idle themselves, and Rex keeps the latest report per terminal
# (block method program_status), dropping it when the reporting process exits.
# Codex and Grok don't report, so for them deck sees only whether the process
# is alive. The rex binary: config rex_bin, else `rex` on PATH, else
# $REX_BIN_DIR/rex (set inside Rex terminals), else the one in the Rex app bundle.

DECK_MUXES="herdr rex"
DECK_REX_APP_BIN=${DECK_REX_APP_BIN:-"/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"}

valid_mux() { case " $DECK_MUXES " in *" $1 "*) return 0 ;; esac; return 1; }

# The mux new work goes to.
mux_name() {
  local m=${DECK_MUX:-}
  [ -n "$m" ] || m=$(conf_get "$DECK_CONF" mux herdr)
  valid_mux "$m" || die "unknown multiplexer '$m' (DECK_MUX or mux= in config/deck.conf): use one of $DECK_MUXES"
  printf '%s\n' "$m"
}

# The mux a job was spawned under. Jobs from before deck had a choice are Herdr's.
job_mux() { # <id>
  local m
  m=$(job_get "$1" mux "")
  [ -n "$m" ] || m=herdr
  printf '%s\n' "$m"
}

mux_title() { case $1 in rex) echo Rex ;; *) echo Herdr ;; esac; }

# What the operator calls a worker's space in this mux, for messages.
mux_space() { case $1 in rex) echo "Rex tab" ;; *) echo "Herdr workspace" ;; esac; }

# ------------------------------------------------------------------ rex basics

rex_bin() {
  local b
  b=$(conf_get "$DECK_CONF" rex_bin "")
  [ -n "$b" ] || b=$(command -v rex 2>/dev/null) || b=""
  # Programs in Rex terminals get REX_BIN_DIR, where the running server's rex lives.
  [ -n "$b" ] || { [ -n "${REX_BIN_DIR:-}" ] && [ -x "$REX_BIN_DIR/rex" ] && b=$REX_BIN_DIR/rex; }
  [ -n "$b" ] || { [ -x "$DECK_REX_APP_BIN" ] && b=$DECK_REX_APP_BIN; }
  [ -n "$b" ] || return 1
  printf '%s\n' "$b"
}

rexc() { # <rex args...>
  local b
  b=$(rex_bin) || { echo "rex is not installed" >&2; return 127; }
  "$b" "$@"
}

# The Rex session the operator works in: the one it runs inside, else the
# configured one.
rex_session() {
  if [ -n "${REX_SESSION:-}" ]; then printf '%s\n' "$REX_SESSION"; return 0; fi
  local s
  s=$(conf_get "$DECK_CONF" rex_session "")
  [ -n "$s" ] || return 1
  printf '%s\n' "$s"
}

# Root program-status record of a block as "<state> <updated_at>", or nothing.
rex_program_state() { # <session> <block>
  rexc block call -s "$1" -b "$2" program_status 2>/dev/null |
    jq -r 'first(.records[]? | select((.id // "") == "")) | "\(.state) \(.updated_at)"' 2>/dev/null
}

# Is the program in the block still running? (A --keep-open block outlives it.)
rex_block_alive() { # <session> <block>
  local p
  p=$(rexc block call -s "$1" -b "$2" process 2>/dev/null) || return 1
  [ -n "$(printf '%s' "$p" | jq -r '.child.pid // empty' 2>/dev/null)" ]
}

rex_window_label() { # <session> <window>
  rexc window ls -s "$1" --json 2>/dev/null |
    jq -r --arg w "$2" '.windows[]? | select(.window_id == $w) | .label' 2>/dev/null
}

# Type <text> into a block as one paste, then press Return.
rex_paste_enter() { # <session> <block> <text>
  jq -nc --arg b "$2" --arg t "$3" '{block_id:$b,event:{type:"paste",payload:{text:$t}}}' |
    rexc api call -s "$1" block.event - >/dev/null 2>&1 || return 1
  sleep "${DECK_REX_PASTE_SETTLE:-0.3}"   # each rex call is its own connection; keep Return after the paste
  rexc send-key -s "$1" -b "$2" enter >/dev/null 2>&1
}

# Best-effort: move window <w> to the end of the run of "└ " tabs that follows
# the operator's own tab (found from $REX_BLOCK). Never fails the caller.
rex_group_window() { # <session> <window>
  local s=$1 new=$2 list before
  [ -n "${REX_BLOCK:-}" ] || return 0
  list=$(rexc window ls -s "$s" --json 2>/dev/null) || return 0
  before=$(printf '%s' "$list" | jq -r --arg b "$REX_BLOCK" --arg n "$new" --arg pre "$DECK_WS_PREFIX" '
    [.windows[] | select(.window_id != $n)] as $ws
    | ($ws | map([.layers[]?.blocks[]?.block_id] | index($b) != null) | index(true)) as $i
    | if $i == null then "skip" else
        ([range($i + 1; $ws | length)] | map(select(($ws[.].label // "") | startswith($pre) | not)) | .[0]) as $j
        | if $j == null then "end" else $ws[$j].window_id end
      end' 2>/dev/null)
  case $before in
    ""|skip) return 0 ;;
    end) jq -nc --arg w "$new" '{window_id:$w}' ;;
    *) jq -nc --arg w "$new" --arg x "$before" '{window_id:$w,before_window_id:$x}' ;;
  esac | rexc api call -s "$s" session.move_window - >/dev/null 2>&1 ||
    warn "could not move tab $new next to the operator's"
  return 0
}

# Wait for the harness in a block to be ready for a prompt: one that reports
# status says idle; one that doesn't (codex, grok) is taken as ready once its
# screen stops changing. Returns 0 when ready; else sets MUX_ERR (exited, or
# agent_not_ready when it is at a dialog or never got ready) and MUX_OUT.
rex_wait_ready() { # <session> <block> <harness>
  local s=$1 b=$2 harness=$3 i=0 prev="" cur stable=0 st
  while [ $i -lt "${DECK_REX_START_TRIES:-90}" ]; do
    rex_block_alive "$s" "$b" ||
      { MUX_ERR=exited MUX_OUT="$harness exited as it started; its screen: $(rexc capture -s "$s" -b "$b" --trim 2>/dev/null | tail -n 15)"; return 1; }
    st=$(rex_program_state "$s" "$b")
    case ${st%% *} in
      idle|done) return 0 ;;
      blocked) MUX_ERR=agent_not_ready MUX_OUT="$harness is at a dialog"; return 1 ;;
    esac
    case $harness in
      codex|grok)
        cur=$(rexc capture -s "$s" -b "$b" --trim 2>/dev/null | cksum)
        if [ -n "$cur" ] && [ "$cur" = "$prev" ]; then stable=$((stable + 1)); else stable=0; fi
        prev=$cur
        [ $stable -lt 3 ] || return 0 ;;
    esac
    i=$((i + 1)); sleep 1
  done
  MUX_ERR=agent_not_ready MUX_OUT="$harness did not report ready (it may be at a startup dialog)"
  return 1
}

# ------------------------------------------------------------------ readiness

# Is the operator somewhere this mux can open worker spaces? Dies with a fix if not.
mux_require_ready() { # <mux>
  case $1 in
    herdr)
      need herdr
      [ "${HERDR_ENV:-}" = 1 ] || die "the operator is not running inside Herdr; start herdr in the deck directory and launch your agent inside it" ;;
    rex)
      rex_bin >/dev/null || die "rex is not installed (no rex on PATH, no $DECK_REX_APP_BIN; set rex_bin= in config/deck.conf)"
      rex_session >/dev/null || die "the operator is not running inside Rex (no REX_SESSION) and config/deck.conf has no rex_session; run your agent in a Rex tab"
      rexc session inspect "$(rex_session)" --json >/dev/null 2>&1 ||
        die "Rex session $(rex_session) isn't there (is the Rex server running? rex ls)" ;;
  esac
}

# ------------------------------------------------------------------ agents

# A job's worker as "<status> <seq>": status is working|idle|done|blocked
# (blocked = at an approval or question dialog). Prints nothing when no live
# worker holds the job. seq changes whenever the status is reported again.
mux_agent_status() { # <id>
  local id=$1 info s b st
  case $(job_mux "$id") in
    herdr)
      command -v herdr >/dev/null 2>&1 || return 0
      info=$(herdr agent get "$id" 2>/dev/null) || return 0
      printf '%s' "$info" | jq -r '.result.agent | select(.agent_status != null) | "\(.agent_status) \(.state_change_seq // 0)"' 2>/dev/null ;;
    rex)
      s=$(job_get "$id" mux_session) b=$(job_get "$id" pane)
      [ -n "$s" ] && [ -n "$b" ] || return 0
      rex_bin >/dev/null || return 0
      rex_block_alive "$s" "$b" || return 0
      st=$(rex_program_state "$s" "$b")
      case ${st%% *} in
        working|blocked|idle|done) printf '%s\n' "$st" ;;
        error) printf 'done %s\n' "${st#* }" ;;    # the run ended in an error: it stopped
        "") echo "working 0" ;;                     # alive, no report (codex, grok, or still starting)
        *) printf 'idle %s\n' "${st#* }" ;;         # the protocol says: treat unknown as idle
      esac ;;
  esac
}

mux_agent_exists() { [ -n "$(mux_agent_status "$1")" ]; }

# The command the operator uses to read a worker's screen.
mux_read_hint() { # <id>
  case $(job_mux "$1") in
    rex) echo "bin/deck-peek $1" ;;
    *) echo "herdr agent read $1 --source recent-unwrapped --lines 80" ;;
  esac
}

# Print the last <lines> lines of a worker's screen.
mux_agent_read() { # <id> <lines>
  local id=$1 n=$2
  case $(job_mux "$id") in
    herdr) herdr agent read "$id" --source recent-unwrapped --lines "$n" ;;
    rex) rexc capture -s "$(job_get "$id" mux_session)" -b "$(job_get "$id" pane)" --trim --unwrap | tail -n "$n" ;;
  esac
}

# Press <key> (Rex/Herdr key syntax: esc, ctrl+c, enter) in the worker's terminal.
mux_agent_send_key() { # <id> <key>
  local id=$1 key=$2
  case $(job_mux "$id") in
    herdr) herdr agent send-keys "$id" "$key" ;;
    rex)
      mux_agent_exists "$id" || { echo "no live worker for $id" >&2; return 1; }
      rexc send-key -s "$(job_get "$id" mux_session)" -b "$(job_get "$id" pane)" "$key" ;;
  esac
}

# Send the worker a prompt. Returns 0 when delivered. On failure MUX_ERR holds
# a code: timeout (Herdr: delivered, still working; callers treat it as
# success), agent_blocked (at a dialog), agent_not_found, or another code, and
# MUX_OUT the raw output.
MUX_ERR="" MUX_OUT=""
mux_agent_prompt() { # <id> <text> <timeout-ms>
  local id=$1 text=$2 tmo=$3 rc st
  MUX_ERR="" MUX_OUT=""
  case $(job_mux "$id") in
    herdr)
      MUX_OUT=$(herdr agent prompt "$id" "$text" --wait --timeout "$tmo" 2>&1)
      rc=$?
      MUX_ERR=$(printf '%s' "$MUX_OUT" | jq -r '.error.code // empty' 2>/dev/null)
      [ $rc = 0 ] || [ -n "$MUX_ERR" ] || MUX_ERR=failed
      return $rc ;;
    rex)
      st=$(mux_agent_status "$id")
      case ${st%% *} in
        "") MUX_ERR=agent_not_found MUX_OUT="no live worker in Rex for $id"; return 1 ;;
        blocked) MUX_ERR=agent_blocked MUX_OUT="worker $id is at a dialog"; return 1 ;;
      esac
      rex_paste_enter "$(job_get "$id" mux_session)" "$(job_get "$id" pane)" "$text" ||
        { MUX_ERR=send_failed MUX_OUT="rex could not type into worker $id's tab"; return 1; }
      return 0 ;;
  esac
}

# ------------------------------------------------------------------ worker spaces

# Label of a job's worker space, or nothing if it is gone.
mux_ws_label() { # <id> <ws>
  local id=$1 ws=$2
  case $(job_mux "$id") in
    herdr) herdr workspace list 2>/dev/null | jq -r --arg w "$ws" '.result.workspaces[] | select(.workspace_id == $w) | .label' 2>/dev/null ;;
    rex) rex_window_label "$(job_get "$id" mux_session)" "$ws" ;;
  esac
}

mux_ws_close() { # <id> <ws>
  case $(job_mux "$1") in
    herdr) herdr workspace close "$2" >/dev/null 2>&1 ;;
    rex) rexc window close -s "$(job_get "$1" mux_session)" "$2" >/dev/null 2>&1 ;;
  esac
}

# Close the job's worker space only if it still carries our label: "└ <id>",
# or the plain "<id>" used by jobs spawned before grouping. Warns otherwise.
mux_ws_close_if_ours() { # <id> <ws>
  local id=$1 ws=$2 label
  case $(job_mux "$id") in
    herdr) command -v herdr >/dev/null 2>&1 || return 0 ;;
    rex) rex_bin >/dev/null || return 0 ;;
  esac
  label=$(mux_ws_label "$id" "$ws")
  if [ "$label" = "$(worker_ws_label "$id")" ] || [ "$label" = "$id" ]; then
    mux_ws_close "$id" "$ws" || warn "could not close $(mux_space "$(job_mux "$id")") $ws"
  elif [ -n "$label" ]; then
    warn "$(mux_space "$(job_mux "$id")") $ws is now labelled '$label', not '$(worker_ws_label "$id")'; leaving it open"
  fi
  return 0
}

# Can a relaunch reuse the job's old pane? Herdr: yes when the pane is still
# in the job's workspace and that workspace still carries our label. Rex: never
# (a tab's program can't be restarted in place; the relaunch opens a new tab).
mux_ws_reusable() { # <id> <ws> <pane>
  local id=$1 ws=$2 pane=$3 label pws
  case $(job_mux "$id") in
    herdr)
      label=$(mux_ws_label "$id" "$ws")
      pws=$(herdr pane get "$pane" 2>/dev/null | jq -r '.result.pane.workspace_id // empty' 2>/dev/null)
      { [ "$label" = "$(worker_ws_label "$id")" ] || [ "$label" = "$id" ]; } && [ "$pws" = "$ws" ] ;;
    *) return 1 ;;
  esac
}

# Create a worker space for a job. Sets MUX_WS and MUX_PANE (Herdr). Rex makes
# the tab when the worker starts (mux_agent_start), so here it sets both empty.
MUX_WS="" MUX_PANE=""
mux_ws_create() { # <id> <worktree>
  local id=$1 wt=$2
  MUX_WS="" MUX_PANE="" MUX_OUT=""
  case $(job_mux "$id") in
    herdr)
      MUX_OUT=$(herdr workspace create --cwd "$wt" --label "$(worker_ws_label "$id")" --no-focus \
        --env "DECK_JOB=$id" --env "DECK_HOME=$DECK_ROOT" --env "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false" 2>&1) || return 1
      MUX_WS=$(printf '%s' "$MUX_OUT" | jq -r '.result.workspace.workspace_id')
      MUX_PANE=$(printf '%s' "$MUX_OUT" | jq -r '.result.root_pane.pane_id')
      group_worker_workspace "$MUX_WS" ;;
    rex) ;;
  esac
  return 0
}

# Start the worker's harness. Herdr: in <pane>, retrying while its shell starts.
# Rex: in a new tab "└ <id>" at <worktree> (sets MUX_WS and MUX_PANE), then
# waits for the harness to come up. Returns 0 when it is ready for its brief.
# On failure MUX_ERR is agent_not_ready (up, but at a startup dialog), or
# another code, and MUX_OUT says what happened.
mux_agent_start() { # <id> <harness> <pane> <worktree> [harness args...]
  local id=$1 harness=$2 pane=$3 wt=$4 tries=0 s exe out
  shift 4
  MUX_ERR="" MUX_OUT=""
  case $(job_mux "$id") in
    herdr)
      while :; do
        MUX_OUT=$(herdr agent start "$id" --kind "$harness" --pane "$pane" --timeout 90000 -- "$@" 2>&1) && return 0
        MUX_ERR=$(printf '%s' "$MUX_OUT" | jq -r '.error.code // empty' 2>/dev/null)
        if [ "$MUX_ERR" = agent_pane_busy ] && [ $tries -lt 30 ]; then tries=$((tries + 1)); sleep 1; continue; fi
        [ -n "$MUX_ERR" ] || MUX_ERR=failed
        return 1
      done ;;
    rex)
      s=$(job_get "$id" mux_session)
      exe=$(command -v "$harness") || { MUX_ERR=failed MUX_OUT="$harness is not installed"; return 1; }
      # The tab runs the harness directly, through the login shell's environment.
      out=$(rexc window new -s "$s" "$(worker_ws_label "$id")" -c "$wt" --focus=false --keep-open --json -- \
        /usr/bin/env "DECK_JOB=$id" "DECK_HOME=$DECK_ROOT" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false PI_PROGRAM_STATUS=1 \
        "$exe" "$@" 2>&1) || { MUX_ERR=failed MUX_OUT="rex window new failed: $out"; return 1; }
      MUX_WS=$(printf '%s' "$out" | jq -r '.window_id // empty' 2>/dev/null)
      MUX_PANE=$(printf '%s' "$out" | jq -r '.block_ids[0] // empty' 2>/dev/null)
      [ -n "$MUX_PANE" ] || { MUX_ERR=failed MUX_OUT="rex window new returned no block: $out"; return 1; }
      rex_group_window "$s" "$MUX_WS"
      rex_wait_ready "$s" "$MUX_PANE" "$harness" ;;
  esac
}

# ------------------------------------------------------------------ notifications

# A user-facing notification about a job. Herdr shows its own; under Rex the
# worker's tab carries its status in the sidebar (and its Activity filter), so
# this is quiet.
mux_notify() { # <id> <title> <body> <sound>
  [ "$(conf_get "$DECK_CONF" notify on)" = off ] && return 0
  [ "$(job_mux "$1")" = herdr ] || return 0
  command -v herdr >/dev/null 2>&1 || return 0
  herdr notification show "$2" --body "$3" --sound "$4" >/dev/null 2>&1 || true
}
