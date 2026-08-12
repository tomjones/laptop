#!/usr/bin/env bash
# profiles/55-tunnels.sh — remote access and link sharing.
#
# Three tools, three jobs. Installing only one of them is how you end up using
# the wrong one out of habit:
#
#   cloudflared  Stable named hostnames on a domain you already control, and
#                Cloudflare Access can put SSO in front for free. Best choice
#                for anything a client will see, or anything touching real data.
#   ngrok        Fastest throwaway link. Free tier gives a random URL that
#                changes each restart, one agent at a time, and an interstitial
#                warning page on HTTP tunnels.
#   tailscale    Private mesh. The service never becomes public at all — the
#                right answer whenever the audience is you or a colleague
#                rather than the internet.
#
# None of these are authenticated here; each prints its own manual step.
#
# shellcheck shell=bash

step "tunnels: cloudflared"
if want cloudflared; then :; else
  if [[ "$PKG_FAMILY" == "debian" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      skip "would add the Cloudflare apt repo and install cloudflared"
      mark_skip "tunnels: cloudflared" "dry run"
    else
      as_root mkdir -p --mode=0755 /usr/share/keyrings
      if run_sh "curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null" \
        && run_sh "echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null"
      then
        _APT_UPDATED=0
        if pkg_install cloudflared; then mark_ok "tunnels: cloudflared"; else mark_fail "tunnels: cloudflared"; fi
      else
        mark_fail "tunnels: cloudflared" "could not configure apt repo"
      fi
    fi
  else
    # Single static binary; the repo only exists for Debian-likes.
    if fetch "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$(arch_go)" /tmp/cloudflared \
       && run install -m 0755 /tmp/cloudflared "$HOME/.local/bin/cloudflared"
    then
      mark_ok "tunnels: cloudflared"
    else
      mark_fail "tunnels: cloudflared" "release download failed"
    fi
    run rm -f /tmp/cloudflared
  fi
fi
manual "Cloudflare Tunnel: 'cloudflared tunnel login' once, then 'cloudflared tunnel create <name>' and route DNS to it. Quick throwaway links need no login at all: 'cloudflared tunnel --url http://localhost:PORT'."

step "tunnels: ngrok"
if want ngrok; then :; else
  if [[ "$PKG_FAMILY" == "debian" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      mark_skip "tunnels: ngrok" "dry run"
    else
      as_root mkdir -p /etc/apt/keyrings
      # Upstream publishes a single 'buster' suite regardless of your release.
      if run_sh "curl -fsSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc | sudo tee /etc/apt/keyrings/ngrok.asc >/dev/null" \
        && run_sh "echo 'deb [signed-by=/etc/apt/keyrings/ngrok.asc] https://ngrok-agent.s3.amazonaws.com buster main' | sudo tee /etc/apt/sources.list.d/ngrok.list >/dev/null"
      then
        _APT_UPDATED=0
        if pkg_install ngrok; then mark_ok "tunnels: ngrok"; else mark_fail "tunnels: ngrok"; fi
      else
        mark_fail "tunnels: ngrok" "could not configure apt repo"
      fi
    fi
  else
    mark_skip "tunnels: ngrok" "no ${PKG_FAMILY} package; see ngrok.com/download"
  fi
fi
manual "ngrok: 'ngrok config add-authtoken <token>' from your dashboard."

# Tailscale is a daemon rather than a CLI, so it needs systemd to be useful.
step "tunnels: tailscale"
if want tailscale; then :; else
  if [[ "$DRY_RUN" == "1" ]]; then
    skip "would install tailscale via the official installer"
    mark_skip "tunnels: tailscale" "dry run"
  elif run_sh 'curl -fsSL https://tailscale.com/install.sh | sh'; then
    mark_ok "tunnels: tailscale"
  else
    mark_fail "tunnels: tailscale" "installer failed"
  fi
fi

if have tailscale && [[ "$DRY_RUN" != "1" ]]; then
  if [[ -d /run/systemd/system ]]; then
    svc_enable tailscaled >/dev/null 2>&1 \
      && note "tailscaled enabled — run 'sudo tailscale up' to join your tailnet"
  else
    manual "tailscaled needs systemd. Enable it first (WSL: systemd=true in /etc/wsl.conf), then 'sudo tailscale up'."
  fi
fi
manual "Tailscale: 'sudo tailscale up' to join your tailnet. For a public URL without exposing a port: 'tailscale funnel <port>'."

# ------------------------------------------------------------------ share ----

step "tunnels: share command"
if [[ ! -f "${LAPTOP_DIR}/files/bin/share" ]]; then
  mark_skip "tunnels: share command" "no payload"
elif run install -m 0755 "${LAPTOP_DIR}/files/bin/share" "$HOME/.local/bin/share"; then
  mark_ok "tunnels: share command -> ~/.local/bin/share"
else
  mark_fail "tunnels: share command"
fi

note "A tunnel forwards a port straight from the internet to this machine, bypassing every network boundary. Tunnel a specific app port, never 80, and never a database port. The 'share' command refuses the dangerous ones unless you pass --force."
