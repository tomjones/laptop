#!/usr/bin/env bash
# desc: bash config, readline tuning, git defaults, the secrets command
# profiles/10-shell.sh — shell, readline, and git configuration.
#
# Manages a marked block inside ~/.bashrc rather than replacing the file, so
# your own edits survive re-runs and upgrades of this script.
#
# Two things this avoids, both common in hand-grown dotfiles:
#   - RVM sourced from several rc files at once, each redoing the same PATH
#     work. Here it is sourced exactly once.
#   - pyenv initialised unconditionally on every interactive shell, so a broken
#     or half-removed install poisons every new terminal. Here it is guarded.
#
# shellcheck shell=bash

step "shell: ~/.local/bin on PATH"
if run mkdir -p "$HOME/.local/bin"; then mark_ok "shell: ~/.local/bin"; else mark_fail "shell: ~/.local/bin"; fi

step "shell: managed bashrc block"
if [[ "$DRY_RUN" == "1" ]]; then
  skip "would manage the 'laptop' block in ~/.bashrc"
  mark_skip "shell: managed bashrc block" "dry run"
else
  if ensure_block "$HOME/.bashrc" "laptop" <<'BLOCK'
# Managed by ~/laptop/setup.sh. Edit outside these markers; this region is
# rewritten on every run.

# --- PATH ---------------------------------------------------------------
[[ -d "$HOME/.local/bin" ]] && case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;;
esac
export PATH

# --- node (nvm) ---------------------------------------------------------
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh"
[[ -s "$NVM_DIR/bash_completion" ]] && . "$NVM_DIR/bash_completion"

# --- python -------------------------------------------------------------
# Guarded: only initialise pyenv if it is actually usable. An unconditional
# `eval "$(pyenv init --path)"` against a broken install poisons every shell.
if [[ -x "$HOME/.pyenv/bin/pyenv" ]]; then
  export PYENV_ROOT="$HOME/.pyenv"
  case ":$PATH:" in *":$PYENV_ROOT/bin:"*) ;; *) PATH="$PYENV_ROOT/bin:$PATH" ;; esac
  eval "$("$HOME/.pyenv/bin/pyenv" init --path 2>/dev/null)" || true
fi

# --- ruby (rvm) ---------------------------------------------------------
# Sourced exactly once. RVM insists on being last in PATH.
if [[ -s "$HOME/.rvm/scripts/rvm" ]]; then
  case ":$PATH:" in *":$HOME/.rvm/bin:"*) ;; *) PATH="$PATH:$HOME/.rvm/bin" ;; esac
  . "$HOME/.rvm/scripts/rvm"
fi

# --- bun ----------------------------------------------------------------
if [[ -d "$HOME/.bun" ]]; then
  export BUN_INSTALL="$HOME/.bun"
  case ":$PATH:" in *":$BUN_INSTALL/bin:"*) ;; *) PATH="$BUN_INSTALL/bin:$PATH" ;; esac
fi

export PATH

# --- history ------------------------------------------------------------
HISTCONTROL=ignoreboth:erasedups
HISTSIZE=50000
HISTFILESIZE=100000
shopt -s histappend checkwinsize

# --- aliases ------------------------------------------------------------
alias ll='ls -alFh'
alias la='ls -A'
alias gs='git status --short --branch'
alias gl='git log --oneline --graph --decorate -20'
command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1 && alias fd=fdfind
command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1 && alias bat=batcat
BLOCK
  then
    mark_ok "shell: managed bashrc block"
  else
    mark_skip "shell: managed bashrc block" "already current"
  fi
fi

# Keep login shells routed through .bashrc. Without this, `bash -l` and ssh
# sessions silently miss everything configured above.
step "shell: .bash_profile"
if [[ "$DRY_RUN" == "1" ]]; then
  mark_skip "shell: .bash_profile" "dry run"
elif ensure_block "$HOME/.bash_profile" "laptop" <<'BLOCK'
[[ -f "$HOME/.profile" ]] && . "$HOME/.profile"
[[ -f "$HOME/.bashrc"  ]] && . "$HOME/.bashrc"
BLOCK
then
  mark_ok "shell: .bash_profile"
else
  mark_skip "shell: .bash_profile" "already current"
fi

