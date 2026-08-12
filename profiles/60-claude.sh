#!/usr/bin/env bash
# profiles/60-claude.sh — Claude Code and its surrounding configuration.
#
# Often the highest-value layer on a working machine, and the easiest to lose,
# because almost none of it comes from a package manager:
#
#   1. ~/.claude/commands/*.md — your own slash commands. Bespoke by definition,
#      so they exist nowhere but this directory and your backups.
#   2. ~/.claude/skills/ and anything under ~/.claude/lib/ they depend on.
#   3. Any hook target. Hooks in settings.json invoke scripts by ABSOLUTE path;
#      if the target is not restored to exactly that path, every hook fails on
#      every event, usually silently.
#
# Payloads come from files/claude/, which `capture.sh --payload` populates from
# a live machine. They are gitignored — see README, "Keeping it current".
#
# shellcheck shell=bash

CLAUDE_DIR="$HOME/.claude"
MONITOR_DIR="${MONITOR_DIR:-$HOME/claude-code-monitor}"
PAYLOAD="${LAPTOP_DIR}/files/claude"

step "claude: CLI"
if have claude && [[ "$(command -v claude)" == "$HOME/.local/bin/claude" ]]; then
  mark_skip "claude: CLI" "native install present ($(claude --version 2>/dev/null | head -1))"
elif [[ "$DRY_RUN" == "1" ]]; then
  skip "would install Claude Code via the native installer"
  mark_skip "claude: CLI" "dry run"
else
  # Native installer, not npm. It is easy to end up with both, where the stale
  # npm copy is shadowed only by PATH ordering — a confusing thing to debug.
  if run_sh 'curl -fsSL https://claude.ai/install.sh | bash'; then
    mark_ok "claude: CLI"
  else
    mark_fail "claude: CLI" "installer failed"
  fi
fi
manual "Claude Code: run 'claude' once and complete the OAuth login."

step "claude: config directories"
if run mkdir -p "$CLAUDE_DIR"/{commands,skills,lib,plans}; then
  mark_ok "claude: config directories"
else
  mark_fail "claude: config directories"
fi

step "claude: settings.json"
if [[ -f "$CLAUDE_DIR/settings.json" ]]; then
  mark_skip "claude: settings.json" "exists — not overwriting"
elif [[ -f "$PAYLOAD/settings.json" ]]; then
  if run cp "$PAYLOAD/settings.json" "$CLAUDE_DIR/settings.json" && run chmod 600 "$CLAUDE_DIR/settings.json"; then
    mark_ok "claude: settings.json"
    if grep -q '__SET_ME__' "$PAYLOAD/settings.json" 2>/dev/null; then
      manual "Edit ~/.claude/settings.json and replace __SET_ME__ with the claude-code-monitor token (printed by the monitor at startup)."
    fi
  else
    mark_fail "claude: settings.json"
  fi
else
  mark_skip "claude: settings.json" "no payload — run capture.sh on a live box first"
fi

step "claude: commands and skills"
_restored=0
for sub in commands skills lib; do
  if [[ -d "$PAYLOAD/$sub" ]] && [[ -n "$(ls -A "$PAYLOAD/$sub" 2>/dev/null)" ]]; then
    run cp -rn "$PAYLOAD/$sub/." "$CLAUDE_DIR/$sub/" 2>/dev/null
    _restored=1
  fi
done
if ((_restored)); then
  mark_ok "claude: commands and skills restored"
else
  mark_skip "claude: commands and skills" "no payload — run capture.sh on a live box first"
fi
unset _restored

# The /qc-data command renders PDFs from a dedicated venv, not the system python.
step "claude: qc-data venv"
if [[ -d "$CLAUDE_DIR/venv" ]]; then
  mark_skip "claude: qc-data venv" "exists"
elif [[ ! -f "$CLAUDE_DIR/lib/qc_report_pdf.py" ]]; then
  mark_skip "claude: qc-data venv" "qc_report_pdf.py not present"
elif [[ "$DRY_RUN" == "1" ]]; then
  mark_skip "claude: qc-data venv" "dry run"
else
  if run python3 -m venv "$CLAUDE_DIR/venv" \
     && run "$CLAUDE_DIR/venv/bin/pip" install --quiet reportlab markdown-it-py rich; then
    mark_ok "claude: qc-data venv"
  else
    mark_fail "claude: qc-data venv"
  fi
fi

# ------------------------------------------------------- claude-code-monitor ----

step "claude: monitor repo"
if [[ -d "$MONITOR_DIR/.git" ]]; then
  mark_skip "claude: monitor repo" "already cloned"
elif [[ "$DRY_RUN" == "1" ]]; then
  skip "would clone claude-code-monitor to $MONITOR_DIR"
  mark_skip "claude: monitor repo" "dry run"
elif run git clone https://github.com/bruceyxli/claude-code-monitor.git "$MONITOR_DIR"; then
  mark_ok "claude: monitor repo"
else
  mark_fail "claude: monitor repo" "clone failed"
fi

step "claude: monitor dependencies"
if [[ ! -f "$MONITOR_DIR/package.json" ]]; then
  mark_skip "claude: monitor dependencies" "repo not present"
elif [[ -d "$MONITOR_DIR/node_modules" ]]; then
  mark_skip "claude: monitor dependencies" "node_modules present"
elif [[ "$DRY_RUN" == "1" ]]; then
  mark_skip "claude: monitor dependencies" "dry run"
elif [[ -s "$HOME/.nvm/nvm.sh" ]]; then
  if bash -c ". \"\$HOME/.nvm/nvm.sh\" && nvm use default >/dev/null && cd '$MONITOR_DIR' && npm install" >/dev/null 2>&1; then
    mark_ok "claude: monitor dependencies"
  else
    mark_fail "claude: monitor dependencies" "npm install failed"
  fi
else
  mark_skip "claude: monitor dependencies" "no node available"
fi

# The monitor's default bind is 0.0.0.0, and its feature set includes remote
# approval of tool-permission prompts. That combination is a remote control
# plane for an agent with shell access, so loopback is the right default.
if [[ -d "$MONITOR_DIR" ]]; then
  note "claude-code-monitor binds 0.0.0.0:7888 by default and can remotely approve tool permissions. Bind it to 127.0.0.1 unless you genuinely need LAN access."
  manual "claude-code-monitor: its data/config.json holds an API token — chmod 600 it, and keep the token out of any file you commit."
fi

# ---------------------------------------------------------------- extras ----

step "claude: claude-swap (profile switcher)"
if have cswap || have claude-swap; then
  mark_skip "claude: claude-swap" "already installed"
elif [[ "$DRY_RUN" == "1" ]]; then
  mark_skip "claude: claude-swap" "dry run"
elif have uv || [[ -x "$HOME/.local/bin/uv" ]]; then
  UV_BIN="$(command -v uv || echo "$HOME/.local/bin/uv")"
  if run "$UV_BIN" tool install claude-swap; then
    mark_ok "claude: claude-swap"
  else
    mark_fail "claude: claude-swap" "uv tool install failed"
  fi
else
  mark_skip "claude: claude-swap" "uv not available"
fi

manual "MCP servers: remote ones are OAuth-brokered, so no credential is copied. Reconnect each from inside Claude Code. Your server list is in ~/.claude.json under mcpServers — capture it before a rebuild if you want the list itself."
