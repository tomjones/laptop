#!/usr/bin/env bash
# db-snapshot.sh — frequent local PostgreSQL snapshots for rollback.
#
#   ./db-snapshot.sh                    take a snapshot of every connectable db
#   ./db-snapshot.sh --weekly           also include connection-locked databases
#   ./db-snapshot.sh --list             what is available, and from when
#   ./db-snapshot.sh --restore <db>     restore newest into a scratch database
#   ./db-snapshot.sh --restore <db> --at 2026-08-12T09  restore a specific one
#   ./db-snapshot.sh --restore <db> --in-place          overwrite the live db
#   ./db-snapshot.sh --prune            apply the retention ladder
#   ./db-snapshot.sh --mirror           encrypted copy of the newest to /mnt/c
#
# This is NOT the disaster-recovery backup — that is `backup.sh databases`,
# which encrypts and ships off-machine. This is the "undo that migration"
# tool: fast, local, frequent, and restoring to a scratch name by default so
# you can diff before you commit to anything.
#
# Snapshots are stored UNENCRYPTED at mode 0600. That is deliberate: they sit
# on the same disk as the live cluster, which the same user can already read
# with psql, so encrypting them defends against nothing while adding an unlock
# step to the operation that most needs to be quick. Anything that LEAVES this
# machine is encrypted — see --mirror and backup.sh.

set -uo pipefail

LAPTOP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "${LAPTOP_DIR}/lib/common.sh"

CONF="${HOME}/.config/laptop-backup.conf"
# shellcheck source=/dev/null
[[ -f "$CONF" ]] && . "$CONF"

SNAP_DIR="${DB_SNAPSHOT_DIR:-$HOME/.local/state/db-snapshots}"
PSQL_MAINT="${PSQL_MAINT:-postgres}"
MIRROR_DIR="${DB_SNAPSHOT_MIRROR:-}"          # e.g. /mnt/c/Users/you/OneDrive/db-snapshots
AGE_RECIPIENTS_FILE="${AGE_RECIPIENTS_FILE:-$HOME/.config/age/recipients.txt}"

# Retention ladder
KEEP_HOURLY="${KEEP_HOURLY:-24}"
KEEP_DAILY="${KEEP_DAILY:-14}"
KEEP_WEEKLY="${KEEP_WEEKLY:-8}"

STAMP="$(date +%Y-%m-%dT%H%M%S)"

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }

pg_ok() { psql -d "$PSQL_MAINT" -tAc 'SELECT 1' >/dev/null 2>&1; }

connectable_dbs() {
  psql -d "$PSQL_MAINT" -tAc \
    "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname"
}

locked_dbs() {
  psql -d "$PSQL_MAINT" -tAc \
    "SELECT datname FROM pg_database WHERE NOT datallowconn AND NOT datistemplate ORDER BY datname"
}

# ---------------------------------------------------------------- snapshot ----

