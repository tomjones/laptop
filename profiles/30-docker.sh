#!/usr/bin/env bash
# profiles/30-docker.sh — native Docker Engine, not Docker Desktop.
#
# Why native rather than Docker Desktop's WSL integration: with Desktop,
# /usr/bin/docker and /usr/local/bin/kubectl are symlinks into a share that is
# only mounted while the Windows app is running, so both dangle whenever it is
# not. That arrangement cannot be scripted, cannot start a container from cron
# or systemd, and cannot be rebuilt by a disaster-recovery script — which is
# precisely what this file exists to be. It also carries commercial licensing
# terms that a plain docker-ce install does not.
#
# systemd is required for the daemon. In WSL that means 'systemd=true' under
# [boot] in /etc/wsl.conf; the wsl profile sets it.
#
# shellcheck shell=bash

step "docker: remove Docker Desktop shims"
_shims_found=0
for shim in /usr/bin/docker /usr/bin/docker-compose /usr/local/bin/kubectl; do
  if [[ -L "$shim" ]] && [[ "$(readlink "$shim")" == /mnt/wsl/docker-desktop* ]]; then
    _shims_found=1
    if [[ ! -e "$shim" ]]; then
      if as_root rm -f "$shim"; then
        [[ "$DRY_RUN" == "1" ]] \
          && note "would remove dangling Docker Desktop shim: $shim" \
          || note "removed dangling Docker Desktop shim: $shim"
      fi
    else
      warn "$shim points at Docker Desktop and is currently live; leaving it alone"
      manual "Disable WSL integration for this distro in Docker Desktop settings, then remove $shim"
    fi
  fi
done
((_shims_found)) && mark_ok "docker: shims handled" || mark_skip "docker: shims" "none present"
unset _shims_found

step "docker: engine"
if have dockerd; then
  mark_skip "" "already installed"
elif [[ "$PKG_FAMILY" == "debian" ]]; then
  # Official Docker repo. Debian's own docker.io lags meaningfully behind.
  _codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  _distro_id="$(. /etc/os-release && echo "$ID")"
  if [[ -z "$_codename" ]]; then
    mark_fail "docker: engine" "cannot determine distro codename"
  else
    pkg_install ca-certificates curl
    as_root install -m 0755 -d /etc/apt/keyrings
    if [[ "$DRY_RUN" == "1" ]]; then
      skip "would add Docker apt repo for ${_distro_id}/${_codename} and install docker-ce"
      mark_skip "docker: engine" "dry run"
    else
      if run_sh "curl -fsSL https://download.docker.com/linux/${_distro_id}/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes" \
        && as_root chmod a+r /etc/apt/keyrings/docker.gpg \
        && run_sh "echo 'deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${_distro_id} ${_codename} stable' | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null"
      then
        _APT_UPDATED=0   # new repo, force a refresh
        if pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
          mark_ok "docker: engine"
        else
          mark_fail "docker: engine" "apt install failed"
        fi
      else
        mark_fail "docker: engine" "could not configure Docker apt repo"
      fi
    fi
  fi
  unset _codename _distro_id
elif [[ "$PKG_FAMILY" == "rhel" ]]; then
  as_root "$PKG_MGR" config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null \
    || warn "could not add docker repo"
  if pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
    mark_ok "docker: engine"
  else
    mark_fail "docker: engine"
  fi
elif [[ "$PKG_FAMILY" == "arch" ]]; then
  if pkg_install docker docker-buildx docker-compose; then
    mark_ok "docker: engine"
  else
    mark_fail "docker: engine"
  fi
fi

step "docker: group membership"
if id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
  mark_skip "" "$USER already in docker group"
else
  as_root groupadd -f docker
  if as_root usermod -aG docker "$USER"; then
    mark_ok "docker: added $USER to docker group"
    manual "Log out and back in (or run 'newgrp docker') before the docker socket is usable without sudo"
  else
    mark_fail "docker: group membership"
  fi
fi

step "docker: enable service"
if [[ "$DRY_RUN" == "1" ]]; then
  mark_skip "docker: enable service" "dry run"
elif [[ ! -d /run/systemd/system ]]; then
  mark_skip "docker: enable service" "systemd not running"
  manual "Enable systemd, then: sudo systemctl enable --now docker"
else
  if svc_enable docker; then mark_ok "docker: enabled"; else mark_fail "docker: enable service"; fi
fi
