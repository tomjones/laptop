#!/usr/bin/env bash
# backup.sh — tiers 2, 3 and 4 of the backup strategy.
#
#   Tier 0  git hygiene         not automatable — see the strategy doc
#   Tier 1  WSL image snapshot  run from Windows: wsl --export
#   Tier 2  selective files     this script, `files`
#   Tier 3  database dumps      this script, `databases`
#   Tier 4  off-machine copy    this script, `push`
#
#   ./backup.sh                 run files + databases + push
#   ./backup.sh files           just the irreplaceable file set
#   ./backup.sh databases       just PostgreSQL and Redis
#   ./backup.sh push            just ship what is already staged
#   ./backup.sh --dry-run       show what would happen
#   ./backup.sh --list          show the include/exclude sets and exit
#
# Config: ~/.config/laptop-backup.conf, or environment variables. See --list.
#
# Everything staged here is encrypted with your age recipients before it leaves
# the machine, so the destination only ever holds ciphertext.

set -uo pipefail

LAPTOP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "${LAPTOP_DIR}/lib/common.sh"

CONF="${HOME}/.config/laptop-backup.conf"
# shellcheck source=/dev/null
[[ -f "$CONF" ]] && . "$CONF"

BACKUP_STAGE="${BACKUP_STAGE:-$HOME/.local/state/laptop-backup}"
BACKUP_DEST="${BACKUP_DEST:-}"                # local dir, or restic repo URL
BACKUP_METHOD="${BACKUP_METHOD:-auto}"        # auto | restic | copy | none
AGE_RECIPIENTS_FILE="${AGE_RECIPIENTS_FILE:-$HOME/.config/age/recipients.txt}"
KEEP_LOCAL="${KEEP_LOCAL:-7}"                 # staged archives to retain
INCLUDE_LOCKED_DBS="${INCLUDE_LOCKED_DBS:-0}"

STAMP="$(date +%Y%m%d-%H%M%S)"

# What is genuinely irreplaceable: credentials, hand-written configuration, and
# anything that exists in no repository and no package manager. Paths that do
# not exist are skipped silently, so this list is safe to keep broad.
#
# Add your own via BACKUP_EXTRA in ~/.config/laptop-backup.conf, e.g.
#   BACKUP_EXTRA=(".my-app-secrets" "Documents/notes")
INCLUDE=(
  # secret material
  ".secrets" ".ssh" ".gnupg" ".ssl" "certs"
  # shell and git
  ".bashrc" ".bash_profile" ".profile" ".zshrc" ".inputrc"
  ".gitconfig" ".config/git" ".netrc"
  # tool credentials and state
  ".config/age" ".config/gh" ".config/stripe" ".config/ngrok"
  ".config/cloudflare" ".config/doctl" ".config/flyctl"
  ".aws/config" ".kube/config" ".docker/config.json" ".npmrc" ".pypirc"
  # AI tooling — bespoke commands and skills exist nowhere else
  ".claude/settings.json" ".claude/commands" ".claude/skills"
  ".claude/lib" ".claude/plans" ".claude.json"
  # this repo, so a restored machine can rebuild itself
  "laptop"
)
# Merge in anything the user configured.
if declare -p BACKUP_EXTRA >/dev/null 2>&1; then
  INCLUDE+=("${BACKUP_EXTRA[@]}")
fi

# Large, regenerable, or already versioned elsewhere.
EXCLUDE=(
  "*/node_modules/*" "*/.venv/*" "*/venv/*" "*/__pycache__/*"
  "*/.cache/*" "*/.next/*" "*/dist/*" "*/build/*" "*/.turbo/*"
  "*.tar.gz" "*.zip" "*.dump"
)

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

