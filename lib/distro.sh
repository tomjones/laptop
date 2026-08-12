#!/usr/bin/env bash
# lib/distro.sh — distro detection and a cross-family package abstraction.
#
# Support tiers:
#   1  verified   — Debian 12/13. The environment this was built from and tested on.
#   2  expected   — Ubuntu LTS. Same apt path, spot-checked, no reason to fail.
#   3  best-effort— Fedora/RHEL, Arch. Names are mapped where an equivalent exists;
#                   where none does, the step is skipped loudly rather than faked.
#   0  refused    — anything else. We stop rather than half-install.
#
# shellcheck shell=bash

DISTRO_ID=""; DISTRO_VERSION=""; DISTRO_NAME=""; DISTRO_LIKE=""
PKG_FAMILY=""; SUPPORT_TIER=0; PKG_MGR=""

detect_distro() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_VERSION="${VERSION_ID:-}"
    DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"
    DISTRO_LIKE="${ID_LIKE:-}"
  else
    DISTRO_ID="unknown"; DISTRO_NAME="unknown"
  fi

  case "$DISTRO_ID" in
    debian)
      PKG_FAMILY=debian; PKG_MGR=apt
      case "${DISTRO_VERSION%%.*}" in
        12|13) SUPPORT_TIER=1 ;;
        *)     SUPPORT_TIER=2 ;;
      esac
      ;;
    ubuntu|linuxmint|pop|elementary|raspbian)
      PKG_FAMILY=debian; PKG_MGR=apt; SUPPORT_TIER=2 ;;
    fedora)
      PKG_FAMILY=rhel; PKG_MGR=dnf; SUPPORT_TIER=3 ;;
    rhel|centos|rocky|almalinux|ol)
      PKG_FAMILY=rhel; PKG_MGR=dnf; SUPPORT_TIER=3 ;;
    arch|manjaro|endeavouros|cachyos)
      PKG_FAMILY=arch; PKG_MGR=pacman; SUPPORT_TIER=3 ;;
    *)
      # Fall back to ID_LIKE before giving up entirely.
      case " $DISTRO_LIKE " in
        *" debian "*) PKG_FAMILY=debian; PKG_MGR=apt;    SUPPORT_TIER=3 ;;
        *" rhel "*|*" fedora "*) PKG_FAMILY=rhel; PKG_MGR=dnf; SUPPORT_TIER=3 ;;
        *" arch "*)   PKG_FAMILY=arch;   PKG_MGR=pacman; SUPPORT_TIER=3 ;;
        *)            PKG_FAMILY=unknown; SUPPORT_TIER=0 ;;
      esac
      ;;
  esac
}

describe_distro() {
  local tier_label
  case "$SUPPORT_TIER" in
    1) tier_label="${C_GREEN}tier 1 — verified${C_RESET}" ;;
    2) tier_label="${C_GREEN}tier 2 — expected to work${C_RESET}" ;;
    3) tier_label="${C_YELLOW}tier 3 — best effort, gaps are skipped loudly${C_RESET}" ;;
    *) tier_label="${C_RED}unsupported${C_RESET}" ;;
  esac
  printf '  distro : %s\n  family : %s (%s)\n  support: %b\n' \
    "$DISTRO_NAME" "$PKG_FAMILY" "${PKG_MGR:-none}" "$tier_label"
  is_wsl && printf '  wsl    : yes (%s)\n' "${WSL_DISTRO_NAME:-unknown}"
}

require_supported_distro() {
  if [[ "$SUPPORT_TIER" -eq 0 ]]; then
    error "Unsupported distribution: ${DISTRO_NAME}"
    error "Package family could not be determined from ID='${DISTRO_ID}' ID_LIKE='${DISTRO_LIKE}'."
    error "Refusing to continue rather than half-install. Supported: Debian, Ubuntu, Fedora/RHEL, Arch."
    return 1
  fi
  return 0
}

# ------------------------------------------------------ package name map ----
#
# Canonical names are the Debian ones. A value of "-" means "no equivalent on
# this family" and the caller skips it with a warning rather than failing.
# Multi-package values are space-separated and installed together.

_pkg_map_rhel() {
  case "$1" in
    build-essential)     echo "gcc gcc-c++ make" ;;
    libssl-dev)          echo "openssl-devel" ;;
    libffi-dev)          echo "libffi-devel" ;;
    zlib1g-dev)          echo "zlib-devel" ;;
    libbz2-dev)          echo "bzip2-devel" ;;
    libreadline-dev)     echo "readline-devel" ;;
    libsqlite3-dev)      echo "sqlite-devel" ;;
    libncurses5-dev)     echo "ncurses-devel" ;;
    liblzma-dev)         echo "xz-devel" ;;
    libgdbm-dev)         echo "gdbm-devel" ;;
    libyaml-dev)         echo "libyaml-devel" ;;
    libgmp-dev)          echo "gmp-devel" ;;
    tk-dev)              echo "tk-devel" ;;
    libpq-dev)           echo "libpq-devel" ;;
    libfido2-dev)        echo "libfido2-devel" ;;
    python3-venv)        echo "python3" ;;
    python3-pip)         echo "python3-pip" ;;
    python3-dev)         echo "python3-devel" ;;
    postgresql)          echo "postgresql-server" ;;
    postgresql-contrib)  echo "postgresql-contrib" ;;
    redis-server)        echo "redis" ;;
    apache2)             echo "httpd" ;;
    libapache2-mod-php)  echo "php" ;;
    php-pgsql)           echo "php-pgsql" ;;
    dnsutils)            echo "bind-utils" ;;
    silversearcher-ag)   echo "the_silver_searcher" ;;
    universal-ctags)     echo "ctags" ;;
    poppler-utils)       echo "poppler-utils" ;;
    imagemagick)         echo "ImageMagick" ;;
    fd-find)             echo "fd-find" ;;
    apt-transport-https) echo "-" ;;
    gnupg2)              echo "gnupg2" ;;
    pcscd)               echo "pcsc-lite" ;;
    scdaemon)            echo "gnupg2-smime" ;;
    netcat-openbsd)      echo "nmap-ncat" ;;
    *)                   echo "$1" ;;
  esac
}

