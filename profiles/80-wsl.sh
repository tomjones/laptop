#!/usr/bin/env bash
# desc: WSL wiring: systemd, Windows symlinks, .wslconfig
# profiles/80-wsl.sh — WSL-specific wiring. No-ops cleanly on bare metal.
# shellcheck shell=bash

if ! is_wsl; then
  mark_skip "wsl: all steps" "not running under WSL"
  return 0 2>/dev/null || true
fi

# systemd is the load-bearing setting here. Without it there is no docker
# daemon, no postgresql service, no redis, no timers — most of this rebuild
# simply does not function.
step "wsl: systemd"
if [[ -d /run/systemd/system ]]; then
  mark_skip "wsl: systemd" "already running"
elif [[ "$DRY_RUN" == "1" ]]; then
  skip "would set systemd=true in /etc/wsl.conf"
  mark_skip "wsl: systemd" "dry run"
else
  backup_once /etc/wsl.conf
  if grep -qs '^systemd[[:space:]]*=[[:space:]]*true' /etc/wsl.conf; then
    mark_ok "wsl: systemd already configured (restart pending)"
    manual "Run 'wsl --shutdown' from Windows, then reopen this distro, to activate systemd."
  elif printf '[boot]\nsystemd=true\n' | as_root tee /etc/wsl.conf >/dev/null; then
    mark_ok "wsl: systemd=true written to /etc/wsl.conf"
    manual "Run 'wsl --shutdown' from Windows, then reopen this distro, to activate systemd."
  else
    mark_fail "wsl: systemd"
  fi
fi

# Sharing the Windows AWS profile avoids a second copy of your credentials and
# means `aws sso login` on either side works for both. Opt-in: it links your
# Linux home at a Windows path, which is not everyone's preference.
step "wsl: Windows credential symlinks"
_winhome=""
if have wslpath && have cmd.exe; then
  _winhome="$(wslpath "$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')" 2>/dev/null || true)"
fi
if [[ "${LINK_WINDOWS_CREDS:-0}" != "1" ]]; then
  mark_skip "wsl: Windows credential symlinks" "set LINK_WINDOWS_CREDS=1 to enable"
  [[ -n "$_winhome" ]] && note "Windows home detected at ${_winhome} — LINK_WINDOWS_CREDS=1 would symlink ~/.aws to it."
elif [[ -z "$_winhome" ]] || [[ ! -d "$_winhome" ]]; then
  mark_skip "wsl: Windows credential symlinks" "could not resolve the Windows home directory"
elif [[ "$DRY_RUN" == "1" ]]; then
  mark_skip "wsl: Windows credential symlinks" "dry run"
else
  _linked=0
  for d in .aws; do
    if [[ -e "$HOME/$d" ]] && [[ ! -L "$HOME/$d" ]]; then
      warn "$HOME/$d exists and is not a symlink; leaving it alone"
    elif [[ -d "$_winhome/$d" ]]; then
      ln -sfn "$_winhome/$d" "$HOME/$d" && _linked=1
    fi
  done
  if ((_linked)); then mark_ok "wsl: Windows credential symlinks"; else mark_skip "wsl: Windows credential symlinks" "nothing to link"; fi
  unset _linked
fi

# .wslconfig lives on the Windows side and governs the VM itself — memory, swap,
# CPU. It cannot be created from inside the guest in any reliable way, so we
# report rather than write.
step "wsl: .wslconfig"
if [[ -n "$_winhome" ]] && [[ -f "$_winhome/.wslconfig" ]]; then
  mark_ok "wsl: .wslconfig present at ${_winhome}/.wslconfig"
  note "Current .wslconfig: $(tr '\n' ' ' < "$_winhome/.wslconfig" 2>/dev/null | tr -s ' ')"
else
  mark_skip "wsl: .wslconfig" "not found"
  manual "Consider creating C:\\Users\\<you>\\.wslconfig with [wsl2] memory=16GB / swap=4GB, then 'wsl --shutdown'. It controls the VM and cannot be set from inside the guest."
fi
unset _winhome

# WSL regenerates these every boot; a rebuild should not try to restore them.
note "WSL regenerates /etc/hosts, /etc/hostname and /etc/resolv.conf on each boot — do not restore them from backup."
