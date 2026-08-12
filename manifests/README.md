# manifests/

Generated inventory of the machine `capture.sh` was last run on.

**These files are gitignored.** This README is the only tracked file in the
directory. That is deliberate — see [Why they are not committed](#why-they-are-not-committed).

```bash
./capture.sh             # write/refresh everything here
./capture.sh --payload   # also copy Claude Code config into ../files/claude/
```

## What each file is for

| File | Contents | Used when |
|---|---|---|
| `apt-manual.txt` | every explicitly-installed apt package | rebuilding: `xargs -a apt-manual.txt sudo apt-get install -y` |
| `rpm-manual.txt` / `pacman-manual.txt` | the same, on those families | rebuilding on Fedora/RHEL or Arch |
| `apt-sources.txt` | third-party repositories and their signing keys | knowing which repos to re-add before installing |
| `node.txt` | node versions, the default alias, global packages | restoring your Node setup |
| `python.txt` | interpreters, `uv` tools, `pipx` packages, `--user` installs | restoring Python tooling |
| `ruby.txt` | rubies and notable gems | restoring Ruby |
| `local-binaries.txt` | executables in `/usr/local/bin`, `~/.local/bin`, `/opt` | the silent-loss list — things no package manager will bring back |
| `services.txt` | enabled units, custom units, timers | knowing what should be running |
| `ports.txt` | listening sockets and their owners | spotting what is exposed, and on which interface |
| `postgres-databases.txt` | database names and owners (never contents) | knowing what to restore |
| `repos.txt` | every git repo with branch, remote, and a risk flag | re-cloning, and finding work that exists nowhere else |

## `repos.txt` is the interesting one

It carries a `RISK` column, which is worth reading rather than just archiving:

| Flag | Meaning |
|---|---|
| `NO-COMMITS` | a git repo with no commits — the content is untracked files only |
| `NO-REMOTE` | commits exist, but only on this disk |
| `UNPUSHED:n` | `n` commits that no remote has seen |
| `DIRTY:n` | `n` uncommitted changes |
| `ok` | clean and pushed |

Anything flagged `NO-COMMITS` or `NO-REMOTE` will not survive losing the
machine, no matter how good your backups are — a backup of a laptop is not a
substitute for a remote. Run `capture.sh` occasionally and read that column.

## Why they are not committed

The manifests enumerate, for whoever generated them: installed software,
listening ports and their bind addresses, database names, and every repository
path and remote URL on the machine.

None of that is a credential. Collectively it is a precise map of one person's
attack surface, and in a work context it also leaks project and client names
through repository and database naming.

So: **generate them locally, keep them in your own private notes, and treat the
tracked part of this repository as generic tooling that anyone can use.**

If you fork this for a private, single-machine repository, deleting the
`manifests/*` lines from `.gitignore` is a perfectly reasonable thing to do —
committing them gives you a version-controlled history of how the machine
changed over time, which is genuinely useful. Just make the choice deliberately.

## Keeping them fresh

Run `capture.sh` whenever you install something you would miss. If you do commit
them in a private fork, reading `git diff manifests/` afterwards doubles as a
monthly review of what has quietly accumulated on your machine.