do_snapshot() {
  local include_locked="${1:-0}"
  pg_ok || die "cannot reach PostgreSQL (maintenance db: $PSQL_MAINT)"

  local dest="$SNAP_DIR/$STAMP"
  run mkdir -p "$dest" && run chmod 700 "$SNAP_DIR" "$dest"

  local n=0 failed=0 total=0
  local -a failed_dbs=() perm_denied=()
  for db in $(connectable_dbs); do
    if [[ "$DRY_RUN" == "1" ]]; then
      skip "would dump $db"
      continue
    fi
    local err
    err="$(pg_dump -d "$db" --format=custom --compress=6 -f "$dest/${db}.dump" 2>&1)"
    if [[ $? -eq 0 ]]; then
      chmod 600 "$dest/${db}.dump"
      total=$((total + $(stat -c%s "$dest/${db}.dump")))
      n=$((n+1))
    else
      # A failed pg_dump still creates the output file. Leaving that partial
      # file behind would let --list and --restore offer a corrupt dump as if
      # it were good, which is strictly worse than having no dump at all.
      rm -f "$dest/${db}.dump"
      failed_dbs+=("$db")
      grep -q 'permission denied for schema' <<<"$err" && perm_denied+=("$db")
      warn "pg_dump failed: $db — $(grep -m1 'error:' <<<"$err" | sed 's/^pg_dump: error: //')"
      failed=$((failed+1))
    fi
  done

  if ((${#perm_denied[@]})); then
    manual "pg_dump cannot read every schema as '$USER' (${#perm_denied[@]} databases: ${perm_denied[*]}). Grant read-only access to all of them, once, as superuser:  sudo -u postgres psql -c 'GRANT pg_read_all_data TO $USER'"
  fi

  # Locked databases are excluded from the hourly loop on purpose — they are
  # large, static, and unlocking them briefly is not something to do 24x a day.
  if ((include_locked)) && [[ "$DRY_RUN" != "1" ]]; then
    for db in $(locked_dbs); do
      info "unlocking $db for a weekly dump"
      if psql -d "$PSQL_MAINT" -qc "ALTER DATABASE \"$db\" ALLOW_CONNECTIONS true" >/dev/null 2>&1; then
        if pg_dump -d "$db" --format=custom --compress=6 -f "$dest/${db}.dump" 2>/dev/null; then
          chmod 600 "$dest/${db}.dump"
          total=$((total + $(stat -c%s "$dest/${db}.dump")))
          n=$((n+1))
        else
          warn "pg_dump failed: $db"; failed=$((failed+1))
        fi
        psql -d "$PSQL_MAINT" -qc "ALTER DATABASE \"$db\" ALLOW_CONNECTIONS false" >/dev/null 2>&1 \
          || error "FAILED to re-lock '$db' — fix with: ALTER DATABASE \"$db\" ALLOW_CONNECTIONS false"
      else
        warn "could not unlock $db (needs superuser)"; failed=$((failed+1))
      fi
    done
  fi

  [[ "$DRY_RUN" == "1" ]] && { mark_skip "snapshot" "dry run"; return; }

  # Roles, without passwords. Restoring a database whose owner does not exist
  # produces a pile of confusing errors, so this is worth the two seconds.
  pg_dumpall --roles-only --no-role-passwords > "$dest/roles.sql" 2>/dev/null && chmod 600 "$dest/roles.sql"

  { echo "stamp=$STAMP"; echo "databases=$n"; echo "failed=$failed"
    echo "bytes=$total"; echo "locked_included=$include_locked"
    echo "pg_version=$(psql -d "$PSQL_MAINT" -tAc 'SHOW server_version' 2>/dev/null)"
    # Record what is NOT in here. A snapshot that silently omits a database is
    # the failure mode this whole tool exists to avoid.
    ((${#failed_dbs[@]})) && echo "missing=${failed_dbs[*]}"
  } > "$dest/MANIFEST"

  if ((failed)); then
    mark_fail "snapshot $STAMP" "$n dumped, $failed failed"
  elif ((n == 0)); then
    mark_fail "snapshot $STAMP" "enumerated zero databases"
    rmdir "$dest" 2>/dev/null
  else
    mark_ok "snapshot $STAMP — $n databases, $(numfmt --to=iec "$total")"
  fi
}

# ------------------------------------------------------------------- list ----

do_list() {
  [[ -d "$SNAP_DIR" ]] || die "no snapshots at $SNAP_DIR"
  printf '%sSnapshots in %s%s\n\n' "$C_BOLD" "$SNAP_DIR" "$C_RESET"
  printf '  %-22s %6s %10s  %s\n' WHEN DBS SIZE ""
  local any=0
  for d in "$SNAP_DIR"/*/; do
    [[ -d "$d" ]] || continue
    any=1
    local stamp dbs size locked
    stamp="$(basename "$d")"
    dbs="$(grep -c . <(ls "$d"/*.dump 2>/dev/null) 2>/dev/null || echo 0)"
    size="$(du -sh "$d" 2>/dev/null | cut -f1)"
    locked=""
    grep -q '^locked_included=1' "$d/MANIFEST" 2>/dev/null && locked="${C_DIM}+locked${C_RESET}"
    printf '  %-22s %6s %10s  %b\n' "$stamp" "$dbs" "$size" "$locked"
  done
  ((any)) || printf '  %s(none yet)%s\n' "$C_DIM" "$C_RESET"
  printf '\n  total: %s\n' "$(du -sh "$SNAP_DIR" 2>/dev/null | cut -f1)"
}

newest_with() {
  local db="$1" at="${2:-}"
  local d
  for d in $(ls -1d "$SNAP_DIR"/*/ 2>/dev/null | sort -r); do
    [[ -n "$at" ]] && [[ "$(basename "$d")" != "$at"* ]] && continue
    [[ -f "$d/${db}.dump" ]] && { echo "${d%/}"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------- restore ----

do_restore() {
  local db="$1" at="${2:-}" in_place="${3:-0}"
  pg_ok || die "cannot reach PostgreSQL"

  local snap
  snap="$(newest_with "$db" "$at")" || die "no snapshot found for '$db'${at:+ at $at}. Try --list."
  local dump="$snap/${db}.dump"

  local target="$db"
  if ((!in_place)); then
    target="${db}_restore_$(basename "$snap" | tr -d ':-' | cut -c1-13)"
  fi

  printf '\n  source : %s\n  target : %s%s\n\n' \
    "$dump" "$target" "$( ((in_place)) && printf ' %s(LIVE DATABASE)%s' "$C_RED" "$C_RESET" )"

  if ((in_place)); then
    warn "This overwrites the live '$db'. Existing data will be dropped."
    read -r -p "  Type the database name to confirm: " confirm
    [[ "$confirm" == "$db" ]] || die "not confirmed"
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    skip "would restore $dump -> $target"
    return
  fi

  if ((!in_place)); then
    psql -d "$PSQL_MAINT" -qc "DROP DATABASE IF EXISTS \"$target\"" >/dev/null 2>&1
    createdb "$target" || die "could not create $target"
  fi

  # --clean/--if-exists only makes sense when restoring OVER something. Into a
  # database we just created it emits DROP errors for objects that never
  # existed, and "errors ignored on restore" on a clean restore is exactly the
  # wrong signal from a tool you reach for when something is already wrong.
  local -a pgr=(--no-owner --no-privileges)
  ((in_place)) && pgr+=(--clean --if-exists)
  pg_restore -d "$target" "${pgr[@]}" "$dump" 2>&1 | grep -vE '^$' | tail -5 || true
  # pg_restore returns non-zero on ignorable warnings, so verify by counting tables.
  local tables
  tables="$(psql -d "$target" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema')" 2>/dev/null)"
  if [[ "${tables:-0}" -gt 0 ]]; then
    success "restored into '$target' — $tables tables"
    ((in_place)) || printf '\n  Inspect it, then when satisfied:\n    %spsql -d %s%s\n    %s./db-snapshot.sh --restore %s --in-place%s\n    %sdropdb %s%s\n\n' \
      "$C_DIM" "$target" "$C_RESET" "$C_DIM" "$db" "$C_RESET" "$C_DIM" "$target" "$C_RESET"
  else
    error "restore produced no tables in '$target' — check the output above"
  fi
}

# ------------------------------------------------------------------ prune ----

# Retention ladder: every snapshot from the last KEEP_HOURLY hours, then one
# per day back KEEP_DAILY days, then one per week back KEEP_WEEKLY weeks.
do_prune() {
  [[ -d "$SNAP_DIR" ]] || return 0
  local now keep_from_hourly cutoff_daily cutoff_weekly
  now="$(date +%s)"
  keep_from_hourly=$((now - KEEP_HOURLY * 3600))
  cutoff_daily=$((now - KEEP_DAILY * 86400))
  cutoff_weekly=$((now - KEEP_WEEKLY * 7 * 86400))

  declare -A seen_day=() seen_week=()
  local removed=0 kept=0

  # Newest first, so the first snapshot seen for a given day/week is the keeper.
  for d in $(ls -1d "$SNAP_DIR"/*/ 2>/dev/null | sort -r); do
    local stamp epoch iso
    stamp="$(basename "${d%/}")"
    iso="${stamp:0:10} ${stamp:11:2}:${stamp:13:2}:${stamp:15:2}"
    epoch="$(date -d "$iso" +%s 2>/dev/null)" || continue

    local verdict=""
    if   (( epoch >= keep_from_hourly )); then verdict=hourly
    elif (( epoch >= cutoff_daily )); then
      local day="${stamp:0:10}"
      [[ -z "${seen_day[$day]:-}" ]] && { seen_day[$day]=1; verdict=daily; }
    elif (( epoch >= cutoff_weekly )); then
      local week; week="$(date -d "$iso" +%G-W%V 2>/dev/null)"
      [[ -z "${seen_week[$week]:-}" ]] && { seen_week[$week]=1; verdict=weekly; }
    fi

    if [[ -n "$verdict" ]]; then
      kept=$((kept+1))
    else
      if [[ "$DRY_RUN" == "1" ]]; then
        skip "would remove $stamp"
      else
        rm -rf "${d%/}"
      fi
      removed=$((removed+1))
    fi
  done
  mark_ok "prune — kept $kept, removed $removed"
}

# ----------------------------------------------------------------- mirror ----

# Copies the newest snapshot to a destination outside the WSL filesystem, so a
# corrupted VHDX or a stray `wsl --unregister` does not take the database and
# its backups together. Encrypted with age PUBLIC keys, which needs no unlock.
do_mirror() {
  [[ -n "$MIRROR_DIR" ]] || { mark_skip "mirror" "DB_SNAPSHOT_MIRROR unset"; return; }
  [[ -f "$AGE_RECIPIENTS_FILE" ]] || { mark_fail "mirror" "no age recipients — run 'secrets init'"; return; }
  have age || { mark_fail "mirror" "age not installed"; return; }

  local newest
  newest="$(ls -1d "$SNAP_DIR"/*/ 2>/dev/null | sort -r | head -1)"
  [[ -n "$newest" ]] || { mark_skip "mirror" "no snapshots"; return; }
  newest="${newest%/}"

  local out="$MIRROR_DIR/$(basename "$newest").tar.gz.age"
  if [[ "$DRY_RUN" == "1" ]]; then
    skip "would mirror $(basename "$newest") -> $out"
    mark_skip "mirror" "dry run"; return
  fi

  mkdir -p "$MIRROR_DIR"
  local -a rcpt=()
  while read -r k; do [[ -n "$k" ]] && rcpt+=(-r "$k"); done < "$AGE_RECIPIENTS_FILE"

  if tar -czf - -C "$(dirname "$newest")" "$(basename "$newest")" | age "${rcpt[@]}" -o "$out"; then
    chmod 600 "$out"
    mark_ok "mirror -> $out ($(du -h "$out" | cut -f1))"
    # Keep the mirror shallow; it is insurance, not an archive.
    ls -1t "$MIRROR_DIR"/*.tar.gz.age 2>/dev/null | tail -n +8 | xargs -r rm -f
  else
    mark_fail "mirror" "encryption or copy failed"
  fi
}

# --------------------------------------------------------------- dispatch ----

MODE=snapshot; RDB=""; RAT=""; INPLACE=0; WEEKLY=0
while (($#)); do
  case "$1" in
    --weekly)   WEEKLY=1 ;;
    --list|-l)  MODE=list ;;
    --prune)    MODE=prune ;;
    --mirror)   MODE=mirror ;;
    --restore)  MODE=restore; shift; RDB="${1:-}" ;;
    --at)       shift; RAT="${1:-}" ;;
    --in-place) INPLACE=1 ;;
    --dry-run)  DRY_RUN=1 ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "unknown argument: $1  (try --help)" ;;
  esac
  shift
done

case "$MODE" in
  snapshot) heading "Database snapshot — $STAMP"; do_snapshot "$WEEKLY"; do_prune; do_mirror; summary ;;
  list)     do_list ;;
  prune)    heading "Prune"; do_prune; summary ;;
  mirror)   heading "Mirror"; do_mirror; summary ;;
  restore)  [[ -n "$RDB" ]] || die "usage: --restore <database>"; do_restore "$RDB" "$RAT" "$INPLACE" ;;
esac
