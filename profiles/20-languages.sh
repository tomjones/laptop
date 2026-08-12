#!/usr/bin/env bash
# profiles/20-languages.sh — language runtimes and their version managers.
#
# Deliberately opinionated about versions. Dev machines accumulate runtimes:
# six Node versions, three divergent global CLI copies, and a pyenv Python whose
# pip could not execute. This installs one current version of each and leaves
# adding more to you.
#
# shellcheck shell=bash

NODE_VERSION="${NODE_VERSION:-22}"
RUBY_VERSION="${RUBY_VERSION:-3.2.7}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"

# ------------------------------------------------------------------ node ----

step "node: nvm"
if [[ -d "$HOME/.nvm" ]]; then
  mark_skip "" "~/.nvm exists"
else
  NVM_TAG="$(github_latest_tag nvm-sh/nvm)"; NVM_TAG="${NVM_TAG:-v0.40.1}"
  if run_sh "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_TAG}/install.sh | PROFILE=/dev/null bash"; then
    mark_ok "node: nvm ${NVM_TAG}"
  else
    mark_fail "node: nvm" "installer failed"
  fi
fi

step "node: v${NODE_VERSION}"
if [[ "$DRY_RUN" == "1" ]]; then
  skip "would install node ${NODE_VERSION} via nvm and set it as default"
  mark_skip "node: v${NODE_VERSION}" "dry run"
elif [[ -s "$HOME/.nvm/nvm.sh" ]]; then
  # nvm is a shell function, so it has to be sourced rather than executed.
  if bash -c '. "$HOME/.nvm/nvm.sh" && nvm install '"$NODE_VERSION"' && nvm alias default '"$NODE_VERSION" >/dev/null 2>&1; then
    mark_ok "node: v${NODE_VERSION} (default)"
  else
    mark_fail "node: v${NODE_VERSION}" "nvm install failed"
  fi
else
  mark_fail "node: v${NODE_VERSION}" "nvm not available"
fi

# ---------------------------------------------------------------- python ----

# uv handles both Python versions and tool installs, and is dramatically faster
# than the pyenv+pipx pair it replaces. pyenv is still installed below because
# existing projects may still reference it.
step "python: uv"
if want uv; then :; else
  if run_sh 'curl -fsSL https://astral.sh/uv/install.sh | sh'; then
    mark_ok "python: uv"
  else
    mark_fail "python: uv" "installer failed"
  fi
fi

step "python: cpython ${PYTHON_VERSION} via uv"
if [[ "$DRY_RUN" == "1" ]]; then
  mark_skip "python: cpython ${PYTHON_VERSION}" "dry run"
elif have uv || [[ -x "$HOME/.local/bin/uv" ]]; then
  UV_BIN="$(command -v uv || echo "$HOME/.local/bin/uv")"
  if run "$UV_BIN" python install "$PYTHON_VERSION"; then
    mark_ok "python: cpython ${PYTHON_VERSION}"
  else
    mark_fail "python: cpython ${PYTHON_VERSION}" "uv python install failed"
  fi
else
  mark_skip "python: cpython ${PYTHON_VERSION}" "uv unavailable"
fi

step "python: pyenv"
if [[ -d "$HOME/.pyenv" ]]; then
  mark_skip "" "~/.pyenv exists"
else
  if run git clone --depth 1 https://github.com/pyenv/pyenv.git "$HOME/.pyenv"; then
    mark_ok "python: pyenv"
    note "pyenv installed but no version built. 'pyenv global system' is the safe default; use uv for new work."
  else
    mark_fail "python: pyenv" "clone failed"
  fi
fi

step "python: pipx"
if want pipx; then :; else
  if pkg_install pipx; then mark_ok "python: pipx"; else mark_fail "python: pipx"; fi
fi

# ------------------------------------------------------------------ ruby ----

step "ruby: rvm"
if [[ -d "$HOME/.rvm" ]]; then
  mark_skip "" "~/.rvm exists"
elif [[ "$DRY_RUN" == "1" ]]; then
  skip "would install RVM and ruby ${RUBY_VERSION}"
  mark_skip "ruby: rvm" "dry run"
else
  # RVM's installer wants the release-signing keys present first.
  run_sh 'gpg2 --keyserver hkp://keyserver.ubuntu.com --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3 7D2BAF1CF37B13E2069D6956105BD0E739499BDB' >/dev/null 2>&1 \
    || warn "could not fetch RVM signing keys; falling back to unverified install"
  if run_sh 'curl -fsSL https://get.rvm.io | bash -s stable'; then
    mark_ok "ruby: rvm"
  else
    mark_fail "ruby: rvm" "installer failed"
  fi
fi

step "ruby: ${RUBY_VERSION}"
if [[ "$DRY_RUN" == "1" ]]; then
  mark_skip "ruby: ${RUBY_VERSION}" "dry run"
elif [[ -s "$HOME/.rvm/scripts/rvm" ]]; then
  if bash -lc '. "$HOME/.rvm/scripts/rvm" && rvm install '"$RUBY_VERSION"' && rvm --default use '"$RUBY_VERSION" >/dev/null 2>&1; then
    mark_ok "ruby: ${RUBY_VERSION} (default)"
  else
    mark_fail "ruby: ${RUBY_VERSION}" "rvm install failed — check 'rvm requirements'"
  fi
else
  mark_skip "ruby: ${RUBY_VERSION}" "rvm not available"
fi

# ------------------------------------------------------------------- bun ----

step "bun"
if [[ -d "$HOME/.bun" ]]; then
  mark_skip "" "~/.bun exists"
else
  if run_sh 'curl -fsSL https://bun.sh/install | bash'; then
    mark_ok "bun"
  else
    mark_fail "bun" "installer failed"
  fi
fi
