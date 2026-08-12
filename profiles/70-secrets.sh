#!/usr/bin/env bash
# desc: age, sops, gitleaks, and the encrypted secrets store
# profiles/70-secrets.sh — encrypted secret store, plus guardrails.
#
# Design (see "Secrets Management Standard" in Obsidian for the reasoning):
#
#   Store      ~/.secrets/<project>.env, SOPS-encrypted. Not a git repo, never
#              pushed. Variable names stay readable; only values are encrypted.
#   Recipients age supports many recipients per file and ANY ONE can decrypt —
#              genuine OR semantics. We provision:
#                1. a daily identity whose key file is passphrase-encrypted
#                2. (phase 2) a FIDO2 security key, touch to decrypt
#                3. a paper recovery identity, printed and stored offline
#   Runtime    `secrets <project> -- <cmd>` puts values in one child process's
#              environment. Nothing plaintext ever lands on disk.
#
# This script never writes a secret. It installs tooling and generates key
# material only when you ask it to, interactively.
#
# shellcheck shell=bash

SECRETS_DIR="${SECRETS_DIR:-$HOME/.secrets}"
AGE_DIR="$HOME/.config/age"

step "secrets: age"
if want age; then :; else
  if pkg_install age; then
    mark_ok "secrets: age"
  else
    # Not packaged everywhere; fall back to the upstream release.
    _tag="$(github_latest_tag FiloSottile/age)"; _tag="${_tag:-v1.2.1}"
    _tmp="$(mktemp -d)"
    if fetch "https://github.com/FiloSottile/age/releases/download/${_tag}/age-${_tag}-linux-$(arch_go).tar.gz" "$_tmp/age.tgz" \
       && run tar -xzf "$_tmp/age.tgz" -C "$_tmp" \
       && run mkdir -p "$HOME/.local/bin" \
       && run install -m 0755 "$_tmp/age/age" "$_tmp/age/age-keygen" "$HOME/.local/bin/"
    then
      mark_ok "secrets: age ${_tag}"
    else
      mark_fail "secrets: age" "no package and release download failed"
    fi
    run rm -rf "$_tmp"; unset _tmp _tag
  fi
fi

step "secrets: sops"
if want sops; then :; else
  _tag="$(github_latest_tag getsops/sops)"; _tag="${_tag:-v3.9.1}"
  _tmp="$(mktemp -d)"
  if fetch "https://github.com/getsops/sops/releases/download/${_tag}/sops-${_tag}.linux.$(arch_go)" "$_tmp/sops" \
     && run mkdir -p "$HOME/.local/bin" \
     && run install -m 0755 "$_tmp/sops" "$HOME/.local/bin/sops"
  then
    mark_ok "secrets: sops ${_tag}"
  else
    mark_fail "secrets: sops" "release download failed"
  fi
  run rm -rf "$_tmp"; unset _tmp _tag
fi

# Guardrail. Committed API keys are among the most common real-world leaks,
# and a pre-commit hook is the cheapest thing that prevents one.
step "secrets: gitleaks"
if want gitleaks; then :; else
  _tag="$(github_latest_tag gitleaks/gitleaks)"; _tag="${_tag:-v8.21.2}"
  _ver="${_tag#v}"
  _tmp="$(mktemp -d)"
  if fetch "https://github.com/gitleaks/gitleaks/releases/download/${_tag}/gitleaks_${_ver}_linux_$(arch_go).tar.gz" "$_tmp/gl.tgz" \
     && run tar -xzf "$_tmp/gl.tgz" -C "$_tmp" \
     && run mkdir -p "$HOME/.local/bin" \
     && run install -m 0755 "$_tmp/gitleaks" "$HOME/.local/bin/gitleaks"
  then
    mark_ok "secrets: gitleaks ${_tag}"
  else
    mark_fail "secrets: gitleaks" "release download failed"
  fi
  run rm -rf "$_tmp"; unset _tmp _ver _tag
fi

# --------------------------------------------------------- global ignores ----

step "secrets: global gitignore"
_gi="$HOME/.config/git/ignore"
if [[ "$DRY_RUN" == "1" ]]; then
  mark_skip "secrets: global gitignore" "dry run"
else
  run mkdir -p "$(dirname "$_gi")"
  _added=0
  for pat in '.env' '.env.*' '!.env.example' '!.env.template' '*.pem' '*.p12' '*.pfx' \
             'credentials.json' 'service-account*.json' '.envrc.local' \
             '**/.claude/settings.local.json'; do
    ensure_line "$_gi" "$pat" && _added=1
  done
  if ((_added)); then mark_ok "secrets: global gitignore patterns"; else mark_skip "secrets: global gitignore" "already current"; fi
  unset _added
