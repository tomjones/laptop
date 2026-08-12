#!/usr/bin/env bash
# lib/common.sh — logging, dry-run plumbing, idempotency helpers, step accounting.
#
# Deliberately NOT `set -e`. Most setup scripts abort the whole run on any
# single apt hiccup, with no way to resume. Here every step is accounted for
# individually; failures are recorded and reported at the end, and the run
# continues so one broken package cannot cost you the other nine profiles.
#
# shellcheck shell=bash

set -uo pipefail

# ---------------------------------------------------------------- output ----

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

log()      { printf '%s\n' "$*"; }
info()     { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
success()  { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
skip()     { printf '%s  --%s %s\n' "$C_DIM" "$C_RESET" "$*"; }
warn()     { printf '%s  !!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error()    { printf '%s  XX%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
heading()  { printf '\n%s%s%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"; }

die() { error "$*"; exit 1; }

# ------------------------------------------------------------ accounting ----

declare -a STEPS_OK=() STEPS_SKIP=() STEPS_FAIL=() NOTES=() MANUAL=()
CURRENT_STEP=""

step() { CURRENT_STEP="$1"; }

mark_ok()   { STEPS_OK+=("${1:-$CURRENT_STEP}");   success "${1:-$CURRENT_STEP}"; }
mark_skip() { STEPS_SKIP+=("${1:-$CURRENT_STEP}"); skip    "${1:-$CURRENT_STEP}${2:+ ($2)}"; }
mark_fail() { STEPS_FAIL+=("${1:-$CURRENT_STEP}"); error   "${1:-$CURRENT_STEP}${2:+ — $2}"; }

# note: informational line surfaced in the final summary.
note()   { NOTES+=("$*"); }
# manual: something the script cannot do for you. Always surfaced at the end.
manual() { MANUAL+=("$*"); }

summary() {
  heading "Summary"
  printf '  %s%d ok%s   %s%d skipped%s   %s%d failed%s\n' \
    "$C_GREEN" "${#STEPS_OK[@]}"   "$C_RESET" \
    "$C_DIM"   "${#STEPS_SKIP[@]}" "$C_RESET" \
    "$C_RED"   "${#STEPS_FAIL[@]}" "$C_RESET"

  if ((${#STEPS_FAIL[@]})); then
    printf '\n%sFailed steps%s — re-run this script to retry, they are idempotent:\n' \
      "$C_BOLD$C_RED" "$C_RESET"
    printf '  - %s\n' "${STEPS_FAIL[@]}"
  fi

  if ((${#NOTES[@]})); then
    printf '\n%sNotes%s\n' "$C_BOLD" "$C_RESET"
    printf '  - %s\n' "${NOTES[@]}"
  fi

  if ((${#MANUAL[@]})); then
    printf '\n%sManual steps required — the script cannot do these for you%s\n' \
      "$C_BOLD$C_YELLOW" "$C_RESET"
    # One printf per item: a multi-placeholder format would cycle and swallow
    # the colour arguments into the list.
    local m
    for m in "${MANUAL[@]}"; do
      printf '  %s*%s %s\n' "$C_YELLOW" "$C_RESET" "$m"
    done
  fi

  printf '\n'
  ((${#STEPS_FAIL[@]} == 0))
}

# --------------------------------------------------------------- dry-run ----

DRY_RUN="${DRY_RUN:-0}"

# run <cmd...> — execute, or print under --dry-run. Returns the command's status.
run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s  would run:%s %s\n' "$C_DIM" "$C_RESET" "$*"
    return 0
  fi
  "$@"
}

# run_sh <shell-string> — same, for pipelines/redirection that `run` cannot take.
run_sh() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s  would run:%s %s\n' "$C_DIM" "$C_RESET" "$1"
    return 0
  fi
  bash -c "$1"
}

# ----------------------------------------------------------- idempotency ----

have()     { command -v "$1" >/dev/null 2>&1; }
is_wsl()   { [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/version 2>/dev/null; }
is_root()  { [[ "$(id -u)" -eq 0 ]]; }

# sudo_ok — true if we can obtain root without an interactive prompt hanging us.
sudo_ok() {
  is_root && return 0
  have sudo || return 1
  sudo -n true 2>/dev/null && return 0
  # Cached credentials absent; a prompt is acceptable in an interactive run.
  [[ -t 0 ]]
}

as_root() {
  if is_root; then run "$@"; else run sudo "$@"; fi
}

# ensure_line <file> <line> — append if the exact line is absent. Idempotent.
ensure_line() {
  local file="$1" line="$2"
  if [[ -f "$file" ]] && grep -qxF -- "$line" "$file"; then
    return 1   # already present
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s  would append to %s:%s %s\n' "$C_DIM" "$file" "$C_RESET" "$line"
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$line" >> "$file"
  return 0
}

# ensure_block <file> <marker> — replace or append a managed block from stdin.
# Lets us own a region of a user's dotfile without clobbering the rest of it.
ensure_block() {
  local file="$1" marker="$2" body begin end tmp
  body="$(cat)"
  begin="# >>> ${marker} >>>"
  end="# <<< ${marker} <<<"

  local desired
  desired="${begin}"$'\n'"${body}"$'\n'"${end}"

  if [[ -f "$file" ]] && grep -qF "$begin" "$file"; then
    local existing
    existing="$(awk -v b="$begin" -v e="$end" \
      'index($0,b){f=1} f{print} index($0,e){f=0}' "$file")"
    [[ "$existing" == "$desired" ]] && return 1
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s  would manage block%s %s in %s\n' "$C_DIM" "$C_RESET" "$marker" "$file"
    return 0
  fi

  mkdir -p "$(dirname "$file")"
  touch "$file"
  tmp="$(mktemp)"
  # Strip any prior copy of the block, then append the new one.
  awk -v b="$begin" -v e="$end" \
    'index($0,b){f=1} !f{print} index($0,e){f=0}' "$file" > "$tmp"
  # Collapse trailing blank lines so repeated runs do not grow the file.
  printf '%s\n' "$(cat "$tmp")" > "$tmp.trim" && mv "$tmp.trim" "$tmp"
  { printf '\n%s\n' "$desired"; } >> "$tmp"
  mv "$tmp" "$file"
  return 0
}

# backup_once <path> — take a one-time .bak before first modification.
backup_once() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  [[ -e "${path}.pre-laptop.bak" ]] && return 0
  run cp -a "$path" "${path}.pre-laptop.bak"
}

# fetch <url> <dest> — curl with sane retry/failure behaviour.
fetch() {
  local url="$1" dest="$2"
  run curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$dest" "$url"
}

# github_latest_tag <owner/repo> — latest release tag, empty on failure.
github_latest_tag() {
  curl -fsSL --retry 2 --connect-timeout 10 \
    "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
    | grep -m1 '"tag_name"' | cut -d'"' -f4
}

arch_uname() { uname -m; }

# arch_go — GOARCH-style name, which most release tarballs use.
arch_go() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) echo "$(uname -m)" ;;
  esac
}

VERIFY_ONLY="${VERIFY_ONLY:-0}"

# want <name> — in --verify mode, report presence instead of installing.
# Usage:  want foo || install_foo
want() {
  local cmd="$1"
  if have "$cmd"; then
    mark_skip "$cmd" "already installed"
    return 0
  fi
  if [[ "$VERIFY_ONLY" == "1" ]]; then
    mark_fail "$cmd" "MISSING"
    return 0   # verify mode never installs
  fi
  return 1
}