# Easy to forget, and worth having: single-tab completion
# listing, case-insensitive matching, Tab/Shift-Tab cycling.
step "shell: readline config (~/.inputrc)"
if [[ ! -f "${LAPTOP_DIR}/files/inputrc" ]]; then
  mark_skip "shell: readline config" "no payload"
elif [[ -f "$HOME/.inputrc" ]] && ! diff -q "${LAPTOP_DIR}/files/inputrc" "$HOME/.inputrc" >/dev/null 2>&1; then
  mark_skip "shell: readline config" "~/.inputrc exists and differs — not overwriting"
  note "Existing ~/.inputrc left alone. Compare with ${LAPTOP_DIR}/files/inputrc if you want the tuned version."
elif run cp "${LAPTOP_DIR}/files/inputrc" "$HOME/.inputrc"; then
  mark_ok "shell: readline config"
else
  mark_fail "shell: readline config"
fi

# ------------------------------------------------------------------- git ----

step "git: identity"
if [[ -n "$(git config --global user.email 2>/dev/null)" ]]; then
  mark_skip "git: identity" "already set ($(git config --global user.email))"
else
  mark_skip "git: identity" "not set"
  manual "Set your git identity: git config --global user.name 'Your Name' && git config --global user.email you@example.com"
fi

step "git: defaults"
if [[ "$DRY_RUN" == "1" ]]; then
  mark_skip "git: defaults" "dry run"
else
  git config --global init.defaultBranch main
  git config --global pull.rebase true
  git config --global fetch.prune true
  git config --global diff.colorMoved zebra
  git config --global rerere.enabled true
  git config --global push.autoSetupRemote true
  mark_ok "git: defaults"
fi

# gh as the credential helper is what makes a single `gh auth login` restore
# push access for every HTTPS remote at once.
step "git: credential helper"
if [[ "$DRY_RUN" == "1" ]]; then
  mark_skip "git: credential helper" "dry run"
elif have gh && [[ "$(command -v gh)" != /mnt/* ]]; then
  git config --global --replace-all "credential.https://github.com.helper" "" 2>/dev/null
  git config --global --add "credential.https://github.com.helper" "!$(command -v gh) auth git-credential"
  mark_ok "git: credential helper (gh)"
else
  mark_skip "git: credential helper" "gh not installed yet — re-run after the cloud profile"
fi

# ----------------------------------------------------------- secrets tool ----

step "shell: secrets command"
if [[ ! -f "${LAPTOP_DIR}/files/bin/secrets" ]]; then
  mark_skip "shell: secrets command" "no payload"
elif run install -m 0755 "${LAPTOP_DIR}/files/bin/secrets" "$HOME/.local/bin/secrets"; then
  mark_ok "shell: secrets command -> ~/.local/bin/secrets"
else
  mark_fail "shell: secrets command"
fi

# ------------------------------------------------------------------- ssh ----

step "ssh: agent config"
if [[ "$DRY_RUN" == "1" ]]; then
  mark_skip "ssh: agent config" "dry run"
else
  run mkdir -p "$HOME/.ssh"; run chmod 700 "$HOME/.ssh"
  if ensure_block "$HOME/.ssh/config" "laptop" <<'BLOCK'
Host *
    AddKeysToAgent yes
    IdentitiesOnly yes
    ServerAliveInterval 60
BLOCK
  then
    chmod 600 "$HOME/.ssh/config" 2>/dev/null
    mark_ok "ssh: agent config"
  else
    mark_skip "ssh: agent config" "already current"
  fi
fi

# Passphrase-less private keys are the norm on developer machines and the reason
# a stolen laptop is a production incident. AddKeysToAgent above means you type
# each passphrase once per session, not once per connection.
if [[ -d "$HOME/.ssh" ]] && [[ "$DRY_RUN" != "1" ]]; then
  _bare=0
  for k in "$HOME"/.ssh/id_* "$HOME"/.ssh/*.pem; do
    [[ -f "$k" ]] || continue
    [[ "$k" == *.pub ]] && continue
    grep -q 'ENCRYPTED' "$k" 2>/dev/null || _bare=$((_bare+1))
  done
  if ((_bare)); then
    note "${_bare} SSH private key(s) have no passphrase. Add one with: ssh-keygen -p -f <keyfile>"
  fi
  unset _bare
fi
