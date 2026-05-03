
# 🐢 turtle-core

The hierarchical agent orchestration substrate — all the way down.

# Project template — hierarchical agent orchestration substrate

Reusable infrastructure for the methodology described in
[`methodology/agent-orchestration-spec.md`](methodology/agent-orchestration-spec.md)
(v2.1). Clone this repo, run a single setup script, and you have a working
substrate: a long-lived **architect** container, a private **git-server**
hosting two bare repos, and the ability to spin up ephemeral
**planner+coder-daemon** pairs and **auditors** on demand.

The methodology, role guides, and Docker deployment design are all in the
[`methodology/`](methodology/) directory — the substrate exists to satisfy
those specs. Read [`agent-orchestration-spec.md`](methodology/agent-orchestration-spec.md)
§3.3 for the per-role access table this substrate enforces.

---

## What you get

After running setup, you have:

| Container | Lifecycle | What it does |
|---|---|---|
| `git-server` | long-lived | Hosts `main.git` and `auditor.git` as bare repos. SSH access keyed per role; an `update` hook enforces the §3.3 access table. |
| `architect` | long-lived (restartable) | Persistent claude-code session. The human's main interlocutor. Writes briefs and `SHARED-STATE.md`; cannot modify source code. |
| `planner` | ephemeral, per section | Started by `commission-pair.sh`. Decomposes a section into task briefs, commissions coders. |
| `coder-daemon` | ephemeral, paired with planner | HTTP service on the agent network. Spawns claude-code subshells (one at a time) on the planner's command. |
| `auditor` | ephemeral, per audit | Started by `audit.sh`. Read-only on `main`, read+write on `auditor.git`. Adversarial. |

All containers run as the unprivileged `agent` user. Per-role SSH keys are
generated locally and never committed.

---

## Prerequisites

### Linux

- Docker Engine + the Compose v2 plugin (`docker-compose-plugin`).
- Your user in the `docker` group (`sudo usermod -aG docker "$USER"; newgrp docker`).
- `git`, `bash`, `openssl`, `ssh-keygen`. (Standard on every Linux distro.)

### macOS

- **Docker Desktop** OR **Colima** running with at least 4 CPUs and 8 GB
  RAM allocated to the Docker VM:
  ```
  colima start --cpu 4 --memory 8
  ```
- All other prereqs ship with macOS.
- The substrate uses **named volumes** (not bind mounts) for working
  trees, to avoid the host↔VM I/O slowdown on macOS.

### Chromebook (Crostini)

- Linux development environment enabled in **ChromeOS Settings → Linux**,
  with at least **8 GB RAM** and **16 GB disk** allocated.
- **Docker Engine (`docker-ce`) installed via apt** — *not* Docker Desktop,
  which is unreliable on Crostini due to nested virtualization.
- Performance is slower than native Linux because of the Termina VM layer;
  ephemeral container spawn times of a few seconds are normal.
- `setup-linux.sh` detects Crostini and prints these reminders before
  proceeding.

### Windows

Not yet directly supported by a dedicated script. Workaround:

1. Install WSL2 + a Linux distribution (Ubuntu, Debian, etc.).
2. Inside the WSL2 shell, install Docker Engine via apt (or use Docker
   Desktop with the WSL2 backend).
3. Run `./setup-linux.sh` from inside the WSL2 shell.

A native PowerShell entry point may be added later.

### Optional: `--adopt-existing-substrate`

If you ran setup before the substrate-identity mechanism existed (i.e.
your `claude-state-architect` Docker volume was created without the
`app.turtle-core.substrate-id` label), the first plain re-run of
`./setup-linux.sh` or `./setup-mac.sh` will fail loudly: the gate sees
no `.substrate-id` on disk and a labelless volume in Docker, and it
cannot tell which substrate the volume belongs to.

Migrate by running:

```bash
./setup-linux.sh --adopt-existing-substrate      # Linux / Crostini / WSL2
./setup-mac.sh   --adopt-existing-substrate      # macOS
```

The flag is a **one-shot migration tool**. It mints a new UUID, writes
`.substrate-id` at the repo root, and rotates `claude-state-architect`
through a scratch volume so the new label can be applied (Docker local
volumes do not allow label updates after creation). The architect
container is briefly stopped during rotation and restarted as the rest
of setup runs normally. After the flag completes, every subsequent
plain `./setup-linux.sh` / `./setup-mac.sh` will see matching state
and proceed quietly.

The flag refuses to run if `.substrate-id` already exists, if the
`claude-state-architect` volume is missing, if the volume is already
labelled, or if `infra/keys/<role>/id_ed25519` is missing for any
role — the last is brief s004's "sufficient evidence of an existing
substrate" check.

