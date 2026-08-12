#!/usr/bin/env bash
# desc: JDK for the Apex language server, plus sf CLI plugins
#
# profiles/52-salesforce.sh — Salesforce development tooling.
#
# The `sf` CLI itself comes from the cloud profile. What lives here is the part
# that is easy to miss: the Apex Language Server is a Java process. Install the
# Salesforce VS Code extension pack without a JDK and everything *looks* fine —
# the extensions load, syntax highlighting works — but code completion,
# go-to-definition, and test running silently do nothing. There is no error
# that points at Java.
#
# shellcheck shell=bash

JDK_VERSION="${JDK_VERSION:-17}"     # Salesforce supports 11, 17, and 21

step "salesforce: JDK ${JDK_VERSION}"
if have java; then
  mark_skip "salesforce: JDK" "already installed ($(java -version 2>&1 | head -1))"
elif pkg_install "openjdk-${JDK_VERSION}-jdk-headless"; then
  mark_ok "salesforce: JDK ${JDK_VERSION}"
elif pkg_install default-jdk-headless; then
  mark_ok "salesforce: JDK (distro default)"
else
  mark_fail "salesforce: JDK ${JDK_VERSION}" "package install failed"
fi

# VS Code needs to be pointed at the JDK explicitly; it does not reliably infer
# it from PATH, and this is the setting people spend an afternoon on.
if have java && [[ "$DRY_RUN" != "1" ]]; then
  _jdk="$(readlink -f "$(command -v javac 2>/dev/null || command -v java)" 2>/dev/null | sed 's|/bin/.*||')"
  [[ -n "$_jdk" ]] && manual "VS Code: set \"salesforcedx-vscode-apex.java.home\": \"${_jdk}\" in settings.json, or the Apex language server stays silently inert."
  unset _jdk
fi

# ------------------------------------------------------------- sf plugins ----

# Plugins live in ~/.local/share/sf and are shared across every sf install, so
# they are invisible to `npm ls -g` and vanish quietly in a rebuild.
step "salesforce: sf plugins"
if ! have sf; then
  mark_skip "salesforce: sf plugins" "sf not on PATH — run the cloud profile first"
elif [[ "$DRY_RUN" == "1" ]]; then
  skip "would install sf plugins: ${SF_PLUGINS:-@salesforce/data}"
  mark_skip "salesforce: sf plugins" "dry run"
else
  _installed=0 _failed=0
  for plug in ${SF_PLUGINS:-@salesforce/data}; do
    if sf plugins inspect "$plug" >/dev/null 2>&1; then
      continue
    fi
    if run sf plugins install "$plug"; then _installed=$((_installed+1)); else _failed=$((_failed+1)); fi
  done
  if ((_failed)); then
    mark_fail "salesforce: sf plugins" "$_failed failed"
  elif ((_installed)); then
    mark_ok "salesforce: sf plugins ($_installed installed)"
  else
    mark_skip "salesforce: sf plugins" "already present"
  fi
  unset _installed _failed
fi

note "Add more plugins with: SF_PLUGINS='@salesforce/data sfdx-git-delta' ./setup.sh salesforce"

manual "Salesforce orgs: re-authenticate each with 'sf org login web --alias <alias>'. Aliases live in ~/.sfdx/alias.json — capture that file before a rebuild, it is the list of what to re-auth."
