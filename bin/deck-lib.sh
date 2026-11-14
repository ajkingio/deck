#!/usr/bin/env bash
# Shared helpers for deck scripts. Source this file; do not execute it.
# Written for the bash 3.2 that ships with macOS: no associative arrays, no mapfile.

set -u

DECK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DECK_BIN="$DECK_ROOT/bin"
DECK_DATA="$DECK_ROOT/data"
DECK_STATE="$DECK_ROOT/state"
DECK_CONF="$DECK_ROOT/config/deck.conf"
DECK_JOBS="$DECK_DATA/jobs"
DECK_PROJECTS="$DECK_DATA/projects"
DECK_HARNESSES="claude codex grok pi"   # harnesses a worker can run in
DECK_OPERATOR_HARNESSES="$DECK_HARNESSES"  # harnesses the operator can run in
DECK_ALIAS=jackin             # the launcher alias ./setup installs
DECK_GREETING="jacking in"    # what the launcher says to open each session

die() { printf 'deck: %s\n' "$*" >&2; exit 1; }
warn() { printf 'deck: %s\n' "$*" >&2; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is not installed"; }

# Backward compatibility: this project was called fixer. A clone set up before
# the rename keeps config/fixer.conf until bin/deck-migrate renames it; read it
# meanwhile, and say so once per process tree.
DECK_LEGACY_CONF="$DECK_ROOT/config/fixer.conf"
if [ ! -f "$DECK_CONF" ] && [ -f "$DECK_LEGACY_CONF" ]; then
  DECK_CONF=$DECK_LEGACY_CONF
  if [ -z "${DECK_LEGACY_WARNED:-}" ]; then
    printf 'deck: using legacy config/fixer.conf; run bin/deck-migrate to rename it to config/deck.conf\n' >&2
    export DECK_LEGACY_WARNED=1
  fi
fi

# key=value files ------------------------------------------------------------

conf_get() { # <file> <key> [default]
  local v=""
  if [ -f "$1" ]; then v=$(grep -E "^$2=" "$1" | tail -n1 | cut -d= -f2-); fi
  if [ -n "$v" ]; then printf '%s\n' "$v"; else printf '%s\n' "${3:-}"; fi
}

# Config value under its current key, else under the key it had before the
# rename (fixer_harness, runner_harness, lowkey), else the default.
cfg_get() { # <key> <legacy-key> [default]
  local v
  v=$(conf_get "$DECK_CONF" "$1" "")
  [ -n "$v" ] || v=$(conf_get "$DECK_CONF" "$2" "${3:-}")
  printf '%s\n' "$v"
}

conf_set() { # <file> <key> <value>   (value must be a single line)
  local f=$1 k=$2 v=$3 tmp
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || : >"$f"
  tmp=$(mktemp "$f.XXXXXX")
  grep -v -E "^$k=" "$f" >"$tmp" || true
  printf '%s=%s\n' "$k" "$(printf '%s' "$v" | tr '\n' ' ')" >>"$tmp"
  mv "$tmp" "$f"
}

# jobs -------------------------------------------------------------------------

valid_id() { printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9-]{0,31}$'; }
job_dir() { printf '%s/%s\n' "$DECK_JOBS" "$1"; }
job_conf() { printf '%s/%s/job.conf\n' "$DECK_JOBS" "$1"; }
job_get() { conf_get "$(job_conf "$1")" "$2" "${3:-}"; }
job_set() { conf_set "$(job_conf "$1")" "$2" "$3"; }

require_job() {
  valid_id "${1:-}" || die "invalid job id '${1:-}': use lowercase letters, digits and dashes, start with a letter, max 32 chars"
  [ -f "$(job_conf "$1")" ] || die "no such job: $1"
}

job_ids() { # all job ids, oldest first
  [ -d "$DECK_JOBS" ] || return 0
  ls -1tr "$DECK_JOBS" 2>/dev/null | while read -r d; do
    [ -f "$DECK_JOBS/$d/job.conf" ] && printf '%s\n' "$d"
  done
}

# projects ---------------------------------------------------------------------

project_conf() { printf '%s/%s.conf\n' "$DECK_PROJECTS" "$1"; }
project_get() { conf_get "$(project_conf "$1")" "$2" "${3:-}"; }
# Pass the recorded forge without tying detection to job/worktree layout.
# An explicit environment override (even empty) takes precedence.
project_forge() { # <project> <deck-forge arguments...>
  local project=$1; shift
  DECK_FORGE="${DECK_FORGE-$(project_get "$project" forge)}" "$DECK_BIN/deck-forge" "$@"
}

require_project() {
  [ -n "${1:-}" ] || die "missing --project"
  [ -f "$(project_conf "$1")" ] || die "no such project: $1 (see: bin/deck-project list)"
}

# paths ------------------------------------------------------------------------

# Worktrees live outside this repo on purpose: Claude Code loads CLAUDE.md from
# every parent directory, so a worktree under deck/ would turn a worker into a
# second operator.
worktree_root() {
  local h
  h=$(printf '%s' "$DECK_ROOT" | cksum | cut -d' ' -f1)
  printf '%s/%s-%s\n' "${DECK_WORKTREES:-$HOME/.deck/worktrees}" "$(basename "$DECK_ROOT")" "$h"
}

# harness ----------------------------------------------------------------------

valid_harness() { case " $DECK_HARNESSES " in *" $1 "*) return 0 ;; esac; return 1; }
valid_operator_harness() { case " $DECK_OPERATOR_HARNESSES " in *" $1 "*) return 0 ;; esac; return 1; }