show_config() {
  heading "Backup configuration"
  printf '  config file : %s%s\n' "$CONF" "$( [[ -f $CONF ]] && echo "" || echo "  (not present — using defaults)" )"
  printf '  stage dir   : %s\n' "$BACKUP_STAGE"
  printf '  destination : %s\n' "${BACKUP_DEST:-${C_YELLOW}unset — nothing will leave this machine${C_RESET}}"
  printf '  method      : %s\n' "$BACKUP_METHOD"
  printf '  recipients  : %s (%s keys)\n' "$AGE_RECIPIENTS_FILE" \
    "$( [[ -f $AGE_RECIPIENTS_FILE ]] && grep -c . "$AGE_RECIPIENTS_FILE" || echo 0 )"
  heading "Included (relative to \$HOME)"
  printf '  %s\n' "${INCLUDE[@]}"
  heading "Excluded patterns"
  printf '  %s\n' "${EXCLUDE[@]}"
  cat <<EOF

${C_BOLD}Example ${CONF}${C_RESET}
  BACKUP_DEST="/mnt/c/Users/you/OneDrive/backups/wsl"
  BACKUP_METHOD="copy"
  KEEP_LOCAL=14

  # or, with restic to S3:
  # BACKUP_DEST="s3:s3.amazonaws.com/my-backup-bucket/wsl"
  # BACKUP_METHOD="restic"
  # export AWS_PROFILE=backup RESTIC_PASSWORD_FILE=~/.config/restic-pass
EOF
}

# ------------------------------------------------------------ tier 2: files ----

