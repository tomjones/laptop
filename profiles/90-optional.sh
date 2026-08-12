#!/usr/bin/env bash
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
