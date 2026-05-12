# 🐢 turtle-core

The hierarchical agent orchestration substrate — all the way down.

# Project template — hierarchical agent orchestration substrate

Reusable infrastructure for the methodology described in
[`methodology/agent-orchestration-spec.md`](methodology/agent-orchestration-spec.md)
(v2.3). Clone this repo, run a single setup script, and you have a working
substrate: a long-lived **architect** container, a private **git-server**
hosting two bare repos, the ability to spin up ephemeral
**planner+coder-daemon** pairs and **auditors** on demand, and an
**onboarder** + **code migration agent** sub-agent for importing existing codebases as new turtle-core projects.

The methodology, role guides, and Docker deployment design are all in the
[`methodology/`](methodology) directory — the substrate exists to satisfy
those specs. Read [`agent-orchestration-spec.md`](methodology/agent-orchestration-spec.md)
§3.3 for the per-role access table this substrate enforces.

---

## What you get

After running setup, you have:

| Container       | Lifecycle                          | What it does |
| --------------- | ---------------------------------- | --- |
| `git-server`    | long-lived                         | Hosts `main.git` and `auditor.git` as bare repos. SSH access keyed per role; an `update` hook enforces the §3.3 access table. |
| `architect`     | long-lived (restartable)           | Persistent claude-code session. The human's main interlocutor. Writes briefs and `SHARED-STATE.md`; cannot modify source code. |
| `planner`       | ephemeral, per section             | Started by `commission-pair.sh`. Decomposes a section into task briefs, commissions coders. |
| `coder-daemon`  | ephemeral, paired with planner     | HTTP service on the agent network. Spawns claude-code subshells (one at a time) on the planner's command. |
| `auditor`       | ephemeral, per audit               | Started by `audit.sh`. Read-only on `main`, read+write on `auditor.git`. Adversarial. |
| `onboarder`     | ephemeral, per brownfield project  | Started by `onboard-project.sh`. Across three phases: elicits structure with the operator, commissions the code migration agent, integrates its findings into the final handover. Brownfield only — greenfield projects skip this entirely. |
| `code-migration`| ephemeral, per onboarding (sub-agent of onboarder) | Dispatched by `infra/scripts/dispatch-code-migration.sh` between onboarder phases 1 and 3. Performs structural review of the brownfield source (lint, syntax, dependency resolution, import-graph closure, orphan detection — no build or behavioural test) and commits a survey report consumed by the onboarder's phase-3 integration pass. |

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

      colima start --cpu 4 --memory 8

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
```

From here, two paths depending on whether you're starting fresh or
importing an existing codebase.

### Greenfield: start a new project from scratch

```bash
./attach-architect.sh
# Inside: `claude` (or `claude --resume` to resume your session).
```

You and the architect produce `TOP-LEVEL-PLAN.md`, draft the first
section brief, commit it, and exit.

### Brownfield: import an existing codebase

```bash
./onboard-project.sh /path/to/existing/project
# Or with an explicit platform set (skips inference):
./onboard-project.sh /path/to/existing/project --platforms python-extras,node-extras
```

The script ingests the source tree (single-shot — fails if `main.git`
already has commits), then drives a three-phase onboarding:

1. **Phase 1.** The onboarder runs interactively. Platforms are inferred
   from canonical signal files at the source root (`package.json`,
   `requirements.txt` / `pyproject.toml`, `Cargo.toml`, `go.mod`,
   `platformio.ini`, `CMakeLists.txt`, `Makefile`); the operator confirms
   or corrects. `--platforms=<csv>` bypasses inference entirely. The
   onboarder elicits priorities and unknowns, writes a migration brief
   commissioning the code migration agent, and writes a draft handover
   (section 3 deferred to phase 3). Discharges.

2. **Phase 2.** The host dispatches the code migration agent autonomously.
   The agent reads `/source` (read-only), runs the lint / type-check /
   dependency-resolve probes its tool surface grants, and commits a
   six-section structural-survey report at
   `briefs/onboarding/code-migration.report.md`. No operator interaction.

3. **Phase 3.** A fresh onboarder container reads the migration report
   and integrates its findings into section 3 of the handover. The final
   handover is written to `briefs/onboarding/handover.md`. The architect
   container restarts and picks up the handover on next attach.

```bash
./attach-architect.sh
# Inside: the architect sees the handover with the code-migration agent's
# structural findings already integrated; drafts the first section brief.
```

`--type 1|2|3|4` (source-material taxonomy) and `--platforms <csv>`
(target-language toolchains) are **independent axes**; both, either, or
neither may be supplied. See
[`methodology/deployment-docker.md`](methodology/deployment-docker.md) §6.4 for the full onboarding workflow.

### Either path — section work from then on

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

Ephemeral roles (planner, coder-daemon, auditor, onboarder, code-migration) read
claude-code credentials from a *separate* shared volume
(`claude-state-shared`) populated by setup from the architect's volume.
When the architect's OAuth access token rotates (every several hours),
the shared volume goes stale. To re-sync:

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

0. **(Brownfield only.)** Operator runs `./onboard-project.sh <path>`.
   The substrate runs a three-phase onboarding: onboarder elicits +
   commissions a migration brief, host dispatches the code migration
   agent for structural survey, onboarder integrates the agent's findings
   into the final handover. Architect restarts and reads the handover on
   first attach.
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
[`methodology/deployment-docker.md`](methodology/deployment-docker.md) §4.

### Auditor (per audit)

```bash
./audit.sh s001-hello-timestamps
```

The auditor reads `briefs/s001-hello-timestamps/audit.brief.md` and writes
its report to `auditor.git`. After it exits, follow the on-screen prompt
to have the architect ferry the report into `main`.

### Onboarder + code migration agent (per brownfield project, once)

```bash
./onboard-project.sh /path/to/existing/project [--platforms <csv>]
```

The script:

1. Checks the substrate is up and that `main.git` has no commits yet
   (single-shot — onboarding only runs against a fresh substrate).
2. Generates onboarder and code-migration keypairs if not already present.
3. Imports the source tree into a temporary clone of `main.git` via a
   one-shot helper container, then pushes the initial commit.
4. Infers target-language platforms from canonical signal files at the
   source root, unless `--platforms=<csv>` was supplied (in which case
   that set is authoritative; inference is skipped).
5. **Phase 1.** Brings up an `onboarder` container interactively for
   elicitation. Writes the migration brief
   (`briefs/onboarding/code-migration.brief.md`) and a draft handover
   (`briefs/onboarding/handover.draft.md`). Discharges.
6. **Phase 2.** Runs `infra/scripts/dispatch-code-migration.sh`. The
   code-migration agent composes its image with the declared platforms,
   reads `/source`, runs survey probes per the brief's tool surface, and
   commits the migration report
   (`briefs/onboarding/code-migration.report.md`). Autonomous; no
   operator-in-loop.
7. **Phase 3.** Brings up a fresh `onboarder` container interactively
   for findings integration. Reads the migration report and the draft
   handover, writes the final `briefs/onboarding/handover.md`, discharges.
8. Restarts the architect container so it picks up the handover on next
   attach.

See [`methodology/deployment-docker.md`](methodology/deployment-docker.md) §6.4
for the full onboarding workflow.

---

## Watching agents at work

```bash
./watch-agent.sh                  # auto-detect (one role container running)
./watch-agent.sh planner          # name the role: planner | coder-daemon | auditor | architect
./watch-agent.sh <container-name> # exact container name (no fuzzy match)
./watch-agent.sh -r               # raw JSONL instead of pretty-printed
```

Tails the active claude-code session JSONL inside a running role
container, pretty-printed event-by-event — text turns, tool calls, tool
results, thinking markers. Auto-follows when a new session appears
inside the same container, which makes it particularly useful for
`coder-daemon` (which spawns a fresh sub-session per task) and for any
chained run where one session ends and another begins.

Requires `jq` inside the container for pretty-printing; falls back to
raw JSONL if missing. `Ctrl-C` to stop.

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

### `onboard-project.sh` fails with "main.git already has commits"

Onboarding is single-shot by design — it only runs against a fresh
substrate. If you've already pushed coordination commits to `main.git`,
either start over (`docker compose down -v` and re-run setup) or proceed
greenfield by attaching the architect directly.

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

- **Project source code.** Empty by design for greenfield use. Brownfield
  use imports an existing tree via the onboarder.
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
├── CLAUDE.md                ← substrate-internal (see note below)
├── FINDINGS.md              ← substrate-internal (see note below)
├── docker-compose.yml       ← long-lived (git-server, architect) and
│                              ephemeral-profile (planner, coder-daemon,
│                              auditor, onboarder, code-migration) services
├── setup-linux.sh           ← Linux + Crostini entry point
├── setup-mac.sh             ← macOS entry point
├── setup-common.sh          ← shared setup body
├── install-docker.sh        ← optional Docker installer (idempotent, OS-detecting)
├── verify.sh                ← smoke test + creds-refresh helper
├── commission-pair.sh       ← start a planner+coder-daemon for one section
├── audit.sh                 ← start an auditor for one section
├── onboard-project.sh       ← start an onboarder for a brownfield import
├── attach-architect.sh      ← convenience wrapper for `docker compose attach`
├── watch-agent.sh           ← tail the active session JSONL in a role container
├── infra/
│   ├── base/Dockerfile
│   ├── architect/Dockerfile + entrypoint.sh
│   ├── planner/Dockerfile   + entrypoint.sh
│   ├── coder-daemon/Dockerfile + entrypoint.sh + daemon.js + package.json
│   ├── auditor/Dockerfile   + entrypoint.sh
│   ├── onboarder/Dockerfile + entrypoint.sh
│   ├── code-migration/Dockerfile + entrypoint.sh  ← s014: code migration agent
│   ├── git-server/Dockerfile + entrypoint.sh + init-repos.sh +
│   │                          git-shell-wrapper + hooks/update
│   ├── keys/                ← per-role SSH keys (gitignored except .gitkeep)
│   └── scripts/
│       ├── generate-keys.sh
│       ├── render-dockerfile.sh        ← s009 setup-time renderer; s013 added --stdout mode
│       ├── compose-image.sh            ← s013: JIT platform composition (hash-tagged role images)
│       ├── resolve-platforms.sh        ← s013: section+TLP+s009-fallback resolution
│       ├── validate-tool-surface.sh    ← s013: brief-declared binaries vs image PATH (F52 closure)
│       ├── dispatch-code-migration.sh  ← s014: host-side dispatcher for the code-migration agent
│       ├── infer-platforms.sh          ← s014: canonical signal-file inference for /source
│       └── lib/
│           ├── parse-tool-surface.sh   ← s011: section/audit-brief allowed-tools parser
│           ├── parse-platforms.sh      ← s013: Required platforms / ## Platforms parser
│           └── validate-platform.sh    ← s009: platform YAML schema validator
├── methodology/             ← spec, architect/planner/auditor/onboarder guides;
│   └── platforms/<name>.yaml ← platform registry (s009 + s013 hash semantics)
├── briefs/                  ← runtime: section/task briefs and reports
├── .pairs/                  ← runtime: per-pair env files (gitignored)
├── .gitignore
└── .env.example
```