do_files() {
  heading "Tier 2 — selective file backup"
  local out="$BACKUP_STAGE/files-${STAMP}.tar.gz"
  local -a tar_args=() present=()

  for item in "${INCLUDE[@]}"; do
    [[ -e "$HOME/$item" ]] && present+=("$item")
  done
  if ((${#present[@]} == 0)); then
    mark_fail "tier2: files" "nothing to back up"
    return
  fi
  for pat in "${EXCLUDE[@]}"; do tar_args+=(--exclude="$pat"); done

  step "tier2: archive ${#present[@]} paths"
  run mkdir -p "$BACKUP_STAGE"
  if [[ "$DRY_RUN" == "1" ]]; then
    skip "would archive: ${present[*]}"
    mark_skip "tier2: archive" "dry run"
  elif tar -czf "$out" -C "$HOME" "${tar_args[@]}" "${present[@]}" 2>/dev/null; then
    chmod 600 "$out"
    mark_ok "tier2: $(basename "$out") ($(du -h "$out" | cut -f1))"
  else
    mark_fail "tier2: archive" "tar failed"
    return
  fi

  encrypt_stage "$out"
}

# Encrypt in place so nothing plaintext survives staging.
encrypt_stage() {
  local file="$1"
  step "tier2: encrypt"
  if [[ ! -f "$AGE_RECIPIENTS_FILE" ]]; then
    mark_fail "tier2: encrypt" "no recipients at $AGE_RECIPIENTS_FILE — run 'secrets init'"
    [[ "$DRY_RUN" == "1" ]] || warn "Leaving $file UNENCRYPTED. Do not ship it anywhere."
    return
  fi
  if ! have age; then
    mark_fail "tier2: encrypt" "age not installed"
    return
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    mark_skip "tier2: encrypt" "dry run"
    return
  fi
  local -a rcpt=()
  while read -r key; do [[ -n "$key" ]] && rcpt+=(-r "$key"); done < "$AGE_RECIPIENTS_FILE"
  if age "${rcpt[@]}" -o "${file}.age" < "$file"; then
    shred -u "$file" 2>/dev/null || rm -f "$file"
    chmod 600 "${file}.age"
    mark_ok "tier2: encrypted to $(basename "${file}.age") for ${#rcpt[@]} recipient(s)"
  else
    mark_fail "tier2: encrypt" "age failed"
  fi
}

# -------------------------------------------------------- tier 3: databases ----

do_databases() {
  heading "Tier 3 — database dumps"
  local dir="$BACKUP_STAGE/db-${STAMP}"

  # Always name a database explicitly. Without -d, psql connects to one named
  # after the current user, which frequently does not exist — and the resulting
  # empty result set looks exactly like "no databases to back up".
  local PSQL_MAINT="${PSQL_MAINT:-postgres}"

  if ! have pg_dump; then
    mark_skip "tier3: postgres" "pg_dump not installed"
  elif ! psql -d "$PSQL_MAINT" -tAc 'SELECT 1' >/dev/null 2>&1; then
    mark_skip "tier3: postgres" "cannot connect to PostgreSQL (maintenance db: $PSQL_MAINT)"
  else
    run mkdir -p "$dir"

    # Databases with datallowconn=false are invisible to pg_dumpall and to a
    # naive loop. That can silently be your largest database — exactly
    # the kind of thing you discover is missing during a restore.
    local locked
    locked="$(psql -d "$PSQL_MAINT" -tAc "SELECT datname FROM pg_database WHERE NOT datallowconn AND NOT datistemplate" 2>/dev/null)"
    if [[ -n "$locked" ]]; then
      warn "Databases with connections disabled (skipped by any normal dump):"
      printf '    %s\n' $locked >&2
      if [[ "$INCLUDE_LOCKED_DBS" == "1" ]]; then
        note "INCLUDE_LOCKED_DBS=1 — will temporarily allow connections to dump them"
      else
        manual "Locked databases were NOT dumped: $(echo "$locked" | tr '\n' ' '). Re-run with INCLUDE_LOCKED_DBS=1, or dump them by hand."
      fi
    fi

    local dbs
    dbs="$(psql -d "$PSQL_MAINT" -tAc "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate" 2>/dev/null)"
    if [[ -z "$dbs" ]]; then
      mark_fail "tier3: postgres" "enumerated zero databases — refusing to report success"
    fi
    local n=0
    for db in $dbs; do
      step "tier3: pg_dump $db"
      if [[ "$DRY_RUN" == "1" ]]; then
        mark_skip "tier3: pg_dump $db" "dry run"
      elif pg_dump --format=custom --file="$dir/${db}.dump" "$db" 2>/dev/null; then
        mark_ok "tier3: $db ($(du -h "$dir/${db}.dump" | cut -f1))"; n=$((n+1))
      else
        mark_fail "tier3: pg_dump $db"
      fi
    done

    if [[ "$INCLUDE_LOCKED_DBS" == "1" ]] && [[ -n "$locked" ]] && [[ "$DRY_RUN" != "1" ]]; then
      for db in $locked; do
        step "tier3: pg_dump $db (temporarily unlocking)"
        if psql -d "$PSQL_MAINT" -qc "ALTER DATABASE \"$db\" ALLOW_CONNECTIONS true" >/dev/null 2>&1; then
          if pg_dump --format=custom --file="$dir/${db}.dump" "$db" 2>/dev/null; then
            mark_ok "tier3: $db ($(du -h "$dir/${db}.dump" | cut -f1))"; n=$((n+1))
          else
            mark_fail "tier3: pg_dump $db"
          fi
          # Always restore the original state, dump succeeded or not.
          psql -d "$PSQL_MAINT" -qc "ALTER DATABASE \"$db\" ALLOW_CONNECTIONS false" >/dev/null 2>&1 \
            || manual "FAILED to re-lock database '$db' — set it back with: ALTER DATABASE \"$db\" ALLOW_CONNECTIONS false"
        else
          mark_fail "tier3: pg_dump $db" "could not unlock (needs superuser)"
        fi
      done
    fi

    # Roles carry passwords, so this dump is sensitive even though it holds no
    # table data. It gets encrypted along with everything else below.
    if [[ "$DRY_RUN" != "1" ]] && have pg_dumpall; then
      pg_dumpall --roles-only --no-role-passwords > "$dir/roles.sql" 2>/dev/null \
        && note "roles dumped without passwords — you will need to reset them on restore"
    fi
    ((n)) && note "dumped $n database(s)"
  fi

  step "tier3: redis snapshot"
  if ! have redis-cli; then
    mark_skip "tier3: redis" "redis-cli not installed"
  elif ! redis-cli PING >/dev/null 2>&1; then
    mark_skip "tier3: redis" "server not responding"
  elif [[ "$DRY_RUN" == "1" ]]; then
    mark_skip "tier3: redis" "dry run"
  else
    run mkdir -p "$dir"
    redis-cli BGSAVE >/dev/null 2>&1
    # BGSAVE is asynchronous; wait for rdb_bgsave_in_progress to clear.
    for _ in $(seq 1 30); do
      [[ "$(redis-cli INFO persistence 2>/dev/null | grep -c 'rdb_bgsave_in_progress:1')" == "0" ]] && break
      sleep 1
    done
    local rdb
    rdb="$(redis-cli CONFIG GET dir 2>/dev/null | tail -1)/dump.rdb"
    if [[ -r "$rdb" ]] && cp "$rdb" "$dir/redis-dump.rdb" 2>/dev/null; then
      mark_ok "tier3: redis snapshot"
    else
      mark_skip "tier3: redis" "dump.rdb not readable (usually needs root)"
      manual "Redis RDB needs root to copy: sudo cp $rdb $dir/"
    fi
  fi

  if [[ -d "$dir" ]] && [[ "$DRY_RUN" != "1" ]]; then
    step "tier3: package and encrypt"
    local tarball="$BACKUP_STAGE/db-${STAMP}.tar.gz"
    if tar -czf "$tarball" -C "$BACKUP_STAGE" "db-${STAMP}" 2>/dev/null; then
      rm -rf "$dir"
      chmod 600 "$tarball"
      mark_ok "tier3: $(basename "$tarball") ($(du -h "$tarball" | cut -f1))"
      encrypt_stage "$tarball"
    else
      mark_fail "tier3: package"
    fi
  fi
}

# ------------------------------------------------------------- tier 4: push ----

do_push() {
  heading "Tier 4 — off-machine copy"

  if [[ -z "$BACKUP_DEST" ]]; then
    mark_skip "tier4: push" "BACKUP_DEST is unset"
    manual "Nothing has left this machine. Set BACKUP_DEST in $CONF — a backup that only exists on the machine it protects is not a backup."
    return
  fi

  local method="$BACKUP_METHOD"
  if [[ "$method" == "auto" ]]; then
    if have restic && [[ "$BACKUP_DEST" == *:* ]]; then method=restic; else method=copy; fi
  fi

  case "$method" in
    restic)
      step "tier4: restic"
      if ! have restic; then
        mark_fail "tier4: restic" "not installed"
        return
      fi
      if [[ "$DRY_RUN" == "1" ]]; then
        skip "would run: restic -r $BACKUP_DEST backup $BACKUP_STAGE"
        mark_skip "tier4: restic" "dry run"
      elif restic -r "$BACKUP_DEST" backup "$BACKUP_STAGE" --tag laptop 2>&1 | tail -3; then
        mark_ok "tier4: pushed to $BACKUP_DEST"
        restic -r "$BACKUP_DEST" forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune >/dev/null 2>&1 \
          && note "restic retention applied: 7 daily, 4 weekly, 12 monthly"
      else
        mark_fail "tier4: restic" "backup failed"
      fi
      ;;
    copy)
      step "tier4: copy to $BACKUP_DEST"
      if [[ "$DRY_RUN" == "1" ]]; then
        skip "would rsync $BACKUP_STAGE/ -> $BACKUP_DEST/"
        mark_skip "tier4: copy" "dry run"
      elif mkdir -p "$BACKUP_DEST" && rsync -a --delete-after "$BACKUP_STAGE/" "$BACKUP_DEST/"; then
        mark_ok "tier4: copied to $BACKUP_DEST"
      else
        mark_fail "tier4: copy" "rsync failed"
      fi
      ;;
    none)
      mark_skip "tier4: push" "method=none"
      ;;
    *)
      mark_fail "tier4: push" "unknown method '$method'"
      ;;
  esac
}

prune_local() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  local n
  n="$(find "$BACKUP_STAGE" -maxdepth 1 -name '*.age' -type f 2>/dev/null | wc -l)"
  ((n > KEEP_LOCAL)) || return 0
  find "$BACKUP_STAGE" -maxdepth 1 -name '*.age' -type f -printf '%T@ %p\n' 2>/dev/null \
    | sort -n | head -n "$((n - KEEP_LOCAL))" | cut -d' ' -f2- \
    | while read -r old; do rm -f "$old"; done
  note "pruned staged archives to the newest $KEEP_LOCAL"
}

# ---------------------------------------------------------------- dispatch ----

declare -a WHAT=()
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --list)    show_config; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    files|databases|push) WHAT+=("$1") ;;
    *) die "unknown argument: $1  (try --help)" ;;
  esac
  shift
done
((${#WHAT[@]})) || WHAT=(files databases push)

heading "Backup — ${STAMP}"
[[ "$DRY_RUN" == "1" ]] && printf '  mode: %sdry run%s\n' "$C_YELLOW" "$C_RESET"

for w in "${WHAT[@]}"; do
  case "$w" in
    files)     do_files ;;
    databases) do_databases ;;
    push)      do_push ;;
  esac
done

prune_local
summary