fi
unset _gi

# A template hook, installed into git's init templates so every NEW repo gets
# it automatically. Existing repos need `git init` re-run or a manual copy.
step "secrets: git pre-commit template"
_tpl="$HOME/.config/git/template/hooks"
if [[ "$DRY_RUN" == "1" ]]; then
  mark_skip "secrets: git pre-commit template" "dry run"
else
  run mkdir -p "$_tpl"
  if cat > "$_tpl/pre-commit" <<'HOOK'
#!/usr/bin/env bash
# Block commits containing secrets. Bypass deliberately with --no-verify.
command -v gitleaks >/dev/null 2>&1 || exit 0
if ! gitleaks protect --staged --redact --no-banner --verbose; then
  echo
  echo "gitleaks blocked this commit. Remove the secret, or use --no-verify if it is a false positive."
  exit 1
fi
HOOK
  then
    chmod +x "$_tpl/pre-commit"
    git config --global init.templateDir "$HOME/.config/git/template"
    mark_ok "secrets: git pre-commit template"
    manual "The pre-commit hook applies to NEW repos. For existing ones: 'git init' inside each (safe, re-applies templates) or copy ~/.config/git/template/hooks/pre-commit into .git/hooks/."
  else
    mark_fail "secrets: git pre-commit template"
  fi
fi
unset _tpl

# ----------------------------------------------------------- the store ----

step "secrets: store directory"
if [[ -d "$SECRETS_DIR" ]]; then
  mark_skip "secrets: store directory" "$SECRETS_DIR exists"
elif run mkdir -p "$SECRETS_DIR" && run chmod 700 "$SECRETS_DIR"; then
  mark_ok "secrets: store directory ($SECRETS_DIR, mode 700)"
else
  mark_fail "secrets: store directory"
fi

step "secrets: age identity"
if [[ -f "$AGE_DIR/identity.age" ]]; then
  mark_skip "secrets: age identity" "already provisioned"
elif [[ "$DRY_RUN" == "1" ]]; then
  skip "would generate a passphrase-protected age identity at $AGE_DIR/identity.age"
  mark_skip "secrets: age identity" "dry run"
else
  # Not generated automatically: it needs a passphrase you choose interactively,
  # and generating key material behind someone's back is the wrong default.
  mark_skip "secrets: age identity" "not provisioned"
  manual "Provision your secret store: run '${LAPTOP_DIR}/files/bin/secrets init'. It generates the daily identity, prints the paper recovery key, and writes ~/.sops.yaml."
fi

# ------------------------------------------------ FIDO2 / security key ----

step "secrets: FIDO2 plugin (optional)"
if have age-plugin-fido2-hmac; then
  mark_skip "secrets: FIDO2 plugin" "already installed"
elif [[ "${ENABLE_FIDO2:-0}" != "1" ]]; then
  mark_skip "secrets: FIDO2 plugin" "set ENABLE_FIDO2=1 to install"
  note "Security key support is phase 2 — see 'Secrets Management Standard'. It needs usbipd-win on the Windows side before WSL can see the key at all."
elif [[ "$DRY_RUN" == "1" ]]; then
  mark_skip "secrets: FIDO2 plugin" "dry run"
else
  _tag="$(github_latest_tag olastor/age-plugin-fido2-hmac)"; _tag="${_tag:-v0.3.0}"
  _tmp="$(mktemp -d)"
  if fetch "https://github.com/olastor/age-plugin-fido2-hmac/releases/download/${_tag}/age-plugin-fido2-hmac-${_tag}-linux-$(arch_go).tar.gz" "$_tmp/p.tgz" \
     && run tar -xzf "$_tmp/p.tgz" -C "$_tmp" \
     && run install -m 0755 "$_tmp/age-plugin-fido2-hmac" "$HOME/.local/bin/"
  then
    mark_ok "secrets: FIDO2 plugin ${_tag}"
    manual "Confirm your key supports the hmac-secret extension: 'fido2-token -I \$(fido2-token -L | cut -d: -f1)' and look for 'hmac-secret' in extensions."
  else
    mark_fail "secrets: FIDO2 plugin" "release download failed"
  fi
  run rm -rf "$_tmp"; unset _tmp _tag
fi

if is_wsl && ! [[ -d /dev/bus/usb ]]; then
  note "No USB passthrough in this WSL distro, so a security key is invisible here. Install usbipd-win on Windows ('winget install usbipd'), then 'usbipd bind' once and 'usbipd attach --wsl' per session."
fi