### Substrate-internal artifacts (`CLAUDE.md`, `FINDINGS.md`)

These two files at the repo root are for chat-Claude sessions and
implementing agents doing **substrate-iteration** work on turtle-core
itself — not for operator workflow on your own project.

- `CLAUDE.md` is auto-loaded by Claude Code when you run `claude` from
  the repo root. It orients an agent to the substrate-iteration work
  mode and the boundary between `methodology/` (exported to user
  projects) and substrate-internal artifacts.
- `FINDINGS.md` is the canonical register of substrate-iteration
  findings by F-number, with status, severity, origin, and resolution.

Both are safe to ignore if you're using turtle-core for your own
project. They don't enter any role container's view at runtime.

---

## Pointers

- **[`methodology/agent-orchestration-spec.md`](methodology/agent-orchestration-spec.md)** — what this substrate
  implements. §3 is the contract.
- **[`methodology/architect-guide.md`](methodology/architect-guide.md)** /
  **[`planner-guide.md`](methodology/planner-guide.md)** /
  **[`auditor-guide.md`](methodology/auditor-guide.md)** /
  **[`onboarder-guide.md`](methodology/onboarder-guide.md)** /
  **[`code-migration-agent-guide.md`](methodology/code-migration-agent-guide.md)** —
  what each role should do; loaded into their containers read-only at
  `/methodology`. The migration-brief and migration-report templates
  ([`code-migration-brief-template.md`](methodology/code-migration-brief-template.md),
  [`code-migration-report-template.md`](methodology/code-migration-report-template.md))
  are sibling references the onboarder and the code migration agent
  both consume during brownfield onboarding.
- **[`methodology/deployment-docker.md`](methodology/deployment-docker.md)** — the deployment design that the
  compose file and entrypoints implement.
- **[`methodology/platforms/`](methodology/platforms)** — the platform
  registry. Architects reference this when authoring TOP-LEVEL-PLAN.md's
  `## Platforms` section and section briefs' `Required platforms`
  field. The schema and per-platform install layers are documented in
  [`methodology/platforms/README.md`](methodology/platforms/README.md);
  the composition hash semantics that drive cache reuse / invalidation
  are documented there too.