For a fresh install with no prior substrate state on the host, do
**not** use this flag — plain `./setup-linux.sh` / `./setup-mac.sh`
will detect the absent volume, generate a new identity, and label
the volume at create time.

### Optional: `--install-docker`

If you don't already have Docker on the host, the repo ships an
optional installer at [`install-docker.sh`](install-docker.sh) — an
idempotent OS-detecting script that installs Docker Engine, Compose v2,
and Buildx on Debian / Ubuntu / Crostini (via apt + the Docker apt
repository), or Colima + the Docker CLI on macOS (via Homebrew). It is
**not** invoked by setup unless you ask for it:

```bash
./setup-linux.sh --install-docker      # Linux / Crostini / WSL2
./setup-mac.sh   --install-docker      # macOS
```

Or run it directly:

```bash
./install-docker.sh
```

The flag is a **bootstrap-only mode**: the script runs
`install-docker.sh` and exits. After it completes — and after a
re-login (Linux) or shell reload so the new docker-group membership
takes effect — re-run `./setup-linux.sh` or `./setup-mac.sh` *without*
the flag to do the actual substrate setup. This deliberate two-shot
keeps system-package installation cleanly separated from agent-state
provisioning.

The default behavior of `setup-linux.sh` and `setup-mac.sh` (no flag)
is unchanged: they verify your prerequisites without provisioning
anything system-wide. If verification fails because Docker is missing,
the failure message points at `--install-docker` for users who want
the automatic path.

---

## Quickstart

```bash
git clone <wherever-this-template-lives> myproject
cd myproject

# Linux / Crostini:
./setup-linux.sh

# macOS:
./setup-mac.sh

# Verify everything came up healthy:
./verify.sh

# Attach to the architect:
./attach-architect.sh
# Inside: `claude` (or `claude --resume` to resume your session).
```

From there you and the architect produce `TOP-LEVEL-PLAN.md`, draft the
first section brief, commit it, and exit. Then:

```bash
./commission-pair.sh <section-slug>     # planner + coder-daemon
./audit.sh           <section-slug>     # auditor for the audit step
```

---

## Authentication

This template uses **the user's own** claude-code login. **No credentials
are stored in the repo, baked into images, or shared between users.** Each
user provisions their own auth into their own local Docker volume.

Two paths, picked automatically by setup:

### Path A — host-copy (preferred when available)

If you already have claude-code logged in on this machine
(`~/.claude/.credentials.json` exists), setup copies that file into the
`claude-state-architect` volume via a one-shot helper container — file to
file, never read into a shell variable. The architect then runs as the
same Claude user you are logged in as on this machine.

### Path B — in-container login (fallback)

If `~/.claude/.credentials.json` is missing (fresh user, macOS keychain
storage, etc.), setup proceeds with the architect un-authed. After setup:

```bash
./attach-architect.sh
claude auth login        # interactive OAuth; runs once
```

Your credentials persist in the `claude-state-architect` volume across
container restarts.

### Refreshing ephemeral-role credentials

Ephemeral roles (planner, coder-daemon, auditor) read claude-code credentials
from a *separate* shared volume (`claude-state-shared`) populated by setup
from the architect's volume. When the architect's OAuth access token
rotates (every several hours), the shared volume goes stale. To re-sync:

```bash
./verify.sh        # also acts as the refresh helper
```

The brief deliberately keeps the architect's full `~/.claude/` (which
includes session state, history, plugins, anything else) on its own
volume; only `.credentials.json` is propagated to ephemeral roles.

### Optional: API-key authentication

If you prefer pay-per-token via the Anthropic API instead of OAuth, copy
`.env.example` to `.env` and set `ANTHROPIC_API_KEY=sk-ant-...`. claude-code
accepts the env var in lieu of OAuth; every container in the substrate will
receive it. The two paths are mutually compatible — claude-code prefers
the env var when set.

---

## Substrate identity

A substrate is a coupled pair: a working tree on the host (with per-role
SSH keys under `infra/keys/`) and a set of Docker volumes (auth state,
bare repos, working volumes). The pair is meaningful only when both
sides belong to the same substrate. A host may legitimately host more
than one tree (e.g. a substrate-development clone alongside a real
substrate), and Docker state is global per host — running setup against
the wrong combination of tree and Docker state can silently desync them.

To make the pairing checkable, every substrate carries an explicit
identity:

- **`.substrate-id`** at the repo root — a single line containing a
  UUID v4. Generated on first-time setup. Mode 0644. Gitignored
  (per-clone, never committed).
- **`app.turtle-core.substrate-id=<uuid>`** as a label on the
  `claude-state-architect` Docker volume — set at volume creation
  time. The architect volume is the durable, owned-once carrier.

Setup checks both before any state mutation. Outcomes:

