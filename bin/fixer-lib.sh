#!/usr/bin/env bash
# Shared helpers for fixer scripts. Source this file; do not execute it.
# Written for the bash 3.2 that ships with macOS: no associative arrays, no mapfile.

set -u

FIXER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FIXER_BIN="$FIXER_ROOT/bin"
FIXER_DATA="$FIXER_ROOT/data"
FIXER_STATE="$FIXER_ROOT/state"
FIXER_CONF="$FIXER_ROOT/config/fixer.conf"
FIXER_JOBS="$FIXER_DATA/jobs"
FIXER_PROJECTS="$FIXER_DATA/projects"
FIXER_HARNESSES="claude codex grok"
FIXER_ALIAS=holocall                 # the launcher alias ./setup installs
FIXER_GREETING="got a job for you"   # what the launcher says to open each session

die() { printf 'fixer: %s\n' "$*" >&2; exit 1; }
warn() { printf 'fixer: %s\n' "$*" >&2; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is not installed"; }

# key=value files ------------------------------------------------------------

conf_get() { # <file> <key> [default]
  local v=""
  if [ -f "$1" ]; then v=$(grep -E "^$2=" "$1" | tail -n1 | cut -d= -f2-); fi
  if [ -n "$v" ]; then printf '%s\n' "$v"; else printf '%s\n' "${3:-}"; fi
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
job_dir() { printf '%s/%s\n' "$FIXER_JOBS" "$1"; }
job_conf() { printf '%s/%s/job.conf\n' "$FIXER_JOBS" "$1"; }
job_get() { conf_get "$(job_conf "$1")" "$2" "${3:-}"; }
job_set() { conf_set "$(job_conf "$1")" "$2" "$3"; }

require_job() {
  valid_id "${1:-}" || die "invalid job id '${1:-}': use lowercase letters, digits and dashes, start with a letter, max 32 chars"
  [ -f "$(job_conf "$1")" ] || die "no such job: $1"
}

job_ids() { # all job ids, oldest first
  [ -d "$FIXER_JOBS" ] || return 0
  ls -1tr "$FIXER_JOBS" 2>/dev/null | while read -r d; do
    [ -f "$FIXER_JOBS/$d/job.conf" ] && printf '%s\n' "$d"
  done
}

# projects ---------------------------------------------------------------------

project_conf() { printf '%s/%s.conf\n' "$FIXER_PROJECTS" "$1"; }
project_get() { conf_get "$(project_conf "$1")" "$2" "${3:-}"; }
require_project() {
  [ -n "${1:-}" ] || die "missing --project"
  [ -f "$(project_conf "$1")" ] || die "no such project: $1 (see: bin/fixer-project list)"
}

# paths ------------------------------------------------------------------------

# Worktrees live outside this repo on purpose: Claude Code loads CLAUDE.md from
# every parent directory, so a worktree under fixer/ would turn a runner into a
# second Fixer.
worktree_root() {
  local h
  h=$(printf '%s' "$FIXER_ROOT" | cksum | cut -d' ' -f1)
  printf '%s/%s-%s\n' "${FIXER_WORKTREES:-$HOME/.fixer/worktrees}" "$(basename "$FIXER_ROOT")" "$h"
}

# harness ----------------------------------------------------------------------

valid_harness() { case " $FIXER_HARNESSES " in *" $1 "*) return 0 ;; esac; return 1; }

# The harness the Fixer itself is running in, as Herdr sees it.
fixer_harness() {
  local h=""
  if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ] && command -v herdr >/dev/null 2>&1; then
    h=$(herdr agent get "$HERDR_PANE_ID" 2>/dev/null | jq -r '.result.agent.agent // empty' 2>/dev/null)
  fi
  printf '%s\n' "$h"
}

# Herdr workspaces -------------------------------------------------------------

# Runner workspaces are labelled "└ <job-id>" and grouped in a block right
# after the Fixer's workspace, so they read as its children. Herdr has no
# nested workspaces; this is presentation only. The Herdr agent name stays
# the bare job id.
FIXER_WS_PREFIX="└ "
runner_ws_label() { printf '%s%s\n' "$FIXER_WS_PREFIX" "$1"; }

# Best-effort: move workspace <ws> to the end of the block of "└ " workspaces
# that follows the Fixer's own workspace. The Fixer's workspace is resolved
# live from HERDR_PANE_ID (labels aren't unique). Never fails the caller.
group_runner_workspace() { # <ws>
  local new=$1 parent list idx out
  if [ -z "${HERDR_PANE_ID:-}" ]; then
    warn "not inside a Herdr pane; leaving workspace $new where Herdr put it"; return 0
  fi
  parent=$(herdr pane get "$HERDR_PANE_ID" 2>/dev/null | jq -r '.result.pane.workspace_id // empty' 2>/dev/null)
  [ -n "$parent" ] || { warn "could not find the Fixer's Herdr workspace; leaving workspace $new where Herdr put it"; return 0; }
  [ "$parent" != "$new" ] || return 0
  list=$(herdr workspace list 2>/dev/null)
  # Index among the other workspaces: just past the parent and any "└ " run after it.
  idx=$(printf '%s' "$list" | jq -r --arg p "$parent" --arg n "$new" --arg pre "$FIXER_WS_PREFIX" '
    [.result.workspaces[] | select(.workspace_id != $n)] as $ws
    | ($ws | map(.workspace_id) | index($p)) as $i
    | if $i == null then empty else
        ([range($i + 1; $ws | length)] | map(select(($ws[.].label // "") | startswith($pre) | not)) | .[0]) // ($ws | length)
      end' 2>/dev/null)
  [ -n "$idx" ] || { warn "could not read Herdr's workspace order; leaving workspace $new where Herdr put it"; return 0; }
  out=$("$FIXER_BIN/fixer-herdr-move" "$new" "$idx" 2>&1 >/dev/null) ||
    warn "could not move workspace $new next to the Fixer's: $out"
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
    *) return 1 ;;
  esac
}


default_harness() {
  local h
  h=$(conf_get "$FIXER_CONF" runner_harness "")
  [ -n "$h" ] || h=$(fixer_harness)
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
