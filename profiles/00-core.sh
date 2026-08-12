#!/usr/bin/env bash
# desc: build toolchain, everyday CLI, and shell ergonomics
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

# ------------------------------------------------------------ ergonomics ----

# tmux earns its place specifically because the alternative people reach for is
# `nohup ... &`, which orphans the process with no way to reattach and no
# scrollback when it misbehaves.
step "core: tmux, direnv, fzf, bat"
if pkg_install tmux direnv fzf bat; then
  mark_ok
  # Debian ships bat as batcat to avoid a name clash with the 'bacula' tools.
  if have batcat && ! have bat; then
    run mkdir -p "$HOME/.local/bin"
    run ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"
  fi
else
  mark_fail "" "package install failed"
fi

step "core: git-delta (better diffs)"
if want delta; then :; else
  if pkg_install git-delta; then
    mark_ok "core: git-delta"
  else
    _tag="$(github_latest_tag dandavison/delta)"; _tag="${_tag:-0.18.2}"
    _tmp="$(mktemp -d)"
    if fetch "https://github.com/dandavison/delta/releases/download/${_tag}/delta-${_tag}-$(arch_uname)-unknown-linux-gnu.tar.gz" "$_tmp/d.tgz" \
       && run tar -xzf "$_tmp/d.tgz" -C "$_tmp" --strip-components=1 \
       && run install -m 0755 "$_tmp/delta" "$HOME/.local/bin/delta"
    then mark_ok "core: git-delta ${_tag}"; else mark_fail "core: git-delta"; fi
    run rm -rf "$_tmp"; unset _tmp _tag
  fi
fi

# Deliberately the Go yq (mikefarah), not Debian's python3-yq, which is a
# different tool with a different syntax that happens to share the name.
step "core: yq (YAML processor)"
if want yq; then :; else
  _tag="$(github_latest_tag mikefarah/yq)"; _tag="${_tag:-v4.44.3}"
  if fetch "https://github.com/mikefarah/yq/releases/download/${_tag}/yq_linux_$(arch_go)" /tmp/yq \
     && run install -m 0755 /tmp/yq "$HOME/.local/bin/yq"
  then mark_ok "core: yq ${_tag}"; else mark_fail "core: yq"; fi
  run rm -f /tmp/yq; unset _tag
fi
