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

# Ordered. Numeric prefixes give the run order; the short name is the CLI handle.
PROFILE_ORDER=(core shell languages docker databases cloud tunnels claude secrets wsl optional)

profile_file() {
  case "$1" in
    core)      echo "00-core.sh" ;;
    shell)     echo "10-shell.sh" ;;
    languages) echo "20-languages.sh" ;;
    docker)    echo "30-docker.sh" ;;
    databases) echo "40-databases.sh" ;;
    cloud)     echo "50-cloud-cli.sh" ;;
    tunnels)   echo "55-tunnels.sh" ;;
    claude)    echo "60-claude.sh" ;;
    secrets)   echo "70-secrets.sh" ;;
    wsl)       echo "80-wsl.sh" ;;
    optional)  echo "90-optional.sh" ;;
    *)         echo "" ;;
  esac
}

profile_desc() {
  case "$1" in
    core)      echo "base CLI tools and the build toolchain native extensions need" ;;
    shell)     echo "bash config, readline tuning, git config, the secrets wrapper" ;;
    languages) echo "node (nvm), python (pyenv/uv/pipx), ruby (rvm), bun" ;;
    docker)    echo "native docker-ce engine + compose plugin (not Docker Desktop)" ;;
    databases) echo "PostgreSQL and Redis, with hardened defaults rather than stock" ;;
    cloud)     echo "aws, gh, sf, stripe, heroku, abctl" ;;
    tunnels)   echo "cloudflared, ngrok, tailscale + the 'share' command" ;;
    claude)    echo "Claude Code, its config payload, commands, skills, monitor" ;;
    secrets)   echo "age, sops, the secrets store, gitleaks guardrails" ;;
    wsl)       echo "WSL-specific wiring: systemd, Windows symlinks, .wslconfig" ;;
    optional)  echo "opt-in extras: mkcert, d2, visidata, playwright, apache+adminer" ;;
    *)         echo "" ;;
  esac
}

# Everything except `optional`, which is opt-in by design (it can install a
# web-served database console — see the Environment Map for why that matters).
DEFAULT_PROFILES=(core shell languages docker databases cloud tunnels claude secrets wsl)

usage() {
  cat <<EOF
${C_BOLD}setup.sh${C_RESET} — rebuild this development environment.

${C_BOLD}Usage${C_RESET}
  ./setup.sh [options] [profile ...]

${C_BOLD}Options${C_RESET}
  --all         run every profile except 'optional'
  --dry-run     print every action without performing any of them
  --verify      report which components are missing; install nothing
  --list        list profiles and exit
  -h, --help    this message

${C_BOLD}Profiles${C_RESET}
EOF
  local p
  for p in "${PROFILE_ORDER[@]}"; do
    printf '  %-11s %s\n' "$p" "$(profile_desc "$p")"
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

while (($#)); do
  case "$1" in
    --all)      RUN_ALL=1 ;;
    --dry-run)  DRY_RUN=1 ;;
    --verify)   VERIFY_ONLY=1; DRY_RUN=1 ;;
    --list)     usage; exit 0 ;;
    -h|--help)  usage; exit 0 ;;
    -*)         die "Unknown option: $1  (try --help)" ;;
    *)
      if [[ -z "$(profile_file "$1")" ]]; then
        die "Unknown profile: $1  (try --list)"
      fi
      REQUESTED+=("$1")
      ;;
  esac
  shift
done

export DRY_RUN VERIFY_ONLY

if ((RUN_ALL)); then
  REQUESTED=("${DEFAULT_PROFILES[@]}")
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

if [[ "$SUPPORT_TIER" -eq 3 ]]; then
  warn "Tier 3 distro: package names are mapped best-effort. Unmapped items are skipped and listed at the end."
fi

if [[ "$DRY_RUN" != "1" ]] && ! sudo_ok; then
  warn "sudo is unavailable or requires a password that cannot be prompted for here."
  warn "System package steps will fail. Run from an interactive shell, or pre-authorise with 'sudo -v'."
fi

for p in "${PROFILES[@]}"; do
  f="${LAPTOP_DIR}/profiles/$(profile_file "$p")"
  if [[ ! -r "$f" ]]; then
    mark_fail "profile:$p" "missing $f"
    continue
  fi
  heading "[$p] $(profile_desc "$p")"
  # Subshell-free on purpose: profiles contribute to the shared step accounting.
  # shellcheck source=/dev/null
  . "$f"
done

summary
