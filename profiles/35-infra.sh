#!/usr/bin/env bash
# desc: terraform, packer, ansible, and AWS SSM session access
#
# profiles/35-infra.sh — infrastructure-as-code and remote host access.
#
# session-manager-plugin is the load-bearing one. A modern AWS design often has
# no sshd at all, reaching hosts exclusively through SSM Session Manager. The
# AWS CLI will happily accept `aws ssm start-session` without the plugin and
# then fail at the point of connection — so on a freshly rebuilt machine you
# would have no way to reach anything, and the error does not obviously point
# at a missing local binary.
#
# shellcheck shell=bash

TERRAFORM_VIA_REPO="${TERRAFORM_VIA_REPO:-1}"   # 0 to skip the HashiCorp apt repo

# ------------------------------------------------- hashicorp: terraform, packer ----

step "infra: HashiCorp apt repo"
if [[ "$PKG_FAMILY" != "debian" ]]; then
  mark_skip "infra: HashiCorp apt repo" "not an apt system"
elif [[ "$TERRAFORM_VIA_REPO" != "1" ]]; then
  mark_skip "infra: HashiCorp apt repo" "TERRAFORM_VIA_REPO=0"
elif [[ -f /etc/apt/sources.list.d/hashicorp.list ]]; then
  mark_skip "infra: HashiCorp apt repo" "already configured"
elif [[ "$DRY_RUN" == "1" ]]; then
  skip "would add the HashiCorp apt repo"
  mark_skip "infra: HashiCorp apt repo" "dry run"
else
  _codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  as_root install -m 0755 -d /etc/apt/keyrings
  if run_sh "curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/hashicorp.gpg --yes" \
    && as_root chmod a+r /etc/apt/keyrings/hashicorp.gpg \
    && run_sh "echo 'deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com ${_codename} main' | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null"
  then
    _APT_UPDATED=0
    mark_ok "infra: HashiCorp apt repo"
  else
    mark_fail "infra: HashiCorp apt repo" "could not configure"
  fi
  unset _codename
fi

