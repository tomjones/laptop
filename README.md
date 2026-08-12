# laptop

**Rebuild a Linux development environment from nothing — then keep it backed up, and its secrets encrypted.**

Three tools that share one small library:

| | |
|---|---|
| **`setup.sh`** | install and configure a dev machine, in opt-in profiles |
| **`backup.sh`** | encrypted backups of the things that are genuinely irreplaceable |
| **`db-snapshot.sh`** | frequent local PostgreSQL snapshots, so you can undo a bad migration |

Built for WSL2 on Debian, tested there, and written to work on any mainstream
Linux. No framework, no dependencies beyond bash and coreutils.

```bash
git clone https://github.com/tomjones/laptop.git ~/laptop
cd ~/laptop
./setup.sh --list           # what is available
./setup.sh --all --dry-run  # exactly what it would do, changing nothing
./setup.sh --all            # do it
```

---

## Why this exists

Most "dotfiles" repos restore your shell config. Most setup scripts install a
package list. Neither gets you back to a *working* machine, because the things
that actually break a rebuild are the ones nothing tracks:

- binaries hand-installed into `/usr/local/bin` that no package manager knows about
- a CLI installed under one Node version and invisible from the default one
- nine hooks that all point at one absolute path you forgot to recreate
- ninety `.env` files, and no record of which services they authenticate
- a database with `datallowconn = false` that `pg_dumpall` skips without a word
- the repository with seventy commits and no remote

This tries to handle all of that, and to be honest when it cannot.

### Design rules

**Idempotent.** Every step checks before acting. Re-running is the normal way to
retry a failure.

**No `set -e` abort-all.** Most setup scripts die on the first apt hiccup with no
way to resume. Here each step is accounted for individually; failures are
collected and reported at the end, and the run continues — one broken package
does not cost you the other nine profiles.

**`--dry-run` is exhaustive.** It prints every command, every file write, and
every config change, and performs none of them.

**Never writes a secret.** It installs the tooling and then prints exactly what
you need to authenticate by hand. That checklist is the last thing every run
produces, and it is the real deliverable.

**Says what it skipped.** Silent partial success is the failure mode that makes
backups untrustworthy, so anything omitted is named.

---

## `setup.sh`

| Profile | Installs |
|---|---|
| `core` | build toolchain, native-extension headers, FIDO2, ripgrep/fd, tmux, direnv, fzf, bat, delta, yq |
| `shell` | managed `.bashrc` block, tuned readline, git defaults, the `secrets` command |
| `languages` | Node via nvm, Python via uv + pyenv, Ruby via rvm, Bun |
| `docker` | native `docker-ce` and the compose plugin — **not** Docker Desktop |
| `infra` | terraform, packer, ansible, tflint, kubectl, **session-manager-plugin** |
| `databases` | PostgreSQL and Redis hardened, plus pgcli and duckdb |
| `cloud` | aws, gh, sf, stripe, heroku, abctl |
| `salesforce` | JDK for the Apex language server, plus `sf` CLI plugins |
| `tunnels` | cloudflared, ngrok, tailscale, and the `share` command |
| `claude` | Claude Code, its config payload, commands, skills |
| `secrets` | age, sops, gitleaks, global ignore rules, the encrypted store |
| `wsl` | systemd, Windows credential symlinks, `.wslconfig` guidance |
| `optional` | mkcert, d2, visidata, csvkit, Playwright deps — and, opt-in, apache + adminer |

`--all` runs everything except profiles marked opt-in.

```bash
./setup.sh core shell languages   # just these
./setup.sh --verify               # what's missing on an existing box; installs nothing
```

Version defaults are overridable: `NODE_VERSION=20 ./setup.sh languages`,
`JDK_VERSION=21`, `PG_BIND=localhost`, `REDIS_MAXMEMORY=4gb`.

Every run is logged to `~/.local/state/laptop/setup-<stamp>.log` (ten kept);
`--no-log` disables it. An `--all` run is several hundred lines, and the detail
of what was skipped and why is exactly what you need when debugging a partial
rebuild.

### Two that are easy to overlook

**`session-manager-plugin`** (in `infra`). If your AWS hosts have no sshd and
you reach them through SSM Session Manager, the AWS CLI accepts
`aws ssm start-session` without this plugin and then fails at connection time.
The error does not point at a missing local binary, and on a freshly rebuilt
machine it means you cannot reach anything.

