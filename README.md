
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
[`methodology/deployment-docker.md`](methodology/agent-orchestration-spec.md)
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