| `.substrate-id` | architect volume | Setup behavior |
|---|---|---|
| absent | absent | Fresh install — generate UUID, write sentinel, create labelled volume. |
| present | present, label matches | Ordinary re-setup — proceed quietly. |
| absent | present | Fail loudly — tree is naive of running substrate. Use `--adopt-existing-substrate` if intentional, or `docker compose down -v` for a clean slate. |
| present | absent | Fail loudly — tree describes a substrate with no live Docker state. `rm .substrate-id` for fresh install, or restore from backup. |
| present | present, label mismatch | Fail loudly — tree and Docker state are from different substrates. |

For the model in full, see
[`methodology/deployment-docker.md`](methodology/deployment-docker.md) §3.5.

`infra/scripts/generate-keys.sh` is no longer safe to run standalone
in inconsistent-state cases — it inherits the same gate. Run setup,
which performs proper diagnosis, instead of calling it directly.

---

## Role lifecycle (one-line summary; full detail in `methodology/`)

1. Architect produces `TOP-LEVEL-PLAN.md` and a section brief, commits to
   `main` at `briefs/sNNN-slug/section.brief.md`.
2. Human runs `./commission-pair.sh sNNN-slug`. The planner decomposes the
   section, commissions coders via the daemon, merges PRs into the
   section branch, writes the section report, discharges.
3. Architect produces `briefs/sNNN-slug/audit.brief.md`. Human runs
   `./audit.sh sNNN-slug`. The auditor produces the audit report in
   `auditor.git`, discharges.
4. Architect ferries the audit report into `main`. Human and architect
   decide pass / conditional pass / rework.
5. Pass → human merges section branch into main. Repeat for next section.

---

## Commissioning

### Planner pair (per section)

```bash
./commission-pair.sh s001-hello-timestamps
```

The script:

1. Generates a random TCP port (10000–65535) and a random 43-char bearer
   token (`openssl rand -base64 48 | tr -d '\n=+/' | cut -c1-43`).
2. Writes `.pairs/.pair-s001-hello-timestamps.env` (mode 0600).
3. Brings up `coder-daemon` for this section in its own compose project
   namespace (so multiple pairs can run in parallel).
4. Prints a commissioning summary block for you to paste into the planner.
5. Runs the planner in the foreground.

When the planner exits — discharge or kill — the trap runs `compose down -v`
to dispose the daemon and the ephemeral env file.

The daemon's HTTP API (`POST /commission`, `GET /commission/{id}`,
`GET /commission/{id}/wait`, `POST /commission/{id}/cancel`,
`GET /commissions`) is documented in
[`methodology/deployment-docker.md`](methodology/deployment-docker.md)
§4.

### Auditor (per audit)

```bash
./audit.sh s001-hello-timestamps
```

The auditor reads `briefs/s001-hello-timestamps/audit.brief.md` and writes
its report to `auditor.git`. After it exits, follow the on-screen prompt
to have the architect ferry the report into `main`.

---

## Troubleshooting

### `setup-*.sh` fails on prereq check

Install whatever it names. The script does not provision tools; it only
verifies them.

### Setup says my tree and Docker state are from different substrates

The `.substrate-id` at the repo root and the `app.turtle-core.substrate-id`
label on the `claude-state-architect` Docker volume disagree. The tree
and the Docker state belong to different substrates — running setup
would have desynced one from the other, so it refused.

Diagnose the volume's claimed identity:

```bash
docker volume inspect claude-state-architect --format '{{json .Labels}}'
```

Compare to your sentinel:

```bash
cat .substrate-id
```

Resolve by ONE of:

- Switch to the tree whose `.substrate-id` matches the volume's label.
- Tear down the wrong substrate's Docker state and start fresh:
  `docker compose down -v --remove-orphans`
- If you are deliberately re-pointing this tree at a different substrate
  (rare), `rm .substrate-id` and consider whether
  `--adopt-existing-substrate` fits.

### Setup says I have Docker state for a substrate this tree doesn't know about

The `claude-state-architect` volume exists on this host, but this tree
has no `.substrate-id`. The tree is naive of the running substrate;
running setup here would silently regenerate per-role keys and fight
the running substrate for the same volumes.

Resolve by ONE of:

- `./setup-linux.sh --adopt-existing-substrate` (or `setup-mac.sh`) —
  IF AND ONLY IF you are sure this tree corresponds to the running
  Docker substrate. See "Optional: `--adopt-existing-substrate`" in
  Prerequisites.
- Tear down the live substrate's Docker state, then re-run setup
  for a fresh install: `docker compose down -v --remove-orphans`
- Switch to the correct tree.

Diagnose the live substrate's identity:

```bash
docker volume inspect claude-state-architect --format '{{json .Labels}}'
```

### Setup says my tree describes a substrate with no live Docker state