**A JDK** (in `salesforce`). The Apex Language Server is a Java process. Install
the Salesforce VS Code extension pack without a JDK and everything looks fine —
extensions load, syntax highlights — but completion, go-to-definition, and test
running silently do nothing, with no error naming Java.

### Distro support

| Distro | Tier | Meaning |
|---|---|---|
| Debian 12, 13 | **1** | verified — built and tested here |
| Ubuntu 22.04, 24.04 LTS | 2 | same apt path, expected to work |
| Fedora / RHEL family | 3 | best effort via a `dnf` name mapping |
| Arch | 3 | best effort via a `pacman` name mapping |
| anything else | — | detected and **refused**, rather than half-installed |

Package names differ across families, so `lib/distro.sh` carries an explicit
mapping table (`libpq-dev` → `libpq-devel` → `postgresql-libs`). Where no
equivalent exists the step is skipped loudly and listed in the summary. Tier 3
runs will have gaps; they will tell you which.

---

## Secrets

Secrets live in `~/.secrets/<project>.env`, encrypted with
[sops](https://github.com/getsops/sops) and [age](https://github.com/FiloSottile/age).
Variable *names* stay readable so diffs remain useful; only values are
encrypted. The store is local and is never pushed anywhere.

```bash
secrets init                          # provision identities, print a paper recovery key
secrets import myapp ~/myapp/.env     # encrypt an existing .env into the store
secrets myapp -- npm run dev          # run with those values in the environment
```

`sops exec-env` injects the values into one child process and nowhere else — no
plaintext file, no exported variables lingering in your shell.

### Why age

**age encrypts to multiple recipients, and any *one* of them decrypts.** That is
what makes "unlock with a passphrase **or** a hardware key" possible — they are
two recipients on one file, not two factors. Tools that compose credentials with
AND (KeePassXC, for one) cannot express this at all.

Three recipients are provisioned:

1. a **daily identity**, its key file passphrase-protected, cached in tmpfs for the session
2. a **hardware security key**, enrolled later with `secrets add-fido2`
3. a **paper recovery key**, printed once at `init` and never written to disk

The third is not decoration. Lose the passphrase *and* the security key without
it and every secret is gone permanently.

### Security keys under WSL

WSL2 is a VM with no USB passthrough, so a key plugged into the host is invisible
to Linux until you bridge it:

```powershell
winget install usbipd
usbipd list
usbipd bind   --busid <id>          # once, as admin
usbipd attach --wsl --busid <id>    # per session
```

While attached to WSL the key is detached from Windows, so Windows Hello and
browser WebAuthn using it pause until you release it. This is why the passphrase
path is provisioned first and hardware is additive.

---

## Sharing a local port

```bash
share                    # list every local listener, flagging what must not be published
share 5173               # quick Cloudflare tunnel
share 5173 --ngrok       # ngrok instead
share 5173 --funnel      # Tailscale Funnel
share 5173 --name demo   # named Cloudflare tunnel on your own domain
```

A tunnel forwards a port from the public internet straight to your machine,
bypassing NAT and any host firewall. `share` keeps a refusal list — SSH, SMTP,
plain HTTP, every database port, metrics endpoints — each with a reason, and
overridable with `--force`. It also inspects the target process for auth-bypass
environment variables and refuses if it finds one.

It cannot see through a reverse proxy to a backend, so if your dev server
proxies `/api` to something else, check that too.

---

## Backups

Two tools, because "the machine is gone" and "undo this morning" want different
things.

### `backup.sh` — disaster recovery

```bash
./backup.sh --list       # config and the include/exclude sets
./backup.sh --dry-run
./backup.sh              # files + databases + off-machine copy
```

Encrypted with your age recipients **before** anything leaves the machine, so
the destination only ever holds ciphertext. Configure in
`~/.config/laptop-backup.conf`:

```bash
BACKUP_DEST="/mnt/c/Users/you/OneDrive/backups/wsl"
BACKUP_METHOD="copy"                # or "restic" for a deduplicated remote repo
KEEP_LOCAL=14
BACKUP_EXTRA=(".my-app-secrets")    # add your own paths
```

Two things it refuses to do quietly:

- **Locked databases.** A database with `datallowconn = false` is skipped by
  `pg_dumpall` and by any naive loop, without complaint. This detects them and
  says so; `INCLUDE_LOCKED_DBS=1` unlocks, dumps, and re-locks each one.
- **Push with no destination.** If `BACKUP_DEST` is unset it says so loudly
  rather than reporting success over a backup that never left the disk.

### `db-snapshot.sh` — rollback

```bash
./db-snapshot.sh                     # snapshot every connectable database
./db-snapshot.sh --list
./db-snapshot.sh --restore mydb      # → mydb_restore_<stamp>, NOT the live one
./db-snapshot.sh --restore mydb --at 2026-08-12T09
```

Restores go to a **scratch database by default**. Inspect, diff, and only then
overwrite the live one with `--in-place`, which makes you type the database name.

Retention is a ladder: every snapshot from the last 24 hours, one per day for 14
days, one per week for 8 weeks. On a typical dev box that is single-digit
megabytes per run and a couple of gigabytes steady state.

Snapshots are stored **unencrypted at mode 0600**, deliberately — they sit on the
same disk as the live cluster, which the same user can already read with `psql`,
so encrypting them defends against nothing while adding an unlock step to the
operation that most needs to be fast. Set `DB_SNAPSHOT_MIRROR` to a path outside
the WSL filesystem and each run also writes an **age-encrypted** copy there,
which survives a corrupted WSL image. That works unattended because age encrypts
with *public* keys; only decryption needs your passphrase.

```bash
mkdir -p ~/.config/systemd/user
cp files/systemd/db-snapshot*.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now db-snapshot.timer db-snapshot-weekly.timer
sudo loginctl enable-linger "$USER"
```

> **One-time grant.** `pg_dump` as a non-superuser cannot read schemas owned by
> other roles, so some databases fail with `permission denied for schema`:
> ```bash
> sudo -u postgres psql -c "GRANT pg_read_all_data TO $USER"
> ```
> Until you run it, each snapshot deletes the partial dump a failed `pg_dump`
> leaves behind and records the omission in its `MANIFEST`. A corrupt dump
> presented as valid is worse than no dump.

### Not scriptable from inside the guest

**Git hygiene** costs nothing and removes more risk than every backup tier
combined: push what has a remote, add remotes to what doesn't, commit what has
no commits. `manifests/repos.txt` flags exactly which.

**A WSL image snapshot**, from Windows with the distro stopped:

```powershell
wsl --shutdown
wsl --export Debian D:\backups\debian-2026-08-12.tar
```

---

## Keeping it current

```bash
./capture.sh             # regenerate manifests/ from this machine
./capture.sh --payload   # also copy Claude Code config into files/claude/
```

Run it whenever you install something you would miss. See
[`manifests/README.md`](manifests/README.md) for what each file is for.

Both `manifests/*` and `files/claude/*` are **gitignored**: they enumerate real
hostnames, repository URLs, database names, open ports, and your own slash
commands. That belongs in your private notes, not in a public repo. If you fork
this into a private single-machine repository, removing those `.gitignore` lines
is a reasonable choice — just make it deliberately.

---

## Layout

```
setup.sh              entrypoint
capture.sh            regenerate manifests from a live machine
backup.sh             encrypted backup, tiers 2-4
db-snapshot.sh        frequent local PostgreSQL snapshots
lib/common.sh         logging, dry-run, idempotency, step accounting
lib/distro.sh         detection and the cross-family package map
profiles/*.sh         one file per profile, run in numeric order
files/                payloads: dotfiles, the secrets and share commands, systemd units
manifests/            generated inventory (gitignored)
```

**Adding a profile is one file.** Drop `NN-name.sh` into `profiles/` — the
numeric prefix sets run order, everything after it is the name you type, and two
optional header lines carry the metadata:

```bash
#!/usr/bin/env bash
# desc: one line, shown by --list
# default: no        # omit to include in --all
```

`setup.sh` discovers it from there. Nothing to register anywhere else.

## Development

```bash
shellcheck setup.sh capture.sh backup.sh db-snapshot.sh lib/*.sh profiles/*.sh
./setup.sh --all --dry-run
```

The honest test is a throwaway distro, because that is the situation this exists
for:

```powershell
wsl --install -d Debian --name dr-test
# inside: git clone ... ~/laptop && ~/laptop/setup.sh core shell languages docker
wsl --unregister dr-test
```

## License

MIT — see [LICENSE](LICENSE).