_pkg_map_arch() {
  case "$1" in
    build-essential)     echo "base-devel" ;;
    libssl-dev)          echo "openssl" ;;
    libffi-dev)          echo "libffi" ;;
    zlib1g-dev)          echo "zlib" ;;
    libbz2-dev)          echo "bzip2" ;;
    libreadline-dev)     echo "readline" ;;
    libsqlite3-dev)      echo "sqlite" ;;
    libncurses5-dev)     echo "ncurses" ;;
    liblzma-dev)         echo "xz" ;;
    libgdbm-dev)         echo "gdbm" ;;
    libyaml-dev)         echo "libyaml" ;;
    libgmp-dev)          echo "gmp" ;;
    tk-dev)              echo "tk" ;;
    libpq-dev)           echo "postgresql-libs" ;;
    libfido2-dev)        echo "libfido2" ;;
    python3-venv)        echo "python" ;;
    python3-pip)         echo "python-pip" ;;
    python3-dev)         echo "python" ;;
    python3)             echo "python" ;;
    postgresql)          echo "postgresql" ;;
    postgresql-contrib)  echo "-" ;;
    redis-server)        echo "redis" ;;
    apache2)             echo "apache" ;;
    libapache2-mod-php)  echo "php-apache" ;;
    php-pgsql)           echo "php-pgsql" ;;
    dnsutils)            echo "bind" ;;
    silversearcher-ag)   echo "the_silver_searcher" ;;
    universal-ctags)     echo "ctags" ;;
    poppler-utils)       echo "poppler" ;;
    imagemagick)         echo "imagemagick" ;;
    fd-find)             echo "fd" ;;
    apt-transport-https) echo "-" ;;
    gnupg2)              echo "gnupg" ;;
    pcscd)               echo "pcsclite" ;;
    scdaemon)            echo "gnupg" ;;
    netcat-openbsd)      echo "openbsd-netcat" ;;
    lsb-release)         echo "lsb-release" ;;
    *)                   echo "$1" ;;
  esac
}

# pkg_map <canonical> — resolved name(s) for this family, or "-" if unavailable.
pkg_map() {
  case "$PKG_FAMILY" in
    debian) echo "$1" ;;
    rhel)   _pkg_map_rhel "$1" ;;
    arch)   _pkg_map_arch "$1" ;;
    *)      echo "-" ;;
  esac
}

# ------------------------------------------------------ package commands ----

_APT_UPDATED=0

pkg_refresh() {
  case "$PKG_FAMILY" in
    debian)
      [[ "$_APT_UPDATED" == "1" ]] && return 0
      as_root apt-get update -qq && _APT_UPDATED=1 ;;
    rhel)   as_root "$PKG_MGR" -q makecache ;;
    arch)   as_root pacman -Sy --noconfirm ;;
  esac
}

pkg_installed() {
  case "$PKG_FAMILY" in
    debian) dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -q '^installed$' ;;
    rhel)   rpm -q "$1" >/dev/null 2>&1 ;;
    arch)   pacman -Qi "$1" >/dev/null 2>&1 ;;
    *)      return 1 ;;
  esac
}

# pkg_install <canonical...> — resolves names, filters what is already present,
# installs the remainder in one transaction. Idempotent and quiet when satisfied.
pkg_install() {
  local -a wanted=() unavailable=()
  local canonical resolved p

  for canonical in "$@"; do
    resolved="$(pkg_map "$canonical")"
    if [[ "$resolved" == "-" ]]; then
      unavailable+=("$canonical")
      continue
    fi
    for p in $resolved; do
      pkg_installed "$p" || wanted+=("$p")
    done
  done

  if ((${#unavailable[@]})); then
    warn "no ${PKG_FAMILY} equivalent, skipping: ${unavailable[*]}"
    note "skipped on ${PKG_FAMILY}: ${unavailable[*]}"
  fi

  ((${#wanted[@]})) || return 0

  pkg_refresh
  case "$PKG_FAMILY" in
    debian)
      DEBIAN_FRONTEND=noninteractive \
        as_root apt-get install -y -qq --no-install-recommends "${wanted[@]}" ;;
    rhel)  as_root "$PKG_MGR" install -y "${wanted[@]}" ;;
    arch)  as_root pacman -S --needed --noconfirm "${wanted[@]}" ;;
  esac
}

# svc_enable <unit> — enable+start if systemd is actually running (it is in this
# WSL distro because /etc/wsl.conf sets systemd=true; it may not be elsewhere).
svc_enable() {
  local unit="$1"
  if ! have systemctl || [[ ! -d /run/systemd/system ]]; then
    warn "systemd not running; cannot enable ${unit}"
    manual "Start '${unit}' by hand, or enable systemd (WSL: put 'systemd=true' under [boot] in /etc/wsl.conf, then 'wsl --shutdown')"
    return 0
  fi
  as_root systemctl enable --now "$unit"
}

svc_active() {
  have systemctl && systemctl is-active --quiet "$1"
}