The `.substrate-id` is present but the `claude-state-architect` volume
does not exist. Either the volume was removed (e.g. `compose down -v`),
you are setting up on a different host than the original setup, or you
restored the tree from backup but not the volumes.

Resolve by ONE of:

- Re-attach this tree to a fresh substrate: `rm .substrate-id` and
  re-run setup. This generates a new substrate identity.
- Restore the matching architect volume from backup (with its
  `app.turtle-core.substrate-id` label intact), then re-run setup.

### `verify.sh` fails after setup

Check the listed items. Common causes:

- **Architect cannot reach git-server over ssh.** Almost always means
  `infra/keys/architect/id_ed25519` was not generated. Re-run setup; it
  is idempotent.
- **`claude-state-architect` volume missing.** First-time setup may have
  exited before reaching the auth provisioning step. Re-run setup.

### Architect refreshed its OAuth token; ephemeral roles fail auth

Run `./verify.sh` — it doubles as the refresh helper. Internally it runs
a one-shot `debian:bookworm-slim` container to copy the architect's
`.credentials.json` into the shared volume.

### Nuke and start over

This destroys all substrate state, including any commits to `main.git`,
`auditor.git`, and the architect's claude-code session:

```bash
docker compose down -v --remove-orphans
docker network rm agent-net 2>/dev/null || true
rm -f .substrate-id
# Re-run setup:
./setup-linux.sh
```

To reset only the planner/coder-daemon state for a hung pair:

```bash
docker compose -p $(basename "$PWD")-<section> --profile ephemeral down -v
rm -f .pairs/.pair-<section>.env
```

### Coder subshell hangs

The daemon's `wait()` blocks on the subshell. Cancel it via the API:

```bash
docker compose -p $(basename "$PWD")-<section> exec coder-daemon \
    sh -c 'curl -fsSL -X POST http://$(hostname -i):$COMMISSION_PORT/commission/<id>/cancel \
                 -H "Authorization: Bearer $COMMISSION_TOKEN"'
```

Or just tear the pair down (`Ctrl-C` in the foreground planner shell, or
`docker compose -p ... kill coder-daemon`).

### Inspect commission history

While a pair is running:

```bash
docker compose -p $(basename "$PWD")-<section> exec coder-daemon \
    sqlite3 /data/commissions.db \
    'SELECT commission_id, status, started_at, exit_code, error
       FROM commissions ORDER BY started_at;'
```

---

## What this template does NOT do

- **Project source code.** Empty by design. The first project will be the
  proof-of-concept "hello world with timestamps" CLI, drafted via the
  methodology after the substrate is trusted.
- **CI / production deployment.** Standard CI on PRs to section branches,
  outside the methodology. The methodology stops at "section merged to
  `main`, audit passed."
- **Backups.** The `main-repo-bare`, `auditor-repo-bare`, and architect
  state volumes need backing up like any git remote. Operator's choice.
- **Multi-host deployments.** The compose model assumes a single host.

---

## Layout

```
project-template/
├── README.md                ← this file
├── docker-compose.yml       ← long-lived (git-server, architect) and
│                              ephemeral-profile (planner, coder-daemon,
│                              auditor) services
├── setup-linux.sh           ← Linux + Crostini entry point
├── setup-mac.sh             ← macOS entry point
├── setup-common.sh          ← shared setup body
├── verify.sh                ← smoke test + creds-refresh helper
├── commission-pair.sh       ← start a planner+coder-daemon for one section
├── audit.sh                 ← start an auditor for one section
├── attach-architect.sh      ← convenience wrapper for `docker compose attach`
├── infra/
│   ├── base/Dockerfile
│   ├── architect/Dockerfile + entrypoint.sh
│   ├── planner/Dockerfile   + entrypoint.sh
│   ├── coder-daemon/Dockerfile + entrypoint.sh + daemon.js + package.json
│   ├── auditor/Dockerfile   + entrypoint.sh
│   ├── git-server/Dockerfile + entrypoint.sh + init-repos.sh +
│   │                          git-shell-wrapper + hooks/update
│   ├── keys/                ← per-role SSH keys (gitignored except .gitkeep)
│   └── scripts/generate-keys.sh
├── methodology/             ← spec, architect-guide, planner-guide, auditor-guide
├── briefs/                  ← runtime: section/task briefs and reports
├── .pairs/                  ← runtime: per-pair env files (gitignored)
├── .gitignore
└── .env.example
```

---

## Pointers

- **`methodology/agent-orchestration-spec.md`** — what this substrate
  implements. §3 is the contract.
- **`methodology/architect-guide.md`** / **`planner-guide.md`** /
  **`auditor-guide.md`** — what each ephemeral role should do; loaded
  into their containers read-only at `/methodology`.
