#!/usr/bin/env bash
# desc: opt-in extras: mkcert, d2, visidata, playwright, adminer
# default: no
# profiles/90-optional.sh — opt-in extras. Never part of --all.
#
# Split out because one of these (apache + adminer) installs a web-served
# database console. Left at its defaults that is an unauthenticated superuser
# path to every database on the host, over plain HTTP. It is available here,
# but it has to be a deliberate choice rather than something you inherit.
#
# shellcheck shell=bash

step "optional: mkcert (local TLS)"
if want mkcert; then :; else
  _tag="$(github_latest_tag FiloSottile/mkcert)"; _tag="${_tag:-v1.4.4}"
  if fetch "https://github.com/FiloSottile/mkcert/releases/download/${_tag}/mkcert-${_tag}-linux-$(arch_go)" /tmp/mkcert \
     && run install -m 0755 /tmp/mkcert "$HOME/.local/bin/mkcert"
  then
    mark_ok "optional: mkcert ${_tag}"
    manual "mkcert: run 'mkcert -install' to trust the local CA, then re-issue dev certs. Old certs do not transfer — the CA is per-machine."
  else
    mark_fail "optional: mkcert"
  fi
  run rm -f /tmp/mkcert; unset _tag
fi

step "optional: d2 (diagrams)"
if want d2; then :; else
  if [[ "$DRY_RUN" == "1" ]]; then
    mark_skip "optional: d2" "dry run"
  elif run_sh 'curl -fsSL https://d2lang.com/install.sh | sh -s -- --prefix "$HOME/.local"'; then
    mark_ok "optional: d2"
  else
    mark_fail "optional: d2" "installer failed"
  fi
fi

step "optional: visidata"
if want vd; then :; else
  if have pipx; then
    if run pipx install visidata; then mark_ok "optional: visidata"; else mark_fail "optional: visidata"; fi
  else
    mark_skip "optional: visidata" "pipx not installed"
  fi
fi

step "optional: csvkit / data CLI"
if pkg_install csvkit pgloader; then mark_ok "optional: csvkit, pgloader"; else mark_fail "optional: csvkit, pgloader"; fi

# ------------------------------------------------------------- playwright ----

# The browsers themselves are ~450 MB per version and Playwright downloads them
# on demand, so there is no point backing them up or pre-installing them by
# default. What DOES break on a fresh machine is the system shared libraries
# chromium links against — the failure is a wall of "error while loading shared
# libraries" at first launch, long after you have forgotten this step exists.
step "optional: playwright system dependencies"
_pw_node=""
if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
  _pw_node='. "$HOME/.nvm/nvm.sh" >/dev/null 2>&1;'
elif ! have npx; then
  mark_skip "optional: playwright system dependencies" "no node/npx — run the languages profile first"
fi

if have npx || [[ -n "$_pw_node" ]]; then
  if [[ "$PKG_FAMILY" != "debian" ]]; then
    # Upstream only ships a dependency list for Debian/Ubuntu.
    mark_skip "optional: playwright system dependencies" "only supported on Debian/Ubuntu"
    note "Playwright: on ${PKG_FAMILY}, install chromium's runtime libraries via your distro's chromium package, then 'npx playwright install chromium'."
  elif [[ "$DRY_RUN" == "1" ]]; then
    skip "would run: npx playwright install-deps chromium"
    mark_skip "optional: playwright system dependencies" "dry run"
  elif run_sh "${_pw_node} sudo -E env PATH=\"\$PATH\" npx --yes playwright install-deps chromium"; then
    mark_ok "optional: playwright system dependencies"
  else
    mark_fail "optional: playwright system dependencies" "install-deps failed"
  fi
fi

step "optional: playwright chromium"
if [[ "${PLAYWRIGHT_BROWSERS:-0}" != "1" ]]; then
  mark_skip "optional: playwright chromium" "set PLAYWRIGHT_BROWSERS=1 to pre-download"
  note "Playwright browsers download on first use into ~/.cache/ms-playwright. They are pinned to the library version, so a project on a newer Playwright fetches its own copy rather than reusing an existing one — that cache only grows. Check it with 'du -sh ~/.cache/ms-playwright/*' and reclaim with 'npx playwright uninstall --all'."
elif [[ "$DRY_RUN" == "1" ]]; then
  mark_skip "optional: playwright chromium" "dry run"
elif run_sh "${_pw_node} npx --yes playwright install chromium"; then
  mark_ok "optional: playwright chromium"
else
  mark_fail "optional: playwright chromium" "download failed"
fi
unset _pw_node

# ------------------------------------------------------- apache + adminer ----

step "optional: apache + adminer"
if [[ "${ENABLE_ADMINER:-0}" != "1" ]]; then
  mark_skip "optional: apache + adminer" "set ENABLE_ADMINER=1 to install"
  note "Adminer is not installed by default. A single PHP file on port 80 with no auth in front of it is a superuser path into every database on the host, and it tends to long outlive the afternoon it was needed. Prefer psql, or a desktop client over localhost."
elif [[ "$DRY_RUN" == "1" ]]; then
  mark_skip "optional: apache + adminer" "dry run"
else
  if pkg_install apache2 libapache2-mod-php php-pgsql; then
    _webroot=/var/www/html
    _latest="$(github_latest_tag vrana/adminer)"; _latest="${_latest:-v4.8.1}"
    if as_root curl -fsSL -o "$_webroot/adminer.php" \
         "https://github.com/vrana/adminer/releases/download/${_latest}/adminer-${_latest#v}.php"
    then
      as_root chmod 0644 "$_webroot/adminer.php"
      mark_ok "optional: apache + adminer ${_latest}"
    else
      mark_fail "optional: adminer download"
    fi

    # Loopback-only by default. Reachable from Windows via localhost forwarding,
    # not from the network.
    if printf 'Listen 127.0.0.1:80\n' | as_root tee /etc/apache2/ports.conf >/dev/null 2>&1; then
      note "Apache bound to 127.0.0.1:80 only."
    fi
    svc_enable apache2
    manual "Adminer is installed with NO authentication in front of it. Add HTTP basic auth and TLS before exposing it beyond loopback."
    unset _webroot _latest
  else
    mark_fail "optional: apache + adminer" "package install failed"
  fi
fi
