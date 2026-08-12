#!/usr/bin/env bash
# profiles/00-core.sh — base CLI tooling and the build toolchain.
# shellcheck shell=bash

step "core: build toolchain"
if pkg_install build-essential autoconf automake bison libtool pkg-config; then
  mark_ok
else
  mark_fail "" "package install failed"
fi

# These headers are what let pyenv build a Python, and what psycopg2, nokogiri,
# and every other native extension link against. Missing one of them produces a
# baffling compile error three profiles later, so they go in up front.
step "core: native extension headers"
if pkg_install \
    libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
    libncurses5-dev liblzma-dev libgdbm-dev libyaml-dev libgmp-dev \
    libffi-dev tk-dev libpq-dev python3-dev; then
  mark_ok
else
  mark_fail "" "package install failed"
fi

step "core: everyday CLI"
if pkg_install \
    curl wget git vim nano less jq htop ncdu lsof rsync tree \
    unzip zip ca-certificates gnupg2 openssl sqlite3 dnsutils \
    graphviz python3 python3-pip python3-venv; then
  mark_ok
else
  mark_fail "" "package install failed"
fi

# libfido2 is the prerequisite for both FIDO2-backed SSH keys (ssh-keygen -t
# ed25519-sk) and the age FIDO2 plugin. Cheap to install, awkward to discover
# you are missing when a security key is already in your hand.
step "core: FIDO2 / security key support"
if pkg_install libfido2-dev pcscd; then
  mark_ok
else
  mark_fail "" "package install failed"
fi

# Modern search tools. Worth installing explicitly: on some systems `rg`
# resolves to a shell function proxying into another binary rather than to a
# real ripgrep, which is a confusing thing to debug.
step "core: modern search tools"
if pkg_install ripgrep fd-find; then
  mark_ok
  # Debian ships the binary as fdfind to avoid a name collision.
  if have fdfind && ! have fd; then
    run mkdir -p "$HOME/.local/bin"
    run ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
    note "linked fdfind -> ~/.local/bin/fd"
  fi
else
  mark_fail "" "package install failed"
fi

step "core: shellcheck (for maintaining these scripts)"
if pkg_install shellcheck; then mark_ok; else mark_fail "" "package install failed"; fi