# The harness the operator itself is running in, as Herdr sees it (or, failing
# that, pi when Pi's shell tool set PI_CODING_AGENT).
operator_harness() {
  local h=""
  if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ] && command -v herdr >/dev/null 2>&1; then
    h=$(herdr agent get "$HERDR_PANE_ID" 2>/dev/null | jq -r '.result.agent.agent // empty' 2>/dev/null)
  fi
  [ -n "$h" ] || [ "${PI_CODING_AGENT:-}" != true ] || h=pi
  printf '%s\n' "$h"
}

# Herdr workspaces -------------------------------------------------------------

# Worker workspaces are labelled "└ <job-id>" and grouped in a block right
# after the operator's workspace, so they read as its children. Herdr has no
# nested workspaces; this is presentation only. The Herdr agent name stays
# the bare job id.
DECK_WS_PREFIX="└ "
worker_ws_label() { printf '%s%s\n' "$DECK_WS_PREFIX" "$1"; }

# Best-effort: move workspace <ws> to the end of the block of "└ " workspaces
# that follows the operator's own workspace. The operator's workspace is resolved
# live from HERDR_PANE_ID (labels aren't unique). Never fails the caller.
group_worker_workspace() { # <ws>
  local new=$1 parent list idx out
  if [ -z "${HERDR_PANE_ID:-}" ]; then
    warn "not inside a Herdr pane; leaving workspace $new where Herdr put it"; return 0
  fi
  parent=$(herdr pane get "$HERDR_PANE_ID" 2>/dev/null | jq -r '.result.pane.workspace_id // empty' 2>/dev/null)
  [ -n "$parent" ] || { warn "could not find the operator's Herdr workspace; leaving workspace $new where Herdr put it"; return 0; }
  [ "$parent" != "$new" ] || return 0
  list=$(herdr workspace list 2>/dev/null)
  # Index among the other workspaces: just past the parent and any "└ " run after it.
  idx=$(printf '%s' "$list" | jq -r --arg p "$parent" --arg n "$new" --arg pre "$DECK_WS_PREFIX" '
    [.result.workspaces[] | select(.workspace_id != $n)] as $ws
    | ($ws | map(.workspace_id) | index($p)) as $i
    | if $i == null then empty else
        ([range($i + 1; $ws | length)] | map(select(($ws[.].label // "") | startswith($pre) | not)) | .[0]) // ($ws | length)
      end' 2>/dev/null)
  [ -n "$idx" ] || { warn "could not read Herdr's workspace order; leaving workspace $new where Herdr put it"; return 0; }
  out=$("$DECK_BIN/deck-herdr-move" "$new" "$idx" 2>&1 >/dev/null) ||
    warn "could not move workspace $new next to the operator's: $out"
  return 0
}

# Read-only: does <harness> already trust the repository at <path>?
harness_trusts() { # <harness> <path>
  local h=$1 p=$2 f
  case $h in
    claude)
      f="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
      [ -f "$f" ] && jq -e --arg p "$p" '.projects[$p].hasTrustDialogAccepted == true' "$f" >/dev/null 2>&1 ;;
    codex)
      f="${CODEX_HOME:-$HOME/.codex}/config.toml"
      [ -f "$f" ] && awk -v p="[projects.\"$p\"]" '$0 == p { s = 1; next } /^\[/ { s = 0 } s && /trust_level *= *"trusted"/ { found = 1 } END { exit !found }' "$f" ;;
    grok)
      f="${GROK_HOME:-$HOME/.grok}/trusted_folders.toml"
      # Its format isn't documented: accept only an exact quoted-path key
      # ("<path>" = ...) or a table header whose last key is that path.
      [ -f "$f" ] && awk -v k="\"$p\"" '
        { l = $0; sub(/^[ \t]+/, "", l); sub(/[ \t]+$/, "", l) }
        substr(l, 1, length(k)) == k && substr(l, length(k) + 1) ~ /^[ \t]*=/ { found = 1 }
        l ~ /^\[/ && (l == "[" k "]" || l == "[[" k "]]" || substr(l, length(l) - length(k) - 1) == "." k "]") { found = 1 }
        END { exit !found }' "$f" ;;
    pi)
      # Pi keys trust by path and the closest saved decision wins: the nearest
      # of <path> and its ancestors that has an entry decides.
      f="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/trust.json"
      [ -f "$f" ] && jq -e --arg p "$p" '
        . as $t | [$p | recurse(if . == "/" then empty else (sub("/[^/]*$"; "") | if . == "" then "/" else . end) end)]
        | map(. as $a | select($t | has($a))) | .[0] as $k | $k != null and $t[$k] == true' "$f" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}


default_harness() {
  local h
  h=$(cfg_get worker_harness runner_harness "")
  [ -n "$h" ] || h=$(operator_harness)
  valid_harness "$h" || h=claude
  printf '%s\n' "$h"
}

# rendering --------------------------------------------------------------------

# Replace {{KEY}} with the value of env var T_KEY. Literal replacement: values
# may contain slashes, ampersands or backslashes.
render_template() { # <template-file>
  awk '
    function rep(s, key, val,   out, i, n) {
      n = length(key); out = ""
      while ((i = index(s, key)) > 0) { out = out substr(s, 1, i - 1) val; s = substr(s, i + n) }
      return out s
    }
    { line = $0
      for (k in ENVIRON) if (k ~ /^T_/) line = rep(line, "{{" substr(k, 3) "}}", ENVIRON[k])
      print line }
  ' "$1"
}

# Frontmatter field of a markdown file ("key: value" between the first two ---).
fm_get() { # <file> <key>
  awk -v k="$2" '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    NR > 1 { i = index($0, ":"); if (i && substr($0, 1, i - 1) == k) { v = substr($0, i + 1); sub(/^[ \t]+/, "", v); print v; exit } }
  ' "$1"
}

# Body of a markdown file without its frontmatter.
fm_body() { awk 'NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { fm = 0; next } !fm' "$1"; }