step "infra: terraform"
if want terraform; then :; else
  if [[ "$PKG_FAMILY" == "debian" ]] && [[ -f /etc/apt/sources.list.d/hashicorp.list || "$DRY_RUN" == "1" ]]; then
    if pkg_install terraform; then mark_ok "infra: terraform"; else mark_fail "infra: terraform"; fi
  else
    # No repo available: fall back to the release zip.
    _v="$(curl -fsSL https://checkpoint-api.hashicorp.com/v1/check/terraform 2>/dev/null | grep -oE '"current_version":"[^"]+' | cut -d'"' -f4)"
    _v="${_v:-1.9.8}"
    _tmp="$(mktemp -d)"
    if fetch "https://releases.hashicorp.com/terraform/${_v}/terraform_${_v}_linux_$(arch_go).zip" "$_tmp/tf.zip" \
       && run unzip -qo "$_tmp/tf.zip" -d "$_tmp" \
       && run install -m 0755 "$_tmp/terraform" "$HOME/.local/bin/terraform"
    then mark_ok "infra: terraform ${_v}"; else mark_fail "infra: terraform"; fi
    run rm -rf "$_tmp"; unset _tmp _v
  fi
fi

step "infra: packer"
if want packer; then :; else
  if [[ "$PKG_FAMILY" == "debian" ]] && [[ -f /etc/apt/sources.list.d/hashicorp.list || "$DRY_RUN" == "1" ]]; then
    if pkg_install packer; then mark_ok "infra: packer"; else mark_fail "infra: packer"; fi
  else
    mark_skip "infra: packer" "no HashiCorp repo; see developer.hashicorp.com/packer/downloads"
  fi
fi

# Linting matters more for Terraform than most languages, because the feedback
# loop is otherwise "apply it and find out".
step "infra: tflint"
if want tflint; then :; else
  if [[ "$DRY_RUN" == "1" ]]; then
    mark_skip "infra: tflint" "dry run"
  elif run_sh 'curl -fsSL https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | sudo bash'; then
    mark_ok "infra: tflint"
  else
    mark_fail "infra: tflint" "installer failed"
  fi
fi

step "infra: terraform-docs"
if want terraform-docs; then :; else
  _tag="$(github_latest_tag terraform-docs/terraform-docs)"; _tag="${_tag:-v0.19.0}"
  _tmp="$(mktemp -d)"
  if fetch "https://github.com/terraform-docs/terraform-docs/releases/download/${_tag}/terraform-docs-${_tag}-linux-$(arch_go).tar.gz" "$_tmp/td.tgz" \
     && run tar -xzf "$_tmp/td.tgz" -C "$_tmp" \
     && run install -m 0755 "$_tmp/terraform-docs" "$HOME/.local/bin/terraform-docs"
  then mark_ok "infra: terraform-docs ${_tag}"; else mark_fail "infra: terraform-docs"; fi
  run rm -rf "$_tmp"; unset _tmp _tag
fi

# ---------------------------------------------------------------- ansible ----

# Via pipx rather than apt: distro Ansible packages lag badly, and pipx keeps
# it and its collections isolated from the system Python.
step "infra: ansible"
if want ansible; then :; else
  if have pipx; then
    if run pipx install --include-deps ansible; then
      mark_ok "infra: ansible (pipx)"
    else
      mark_fail "infra: ansible" "pipx install failed"
    fi
  else
    mark_skip "infra: ansible" "pipx not installed — run the languages profile first"
  fi
fi

step "infra: ansible-lint"
if want ansible-lint; then :; else
  if have pipx; then
    if run pipx install ansible-lint; then mark_ok "infra: ansible-lint"; else mark_fail "infra: ansible-lint"; fi
  else
    mark_skip "infra: ansible-lint" "pipx not installed"
  fi
fi

# ------------------------------------------------------------- aws access ----

step "infra: session-manager-plugin"
if want session-manager-plugin; then :; else
  if [[ "$DRY_RUN" == "1" ]]; then
    skip "would install the AWS session-manager-plugin"
    mark_skip "infra: session-manager-plugin" "dry run"
  elif [[ "$PKG_FAMILY" == "debian" ]]; then
    _arch="$(dpkg --print-architecture)"
    _tmp="$(mktemp -d)"
    if fetch "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_${_arch}/session-manager-plugin.deb" "$_tmp/smp.deb" \
       && as_root dpkg -i "$_tmp/smp.deb"
    then mark_ok "infra: session-manager-plugin"; else mark_fail "infra: session-manager-plugin"; fi
    run rm -rf "$_tmp"; unset _tmp _arch
  elif [[ "$PKG_FAMILY" == "rhel" ]]; then
    if as_root "$PKG_MGR" install -y "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm"; then
      mark_ok "infra: session-manager-plugin"
    else
      mark_fail "infra: session-manager-plugin"
    fi
  else
    mark_skip "infra: session-manager-plugin" "no package for ${PKG_FAMILY}"
  fi
fi
manual "SSM access: 'aws ssm start-session --target <instance-id>'. Needs the AmazonSSMManagedInstanceCore permissions on the instance role and ssm:StartSession on yours."

step "infra: kubectl"
if want kubectl; then :; else
  # A dangling kubectl symlink from Docker Desktop is a common leftover; make
  # sure we are not installing on top of one.
  [[ -L /usr/local/bin/kubectl && ! -e /usr/local/bin/kubectl ]] && as_root rm -f /usr/local/bin/kubectl
  _v="$(curl -fsSL https://dl.k8s.io/release/stable.txt 2>/dev/null)"; _v="${_v:-v1.31.0}"
  if fetch "https://dl.k8s.io/release/${_v}/bin/linux/$(arch_go)/kubectl" /tmp/kubectl \
     && run install -m 0755 /tmp/kubectl "$HOME/.local/bin/kubectl"
  then mark_ok "infra: kubectl ${_v}"; else mark_fail "infra: kubectl"; fi
  run rm -f /tmp/kubectl; unset _v
fi
