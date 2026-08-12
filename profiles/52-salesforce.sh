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

# VS Code does not reliably infer the JDK from PATH, so installing Java is only
# half the job — the extension needs java.home set explicitly. This is the step
# people lose an afternoon to, so the script does it rather than telling you to.
#
# Machine scope, not User: java.home is a per-machine path, and User settings
# sync across your other machines where it would be wrong.
step "salesforce: point VS Code at the JDK"
_vscode_settings="$HOME/.vscode-server/data/Machine/settings.json"
if ! have java; then
  mark_skip "salesforce: VS Code java.home" "no JDK installed"
elif [[ ! -d "$HOME/.vscode-server" ]]; then
  mark_skip "salesforce: VS Code java.home" "VS Code Server not present"
else
  _jdk="$(readlink -f "$(command -v javac 2>/dev/null || command -v java)" 2>/dev/null | sed 's|/bin/[^/]*$||')"
  if [[ -z "$_jdk" || ! -d "$_jdk" ]]; then
    mark_fail "salesforce: VS Code java.home" "could not resolve JAVA_HOME"
  elif [[ "$DRY_RUN" == "1" ]]; then
    skip "would set salesforcedx-vscode-apex.java.home = ${_jdk} in ${_vscode_settings}"
    mark_skip "salesforce: VS Code java.home" "dry run"
  else
    mkdir -p "$(dirname "$_vscode_settings")"
    backup_once "$_vscode_settings"
    # Merge rather than overwrite; the file may already hold your own settings.
    # VS Code tolerates comments in settings.json, which json.load does not, so
    # fall back to leaving the file alone rather than destroying hand edits.
    if JDK="$_jdk" SETTINGS="$_vscode_settings" python3 - <<'PY'
import json, os, sys
p, jdk = os.environ["SETTINGS"], os.environ["JDK"]
key = "salesforcedx-vscode-apex.java.home"
data = {}
if os.path.exists(p) and os.path.getsize(p):
    try:
        with open(p) as f:
            data = json.load(f)
    except Exception:
        sys.stderr.write("existing settings.json is not plain JSON (comments?) — not touching it\n")
        sys.exit(2)
if data.get(key) == jdk:
    sys.exit(3)          # already correct
data[key] = jdk
with open(p, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
    then
      mark_ok "salesforce: VS Code java.home = ${_jdk}"
      manual "Reload the VS Code window (Ctrl+Shift+P, 'Developer: Reload Window') for the Apex language server to pick up the JDK."
    else
      case $? in
        3) mark_skip "salesforce: VS Code java.home" "already correct" ;;
        2) mark_skip "salesforce: VS Code java.home" "settings.json has comments — set it by hand"
           manual "Add to ${_vscode_settings}:  \"salesforcedx-vscode-apex.java.home\": \"${_jdk}\"" ;;
        *) mark_fail "salesforce: VS Code java.home" ;;
      esac
    fi
  fi
  unset _jdk
fi
unset _vscode_settings

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
