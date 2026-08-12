#!/usr/bin/env bash
# profiles/40-databases.sh — PostgreSQL and Redis, with hardened defaults.
#
# `listen_addresses = '*'` is the single most common self-inflicted database
# exposure: someone sets it once to get a client connecting, and it outlives the
# reason. On a laptop with no host firewall it means every database is reachable
# from the network. This profile binds Postgres to localhost and makes you opt
# in explicitly, via PG_BIND, to anything wider.
#
# shellcheck shell=bash

PG_BIND="${PG_BIND:-localhost}"          # set to '*' only with a firewall in place
REDIS_MAXMEMORY="${REDIS_MAXMEMORY:-2gb}"

# ------------------------------------------------------------- postgresql ----

step "postgres: server"
if have psql && (svc_active postgresql || svc_active "postgresql@*"); then
  mark_skip "" "already installed and running"
elif pkg_install postgresql postgresql-contrib libpq-dev; then
  mark_ok "postgres: server"
else
  mark_fail "postgres: server" "package install failed"
fi

step "postgres: initialise cluster"
if [[ "$DRY_RUN" == "1" ]]; then
  mark_skip "postgres: initialise cluster" "dry run"
elif [[ "$PKG_FAMILY" == "debian" ]]; then
  # Debian auto-creates a cluster on install; nothing to do.
  mark_skip "postgres: initialise cluster" "Debian creates one on install"
elif [[ "$PKG_FAMILY" == "rhel" ]]; then
  if [[ -d /var/lib/pgsql/data/base ]]; then
    mark_skip "postgres: initialise cluster" "already initialised"
  elif as_root postgresql-setup --initdb; then
    mark_ok "postgres: initialise cluster"
  else
    mark_fail "postgres: initialise cluster"
  fi
elif [[ "$PKG_FAMILY" == "arch" ]]; then
  if [[ -d /var/lib/postgres/data/base ]]; then
    mark_skip "postgres: initialise cluster" "already initialised"
  elif as_root su - postgres -c "initdb -D /var/lib/postgres/data"; then
    mark_ok "postgres: initialise cluster"
  else
    mark_fail "postgres: initialise cluster"
  fi
fi

step "postgres: bind to ${PG_BIND}"
if [[ "$DRY_RUN" == "1" ]]; then
  skip "would set listen_addresses = '${PG_BIND}'"
  mark_skip "postgres: bind" "dry run"
else
  _pgconf="$(as_root find /etc/postgresql /var/lib/pgsql /var/lib/postgres \
              -name postgresql.conf -not -path '*/conf.d/*' 2>/dev/null | head -1)"
  if [[ -z "$_pgconf" ]]; then
    mark_skip "postgres: bind" "postgresql.conf not found"
  else
    backup_once "$_pgconf"
    if as_root sed -i -E "s|^[[:space:]]*#?[[:space:]]*listen_addresses[[:space:]]*=.*|listen_addresses = '${PG_BIND}'|" "$_pgconf"; then
      mark_ok "postgres: listen_addresses = '${PG_BIND}' in $_pgconf"
      [[ "$PG_BIND" != "localhost" ]] && \
        manual "PostgreSQL is bound wider than localhost. Confirm pg_hba.conf and a host firewall are both in place."
    else
      mark_fail "postgres: bind"
    fi
  fi
  unset _pgconf
fi

step "postgres: enable service"
if [[ "$DRY_RUN" == "1" ]]; then
  mark_skip "postgres: enable service" "dry run"
elif [[ ! -d /run/systemd/system ]]; then
  mark_skip "postgres: enable service" "systemd not running"
else
  if svc_enable postgresql; then mark_ok "postgres: enabled"; else mark_fail "postgres: enable service"; fi
fi

step "postgres: role for $USER"
if [[ "$DRY_RUN" == "1" ]]; then
  mark_skip "postgres: role" "dry run"
elif ! svc_active postgresql; then
  mark_skip "postgres: role" "server not running"
elif as_root su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='$USER'\"" 2>/dev/null | grep -q 1; then
  mark_skip "postgres: role" "role '$USER' exists"
else
  if as_root su - postgres -c "createuser --createdb '$USER'"; then
    mark_ok "postgres: created role '$USER' with CREATEDB"
  else
    mark_fail "postgres: role"
  fi
fi

# ------------------------------------------------------------------ redis ----

step "redis: server"
if have redis-server || have redis-cli; then
  mark_skip "" "already installed"
