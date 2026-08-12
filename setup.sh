#!/usr/bin/env bash
# setup.sh — rebuild this development environment on a fresh Linux box.
#
#   ./setup.sh --list                 show available profiles
#   ./setup.sh core shell languages   run selected profiles
#   ./setup.sh --all                  run everything except opt-in extras
#   ./setup.sh --all --dry-run        show every action, change nothing
#   ./setup.sh --verify               report what is missing, install nothing
#
# Machine layer only: tooling, services, and configuration. It does not clone
# your repositories and it never writes a secret — it installs the tooling and
# then tells you exactly what you need to authenticate by hand.
#
# Safe to re-run. Every step checks before it acts.

set -uo pipefail

LAPTOP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export LAPTOP_DIR

# shellcheck source=lib/common.sh
. "${LAPTOP_DIR}/lib/common.sh"
# shellcheck source=lib/distro.sh
. "${LAPTOP_DIR}/lib/distro.sh"

# ------------------------------------------------------ profile discovery ----
#
# Profiles are discovered from profiles/NN-name.sh. The numeric prefix sets run
# order; everything after it is the name you type. Two optional header lines,
# read from the file itself, keep the metadata next to the code rather than in
# a table here that drifts out of sync:
#
#   # desc: one-line description, shown by --list
#   # default: no        exclude from --all (opt-in only)

declare -a PROFILE_ORDER=()
declare -A PROFILE_FILE=() PROFILE_DESC=() PROFILE_DEFAULT=()

discover_profiles() {
  local f base name
  for f in "${LAPTOP_DIR}"/profiles/[0-9][0-9]-*.sh; do
    [[ -r "$f" ]] || continue
    base="$(basename "$f")"
    name="${base#*-}"; name="${name%.sh}"
    PROFILE_ORDER+=("$name")
    PROFILE_FILE[$name]="$f"
    PROFILE_DESC[$name]="$(sed -n 's/^# desc: //p' "$f" | head -1)"
    if grep -q '^# default: no' "$f"; then
      PROFILE_DEFAULT[$name]=0
    else
      PROFILE_DEFAULT[$name]=1
    fi
  done
}

discover_profiles
((${#PROFILE_ORDER[@]})) || die "no profiles found in ${LAPTOP_DIR}/profiles/"

default_profiles() {
  local p
  for p in "${PROFILE_ORDER[@]}"; do
    [[ "${PROFILE_DEFAULT[$p]}" == "1" ]] && printf '%s\n' "$p"
  done
}

usage() {
  cat <<EOF
${C_BOLD}setup.sh${C_RESET} — rebuild this development environment.

${C_BOLD}Usage${C_RESET}
  ./setup.sh [options] [profile ...]

${C_BOLD}Options${C_RESET}
  --all         run every profile except opt-in ones
  --dry-run     print every action without performing any of them
  --verify      report which components are missing; install nothing
  --list        list profiles and exit
  --no-log      do not write a run log
  -h, --help    this message

${C_BOLD}Profiles${C_RESET}
EOF
  local p mark
  for p in "${PROFILE_ORDER[@]}"; do
    mark=""; [[ "${PROFILE_DEFAULT[$p]}" == "0" ]] && mark=" ${C_DIM}(opt-in)${C_RESET}"
    printf '  %-11s %s%b\n' "$p" "${PROFILE_DESC[$p]}" "$mark"
  done
  cat <<EOF

${C_BOLD}Examples${C_RESET}
  ./setup.sh --list
  ./setup.sh core shell languages
  ./setup.sh --all --dry-run
  ./setup.sh --verify
EOF
}

# ------------------------------------------------------------ arg parsing ----

declare -a REQUESTED=()
RUN_ALL=0
WRITE_LOG=1

while (($#)); do
  case "$1" in
    --all)      RUN_ALL=1 ;;
    --dry-run)  DRY_RUN=1 ;;
    --verify)   VERIFY_ONLY=1; DRY_RUN=1 ;;
    --no-log)   WRITE_LOG=0 ;;
    --list)     usage; exit 0 ;;
    -h|--help)  usage; exit 0 ;;
    -*)         die "Unknown option: $1  (try --help)" ;;
    *)
      [[ -n "${PROFILE_FILE[$1]:-}" ]] || die "Unknown profile: $1  (try --list)"
      REQUESTED+=("$1")
      ;;
  esac
  shift
done

export DRY_RUN VERIFY_ONLY

if ((RUN_ALL)); then
  mapfile -t REQUESTED < <(default_profiles)
elif ((${#REQUESTED[@]} == 0)); then
  usage
  exit 0
fi

# Preserve canonical order regardless of the order given on the command line,
# because e.g. `languages` genuinely depends on `core` having run first.
declare -a PROFILES=()
for p in "${PROFILE_ORDER[@]}"; do
  for r in "${REQUESTED[@]}"; do
    [[ "$p" == "$r" ]] && { PROFILES+=("$p"); break; }
  done
done

# --------------------------------------------------------------- run log ----
#
# An --all run produces several hundred lines. Without this, the detail of what
# was skipped and why scrolls away exactly when you need it to debug a partial
# rebuild.
LOG=""
if ((WRITE_LOG)); then
  LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/laptop"
  mkdir -p "$LOG_DIR" 2>/dev/null && LOG="${LOG_DIR}/setup-$(date +%Y%m%dT%H%M%S).log"
  if [[ -n "$LOG" ]]; then
    exec > >(tee -a "$LOG") 2>&1
    # Keep the ten most recent runs.
    # shellcheck disable=SC2012
    ls -1t "$LOG_DIR"/setup-*.log 2>/dev/null | tail -n +11 | xargs -r rm -f
  fi
fi

# ----------------------------------------------------------------- run it ----

heading "Environment rebuild"
detect_distro
describe_distro
require_supported_distro || exit 1

if [[ "$VERIFY_ONLY" == "1" ]]; then
  printf '  mode   : %sverify — reporting only, nothing will be installed%s\n' \
    "$C_YELLOW" "$C_RESET"
elif [[ "$DRY_RUN" == "1" ]]; then
  printf '  mode   : %sdry run — nothing will be changed%s\n' "$C_YELLOW" "$C_RESET"
fi
printf '  profiles: %s\n' "${PROFILES[*]}"
[[ -n "$LOG" ]] && printf '  log     : %s\n' "$LOG"

if [[ "$SUPPORT_TIER" -eq 3 ]]; then
  warn "Tier 3 distro: package names are mapped best-effort. Unmapped items are skipped and listed at the end."
fi

if [[ "$DRY_RUN" != "1" ]] && ! sudo_ok; then
  warn "sudo is unavailable or requires a password that cannot be prompted for here."
  warn "System package steps will fail. Run from an interactive shell, or pre-authorise with 'sudo -v'."
fi

for p in "${PROFILES[@]}"; do
  f="${PROFILE_FILE[$p]}"
  heading "[$p] ${PROFILE_DESC[$p]}"
  # Sourced, not subshelled, so profiles contribute to the shared accounting.
  # shellcheck source=/dev/null
  . "$f"
done

summary
rc=$?

# Let the tee subprocess drain before the shell exits, or the tail of the run
# can be missing from the log file.
if [[ -n "$LOG" ]]; then
  exec 1>&- 2>&-
  wait 2>/dev/null || true
fi
exit "$rc"
