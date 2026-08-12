#!/usr/bin/env bash
# profiles/50-cloud-cli.sh — cloud and SaaS command-line tools.
#
# None of these are authenticated by this script. Every one of them prints a
# manual re-auth step instead, collected in the summary. That list is the real
# deliverable here: it is what stands between a rebuilt machine and a working one.
#
# shellcheck shell=bash

# ------------------------------------------------------------------- aws ----

step "aws: CLI v2"
if want aws; then :; else
  _tmp="$(mktemp -d)"
  if fetch "https://awscli.amazonaws.com/awscli-exe-linux-$(arch_uname).zip" "$_tmp/awscliv2.zip" \
     && run unzip -q "$_tmp/awscliv2.zip" -d "$_tmp" \
     && as_root "$_tmp/aws/install" --update
  then
    mark_ok "aws: CLI v2"
  else
    mark_fail "aws: CLI v2" "bundle install failed"
  fi
  run rm -rf "$_tmp"
  unset _tmp
fi
manual "AWS: 'aws configure' or 'aws sso login'. In WSL you may prefer symlinking ~/.aws to the Windows profile — the wsl profile offers this."

# -------------------------------------------------------------------- gh ----

# gh matters more than it looks. If git's credential helper is
# 'gh auth git-credential', a single 'gh auth login' restores push access
# for every HTTPS remote at once. It must be the Linux gh, not the Windows one
# that WSL puts on PATH.
step "gh: GitHub CLI"
if have gh && [[ "$(command -v gh)" != /mnt/* ]]; then
  mark_skip "gh: GitHub CLI" "already installed"
elif [[ "$PKG_FAMILY" == "debian" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    skip "would add the GitHub CLI apt repo and install gh"
    mark_skip "gh: GitHub CLI" "dry run"
  else
    as_root mkdir -p /etc/apt/keyrings
    if run_sh "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null" \
      && as_root chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
      && run_sh "echo 'deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main' | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null"
    then
      _APT_UPDATED=0
      if pkg_install gh; then mark_ok "gh: GitHub CLI"; else mark_fail "gh: GitHub CLI"; fi
    else
      mark_fail "gh: GitHub CLI" "could not configure apt repo"
    fi
  fi
else
  if pkg_install gh; then mark_ok "gh: GitHub CLI"; else mark_fail "gh: GitHub CLI"; fi
fi
manual "GitHub: 'gh auth login'. This also restores git push for every HTTPS remote, via the gh credential helper."

# ------------------------------------------------------------ salesforce ----

# Installed against whichever node nvm has made default, so that `sf` is
# actually on PATH in a fresh shell. A common failure is having it installed
# under an older Node version and reachable from none by default.
step "sf: Salesforce CLI"
if [[ "$DRY_RUN" == "1" ]]; then
  skip "would npm install -g @salesforce/cli on the default node"
  mark_skip "sf: Salesforce CLI" "dry run"
elif [[ -s "$HOME/.nvm/nvm.sh" ]]; then
  if bash -c '. "$HOME/.nvm/nvm.sh" && nvm use default >/dev/null && npm install -g @salesforce/cli' >/dev/null 2>&1; then
    mark_ok "sf: Salesforce CLI (on default node)"
  else
    mark_fail "sf: Salesforce CLI" "npm install failed"
  fi
elif have npm; then
  if run npm install -g @salesforce/cli; then mark_ok "sf: Salesforce CLI"; else mark_fail "sf: Salesforce CLI"; fi
else
  mark_skip "sf: Salesforce CLI" "no node/npm — run the languages profile first"
fi
manual "Salesforce: re-auth each org with 'sf org login web --alias <alias>'. See the credential checklist in the Environment Map for the full alias list."

# ---------------------------------------------------------------- stripe ----

step "stripe: CLI"
if want stripe; then :; else
  if [[ "$PKG_FAMILY" == "debian" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      mark_skip "stripe: CLI" "dry run"
    else
      if run_sh "curl -fsSL https://packages.stripe.dev/api/security/keypair/stripe-cli-gpg/public | gpg --dearmor | sudo tee /usr/share/keyrings/stripe.gpg >/dev/null" \
        && run_sh "echo 'deb [signed-by=/usr/share/keyrings/stripe.gpg] https://packages.stripe.dev/stripe-cli-debian-local stable main' | sudo tee /etc/apt/sources.list.d/stripe.list >/dev/null"
      then
        _APT_UPDATED=0
        if pkg_install stripe; then mark_ok "stripe: CLI"; else mark_fail "stripe: CLI"; fi
      else
        mark_fail "stripe: CLI" "could not configure apt repo"
      fi
    fi
  else
    mark_skip "stripe: CLI" "no ${PKG_FAMILY} package; install from GitHub releases"
    note "stripe CLI: grab a release from github.com/stripe/stripe-cli/releases"
  fi
fi
manual "Stripe: 'stripe login'."

# ngrok, cloudflared and tailscale live in the 'tunnels' profile — they answer
# a different question ("how do I reach this box from outside") than the cloud
# provider CLIs here.

# ---------------------------------------------------------------- heroku ----

step "heroku: CLI"
if want heroku; then :; else
  if [[ "$DRY_RUN" == "1" ]]; then
    mark_skip "heroku: CLI" "dry run"
  elif run_sh 'curl -fsSL https://cli-assets.heroku.com/install.sh | sh'; then
    mark_ok "heroku: CLI"
  else
    mark_fail "heroku: CLI" "installer failed"
  fi
fi
manual "Heroku: 'heroku login'. Note the old ~/.netrc stored these in plaintext — do not restore that file."

# ----------------------------------------------------------------- abctl ----

step "abctl: Airbyte CLI"
if want abctl; then :; else
  if [[ "$DRY_RUN" == "1" ]]; then
    mark_skip "abctl: Airbyte CLI" "dry run"
  elif run_sh 'curl -fsSL https://connectors.airbyte.com/files/abctl/install.sh | bash'; then
    mark_ok "abctl: Airbyte CLI"
  else
    mark_fail "abctl: Airbyte CLI" "installer failed"
  fi
fi