elif pkg_install redis-server; then
  mark_ok "redis: server"
else
  mark_fail "redis: server" "package install failed"
fi

# Debian ships Redis with maxmemory 0 and noeviction — an unbounded
# allocation with no ceiling other than the machine's RAM. A runaway producer
# takes the box down. A cap plus an LRU policy turns that into a degradation.
step "redis: memory ceiling"
if [[ "$DRY_RUN" == "1" ]]; then
  skip "would set maxmemory ${REDIS_MAXMEMORY} / maxmemory-policy allkeys-lru"
  mark_skip "redis: memory ceiling" "dry run"
else
  _rconf=""
  for c in /etc/redis/redis.conf /etc/redis.conf; do
    as_root test -f "$c" 2>/dev/null && { _rconf="$c"; break; }
  done
  if [[ -z "$_rconf" ]]; then
    mark_skip "redis: memory ceiling" "redis.conf not found"
  else
    backup_once "$_rconf"
    as_root sed -i -E "s|^[[:space:]]*#?[[:space:]]*maxmemory[[:space:]]+.*|maxmemory ${REDIS_MAXMEMORY}|" "$_rconf"
    as_root sed -i -E "s|^[[:space:]]*#?[[:space:]]*maxmemory-policy[[:space:]]+.*|maxmemory-policy allkeys-lru|" "$_rconf"
    grep -q '^maxmemory ' <(as_root cat "$_rconf") \
      || run_sh "echo 'maxmemory ${REDIS_MAXMEMORY}' | sudo tee -a '$_rconf' >/dev/null"
    mark_ok "redis: maxmemory ${REDIS_MAXMEMORY}, allkeys-lru"
  fi
  unset _rconf
fi

step "redis: confirm loopback bind"
if [[ "$DRY_RUN" == "1" ]]; then
  mark_skip "redis: loopback bind" "dry run"
elif ! have redis-cli || ! svc_active redis-server && ! svc_active redis; then
  mark_skip "redis: loopback bind" "server not running"
else
  _bind="$(redis-cli CONFIG GET bind 2>/dev/null | tail -1)"
  if [[ "$_bind" == *"127.0.0.1"* ]]; then
    mark_ok "redis: bound to loopback ($_bind)"
  else
    mark_fail "redis: loopback bind" "bind is '$_bind' — expected 127.0.0.1"
    manual "Redis is not bound to loopback. Set 'bind 127.0.0.1 -::1' in redis.conf and restart."
  fi
  # requirepass adds defence in depth against SSRF from local web services.
  if [[ -z "$(redis-cli CONFIG GET requirepass 2>/dev/null | tail -1)" ]]; then
    note "Redis has no requirepass. Loopback-only makes this tolerable, but any local service with an SSRF gets unauthenticated access."
  fi
  unset _bind
fi

step "redis: enable service"
if [[ "$DRY_RUN" == "1" ]]; then
  mark_skip "redis: enable service" "dry run"
elif [[ ! -d /run/systemd/system ]]; then
  mark_skip "redis: enable service" "systemd not running"
else
  _unit=redis-server
  systemctl list-unit-files 2>/dev/null | grep -q '^redis-server\.service' || _unit=redis
  if svc_enable "$_unit"; then mark_ok "redis: enabled ($_unit)"; else mark_fail "redis: enable service"; fi
  unset _unit
fi

# --------------------------------------------------------------- journald ----

# Not a database, but the same class of problem: an unbounded journal
# against a completely empty journald.conf grows without limit.
step "journald: size ceiling"
if [[ "$DRY_RUN" == "1" ]]; then
  mark_skip "journald: size ceiling" "dry run"
elif [[ ! -d /etc/systemd ]]; then
  mark_skip "journald: size ceiling" "no systemd"
else
  if printf '[Journal]\nSystemMaxUse=500M\nSystemKeepFree=1G\n' \
      | as_root tee /etc/systemd/journald.conf.d/00-size-limit.conf >/dev/null 2>&1 \
      || { as_root mkdir -p /etc/systemd/journald.conf.d && \
           printf '[Journal]\nSystemMaxUse=500M\nSystemKeepFree=1G\n' \
             | as_root tee /etc/systemd/journald.conf.d/00-size-limit.conf >/dev/null; }
  then
    mark_ok "journald: SystemMaxUse=500M"
  else
    mark_fail "journald: size ceiling"
  fi
fi
