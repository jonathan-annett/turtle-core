# Deployment: Docker

Companion to the methodology spec (v2.1). The spec defines *what the substrate must do* (especially §3.3, the per-role access table); this document shows *how Docker does it*. Operational, not normative — if a detail here conflicts with the spec, the spec wins.

---

## 1. The five-container model

Each project runs five container types:

| Container | Lifecycle | Purpose |
|---|---|---|
| `git-server` | long-lived | Hosts bare repos for `main.git` and `auditor.git`. |
| `architect` | long-lived (restartable) | Persistent claude-code session resumed across human work sessions. Maintains `SHARED-STATE.md` and `TOP-LEVEL-PLAN.md`; produces section briefs and audit briefs; ferries audit reports from the auditor repo into the main repo. |
| `planner` | ephemeral, per section | Fresh claude-code instance. Started by the human when the architect has produced a section brief. Decomposes the section into task briefs; commissions coders via the coder daemon. Discharges when the section is done. |
| `coder-daemon` | ephemeral, paired with planner | Node HTTP server that accepts task-brief commissions from the planner and runs each coder as a subshell to completion. One coder at a time. Lives the same lifetime as its planner. |
| `auditor` | ephemeral, per audit | Fresh claude-code instance. Started by the human when the architect has produced an audit brief. Has read access to the main repo (at the section branch tip) and read/write access to the auditor repo. Discharges when the audit is done. |

The `coder-daemon` is what gives the planner autonomy: the planner can commission coders iteratively without the human in the loop for every task. The planner posts to the daemon over HTTP; the daemon spawns coder subshells inside its own container; sqlite tracks the audit trail.

Coder subshells are *not* their own containers. They share the daemon's filesystem and identity. Cross-project isolation is preserved by running the whole pair in a project-scoped compose namespace; cross-task isolation within a section is methodology discipline plus the git server's per-branch hooks. (Concurrent coders are not part of this methodology — one coder at a time per planner.)

---

## 2. Reference `docker-compose.yml`

Skeleton — adjust paths and image tags for the specific project.

```yaml
version: "3.9"

services:
  git-server:
    build: ./infra/git-server
    container_name: agent-git-server
    volumes:
      - main-repo-bare:/srv/git/main.git
      - auditor-repo-bare:/srv/git/auditor.git
      - ./infra/keys:/srv/keys:ro
    networks:
      - agent-net
    restart: unless-stopped

  architect:
    build: ./infra/architect
    container_name: agent-architect
    volumes:
      - architect-workspace:/work          # working clone of main, persists
      - architect-claude-state:/home/agent/.config/claude  # session resume token
      - architect-auditor-clone:/auditor   # read-only clone of auditor repo
      - ./methodology:/methodology:ro
      - ./infra/keys/architect:/home/agent/.ssh:ro
    networks:
      - agent-net
    depends_on:
      - git-server
    stdin_open: true
    tty: true

  planner:
    build: ./infra/planner
    profiles: ["ephemeral"]
    environment:
      COMMISSION_HOST: ${COMMISSION_HOST}
      COMMISSION_PORT: ${COMMISSION_PORT}
      COMMISSION_TOKEN: ${COMMISSION_TOKEN}
    volumes:
      - ./methodology:/methodology:ro
      - ./infra/keys/planner:/home/agent/.ssh:ro
    networks:
      - agent-net
    depends_on:
      - git-server
      - coder-daemon
    stdin_open: true
    tty: true

  coder-daemon:
    build: ./infra/coder-daemon
    profiles: ["ephemeral"]
    environment:
      COMMISSION_PORT: ${COMMISSION_PORT}
      COMMISSION_TOKEN: ${COMMISSION_TOKEN}
    volumes:
      - coder-daemon-state:/data           # sqlite db
      - ./methodology:/methodology:ro
      - ./infra/keys/coder:/home/agent/.ssh:ro
    networks:
      - agent-net
    depends_on:
      - git-server

  auditor:
    build: ./infra/auditor
    profiles: ["ephemeral"]
    volumes:
      - ./methodology:/methodology:ro
      - ./infra/keys/auditor:/home/agent/.ssh:ro
    networks:
      - agent-net
    depends_on:
      - git-server
    stdin_open: true
    tty: true

volumes:
  main-repo-bare:
  auditor-repo-bare:
  architect-workspace:
  architect-claude-state:
  architect-auditor-clone:
  coder-daemon-state:

networks:
  agent-net:
    driver: bridge
```

Notes:

- **`profiles: ["ephemeral"]`** on planner, coder-daemon, auditor means `docker compose up` doesn't start them by default. They're started explicitly per section/audit.
- **Architect persists `claude-state`** on a named volume so its claude-code session can be resumed across container restarts.
- **Architect has a separate `auditor-clone` volume** — a read-only checkout of `auditor.git`. Periodically refreshed (the architect runs `git fetch` in that directory when an audit completes). This is the spec §3.8 ferry mechanism.
- **No host port exposures.** All services communicate over the `agent-net` bridge network. The compose network is unreachable from outside the host and from other compose projects (which run with their own `-p` namespace and their own networks).

---

## 3. Network model and authentication

### 3.1 Network isolation

Each project runs with its own compose project name (via `-p <project-name>` or the directory-name default). Each gets its own bridge network. Containers in one project's network cannot reach containers in another's. This is the boundary that matters for "the daemon is reachable only by its paired planner."

### 3.2 Per-pair credentials

When the human starts a planner/daemon pair, a script generates a random port and a random token:

- `COMMISSION_PORT`: random, unprivileged, e.g. via `shuf -i 10000-65535 -n 1`.
- `COMMISSION_TOKEN`: 32 bytes of `openssl rand -base64 32`.

These are written to a `.pair-<section>.env` file (mode 0600, owned by the human) and passed to compose via `--env-file`. Both `coder-daemon` and `planner` see the same values via env vars.

### 3.3 Daemon access controls

The daemon enforces three checks on every incoming request, in order:

1. **Network**: daemon binds to its compose-network interface (not `0.0.0.0`, not host-routable). Outside-network connections are not possible.
2. **Token**: every request must carry `Authorization: Bearer <token>` matching `COMMISSION_TOKEN`. Failure returns 401 immediately, before any logic runs.
3. **Source IP** (defense in depth): daemon learns the planner's container IP at startup (from `getent hosts planner` or compose-DNS resolution) and rejects requests from any other source.

The first check is the boundary that does the work; checks 2 and 3 are belt and braces.

### 3.4 Pairing script

The human runs one script per section. Skeleton:

```bash
#!/bin/bash
# commission-pair.sh <section-slug>
# Starts a coder-daemon and planner for a section, with random port + token.

set -euo pipefail

section="$1"
project="$(basename "$PWD")-$section"

port=$(shuf -i 10000-65535 -n 1)
token=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-43)

env_file=".pairs/.pair-$section.env"
mkdir -p .pairs
umask 077
cat > "$env_file" <<EOF
COMMISSION_HOST=coder-daemon
COMMISSION_PORT=$port
COMMISSION_TOKEN=$token
EOF

cleanup() {
  echo "Tearing down $project..."
  docker compose -p "$project" --env-file "$env_file" down -v
  rm -f "$env_file"
}
trap cleanup EXIT INT TERM

# Start the daemon (background).
docker compose -p "$project" --env-file "$env_file" up -d coder-daemon

# Print commissioning summary for the human to relay to the planner.
brief_path="briefs/$section/section.brief.md"
echo
echo "=== Planner commissioning summary ==="
echo "Section: $section"
echo "Brief:   $brief_path"
echo "Daemon:  http://coder-daemon:$port (token in env)"
echo "Paste this into the planner at startup."
echo

# Start the planner (foreground; this script blocks until planner exits).
docker compose -p "$project" --env-file "$env_file" run --rm planner
```

When the planner exits — either by completing the section or being killed by the human — the `trap` runs `compose down -v` to dispose the daemon and its sqlite volume, and removes the env file.

For the auditor (one-shot, no daemon needed):

```bash
#!/bin/bash
# audit.sh <section-slug>
section="$1"
project="$(basename "$PWD")-audit-$section"
docker compose -p "$project" run --rm auditor
```

Auditor reads the audit brief from the main repo (it has a fresh clone), produces the audit report into the auditor repo, exits.

---

## 4. The commission daemon

### 4.1 Behavior

- Single HTTP server, node + sqlite.
- One coder subshell at a time. Concurrent commission requests return 409.
- Async API: planner posts a commission, gets back a `commission_id`, polls for completion.
- All commissions logged to sqlite for audit trail.
- On startup: read `COMMISSION_PORT` and `COMMISSION_TOKEN` from env, bind, listen.
- On shutdown signal: finish current commission (if any), flush sqlite, exit.

### 4.2 API

```
POST /commission
  Auth: Bearer <COMMISSION_TOKEN>
  Body: {
    "brief_path": "briefs/s003-feature/t001-foo.brief.md",
    "section_branch": "section/003-feature",
    "task_branch":    "task/003.001-foo"
  }
  Returns 200: { "commission_id": "uuid", "status": "queued" }
  Returns 409 if a coder is already running.

GET /commission/{id}
  Auth: Bearer <COMMISSION_TOKEN>
  Returns: {
    "commission_id":   "uuid",
    "status":          "queued" | "running" | "complete" | "failed",
    "started_at":      "...",
    "finished_at":     "..." | null,
    "exit_code":       0,
    "report_path":     "briefs/s003-feature/t001-foo.report.md" | null,
    "error":           "..." | null
  }

GET /commission/{id}/wait?timeout=300
  Long-poll: returns same as GET when status changes to terminal,
  or after timeout. Planner re-polls on timeout.

POST /commission/{id}/cancel
  Sends SIGTERM to the coder subshell. Status becomes "failed" with
  error="cancelled".

GET /commissions?status=...&limit=...
  List, for the human's audit trail.
```

### 4.3 Subshell mechanics

When a commission starts, the daemon:

1. Fetches the latest section branch into a fresh working directory under `/work/coder-<commission_id>/`.
2. Checks out the section branch, creates the task branch.
3. Writes an instruction file pointing claude-code at the brief path.
4. Spawns `claude-code` as a child process (with the per-role flags from §4.5), captures stdout/stderr to per-commission log files.
5. Waits for the process to exit.
6. Verifies that the expected report file exists at `briefs/<section>/<task>.report.md` on the task branch tip.
7. Records exit code, finish time, report path in sqlite.
8. Cleans up `/work/coder-<commission_id>/`.

If the coder doesn't push (network error, bug, runaway agent), the daemon notes status as `failed` with diagnostic info. The planner can decide to re-commission.

### 4.4 sqlite schema

```sql
CREATE TABLE commissions (
  commission_id    TEXT PRIMARY KEY,
  brief_path       TEXT NOT NULL,
  section_branch   TEXT NOT NULL,
  task_branch      TEXT NOT NULL,
  status           TEXT NOT NULL,           -- queued | running | complete | failed
  started_at       TEXT,
  finished_at      TEXT,
  exit_code        INTEGER,
  report_path      TEXT,
  error            TEXT,
  log_path         TEXT
);
CREATE INDEX idx_status ON commissions(status);
CREATE INDEX idx_started ON commissions(started_at);
```

The sqlite db lives on the `coder-daemon-state` named volume so the audit trail survives daemon restarts within a session. It's destroyed when the planner exits and the script's `compose down -v` runs.

### 4.5 Per-role invocation flags

Each role invokes `claude-code` with a different combination of flags, reflecting the methodology's asymmetry: the coder has no discretion, the planner has section-scope discretion, the auditor has adversarial license. The invocation flags make that asymmetry operational.

#### Coder

- `-p` (or stream-json under the daemon).
- `--permission-mode dontAsk`.
- `--allowedTools` populated from the task brief's "Required tool surface" field (spec §7.3). The daemon reads the field at commission time and translates it into the flag value when spawning the subshell. If the brief lacks the field, the commission fails with a clear error rather than defaulting to a permissive list.

Out-of-allowlist actions deny and surface as task failure rather than blocking on a permission prompt — there is no human in the loop to unblock the coder. No interactivity by design — see spec §11.

#### Planner

- Interactive REPL, or stream-json with passthrough to the human.
- `--permission-mode default` or `acceptEdits`.

Judgement role; the human is in the loop. The planner can ask for clarification when a brief is genuinely ambiguous, decompose tasks differently than first planned, or escalate to the architect.

#### Auditor

- Interactive, stream-json with passthrough for the check-in rule (see auditor-guide).
- `--permission-mode acceptEdits` scoped to the auditor repo.

Read-only access to the main repo is enforced by the Docker read-only volume mount (the auditor's main-repo clone is mounted `:ro`), not by permission mode. Permission mode governs the auditor repo where the audit report and supporting tooling live.

---

## 5. Per-role images

A single base image (`agent-base`) carries the shared runtime. Role images extend it.

### 5.1 `infra/base/Dockerfile`

```dockerfile
FROM debian:bookworm-slim

# Base tools every role needs. Note: nodejs/npm are NOT installed here —
# only the coder-daemon image needs them, and adding them to the base
# image bloats the architect, planner, and auditor unnecessarily.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git openssh-client curl ca-certificates gnupg vim \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code via Anthropic's signed APT repository.
# This is the recommended channel on Debian — updates flow through
# `apt upgrade`, the package is signed, no node runtime required.
# The 'stable' channel is intentional; switch to 'latest' for rolling.
RUN install -d -m 0755 /etc/apt/keyrings && \
    curl -fsSL https://downloads.claude.ai/keys/claude-code.asc \
        -o /etc/apt/keyrings/claude-code.asc && \
    echo "deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main" \
        > /etc/apt/sources.list.d/claude-code.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends claude-code && \
    rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash agent
RUN mkdir /work && chown agent:agent /work

USER agent
WORKDIR /work
```

Each role image extends this and adds role-specific tools (the coder image carries the project's build toolchain; the auditor image carries adversarial tools; the architect image stays minimal). The coder-daemon image adds node + the http server deps and the sqlite library; otherwise it inherits everything from the base.

### 5.2 `infra/coder-daemon/Dockerfile`

```dockerfile
FROM agent-base

# The daemon runs a node http server. Coders run as subshells inside the
# daemon's container, so this image also needs the project's build toolchain.

USER root

# Node runtime for the daemon itself.
RUN apt-get update && apt-get install -y --no-install-recommends \
    nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# Daemon dependencies (installed globally so the agent user can require them).
RUN npm install -g better-sqlite3 express uuid

# Project build toolchain (example for a TypeScript project):
# RUN apt-get update && apt-get install -y --no-install-recommends make gcc \
#     && rm -rf /var/lib/apt/lists/*

USER agent
WORKDIR /work
COPY --chown=agent:agent daemon.js /home/agent/daemon.js

CMD ["node", "/home/agent/daemon.js"]
```

The reference `daemon.js` is ~150 lines: an Express server with the four endpoints from §4.2, child_process to spawn claude-code, better-sqlite3 for state, plus the source-IP and token middleware. Lives in the project-template repo, not in this spec doc.

---

## 6. Workflows

### 6.1 First-time project setup

```bash
# Clone the project-template (a separate repo containing infra/, methodology/,
# scripts, docker-compose.yml).
git clone <project-template> myproject
cd myproject

# Generate per-role ssh keys.
./infra/scripts/generate-keys.sh

# Build images.
docker compose build

# Start git-server and architect.
docker compose up -d git-server architect

# Initialize the bare repos.
docker compose exec git-server /srv/init-repos.sh

# Architect is now running with a persistent claude-code session.
# The human attaches to it interactively:
docker compose attach architect
# (or: docker compose exec architect bash; then run `claude-code --resume`)
```

### 6.2 Section commission (planner + coder-daemon pair)

Architect produces a section brief, commits it to `main` at `briefs/s003-feature/section.brief.md`. The human runs:

```bash
./commission-pair.sh s003-feature
```

The script:
- Generates port and token.
- Writes `.pairs/.pair-s003-feature.env` (0600).
- Brings up `coder-daemon` for this section.
- Prints a commissioning summary for the human to paste into the planner.
- Brings up `planner` in the foreground.

The human pastes the commissioning summary into the planner's claude-code instance:

> "Read /work/main/briefs/s003-feature/section.brief.md. The coder daemon is at http://coder-daemon:$port with token $token (already in env). Discharge when done."

The planner decomposes the section, commits task briefs, posts each commission to the daemon, polls for completion, merges PRs, writes the section report, exits. Script tears everything down.

### 6.3 Audit commission

Architect produces an audit brief, commits it to `main` at `briefs/s003-feature/audit.brief.md`. The human runs:

```bash
./audit.sh s003-feature
```

Auditor reads the audit brief, produces the audit report into the auditor repo, exits. The architect (still running in its container) detects the new audit report on its next `git fetch` of the auditor clone, and copies it to `briefs/s003-feature/audit.report.md` on `main`.

### 6.4 Inspecting commission history

While a planner pair is running, the human can inspect the daemon's sqlite db:

```bash
docker compose -p myproject-s003-feature exec coder-daemon \
  sqlite3 /data/commissions.db \
  'SELECT commission_id, status, started_at, exit_code FROM commissions ORDER BY started_at;'
```

Useful for spotting a planner that's churning, a coder that exited fast (likely failed), or a stalled commission.

---

## 7. Cross-platform notes

### 7.1 Linux

Native Docker. Best performance. Bind mounts and named volumes both fast. No special configuration.

### 7.2 macOS

Docker Desktop or Colima. Both run a Linux VM under the hood. File I/O across the host↔VM boundary is meaningfully slower than on Linux:

- **Use named volumes** (as the reference compose does) rather than bind-mounting working trees from `/Users/...`. The reference compose bind-mounts only read-only directories (`./methodology`, `./infra/keys`).
- **Allocate enough VM resources.** Default 2GB is too tight. `colima start --cpu 4 --memory 8` is a sane minimum.
- **Don't bind-mount `node_modules`.** Build artifacts live inside the daemon's container's working volume.

### 7.3 Windows

Docker Desktop with WSL2 backend. Same Linux-VM model as macOS.

- **Named volumes preferred**, same I/O reason.
- **Path translation:** stick to WSL2-native paths (`/home/<user>/...`) for clean behavior.
- **Document scripts in PowerShell or recommend running from WSL2 shell.** The container-side commands are identical because they run inside Linux.

---

## 8. Templating for new projects

The substrate is one project-template repo. Cloning it gives a complete project setup:

```
project-template/
├── docker-compose.yml
├── commission-pair.sh
├── audit.sh
├── infra/
│   ├── base/Dockerfile
│   ├── architect/Dockerfile
│   ├── planner/Dockerfile
│   ├── coder-daemon/Dockerfile
│   ├── coder-daemon/daemon.js
│   ├── auditor/Dockerfile
│   ├── git-server/Dockerfile
│   ├── git-server/init-repos.sh
│   ├── git-server/hooks/update
│   ├── keys/                       (gitignored; populated by generate-keys.sh)
│   └── scripts/
│       ├── generate-keys.sh
│       └── bootstrap.sh
├── methodology/
│   ├── agent-orchestration-spec.md
│   ├── architect-guide.md
│   ├── planner-guide.md
│   └── auditor-guide.md
├── .pairs/                          (gitignored; runtime per-pair env files)
└── README.md
```

A new project: `git clone project-template myproject && cd myproject && ./infra/scripts/bootstrap.sh`. The bootstrap script generates keys, builds images, brings up the long-lived services, and initializes the bare repos. From there the architect drives `TOP-LEVEL-PLAN.md` with the human and the project starts.

For projects with specific build tools, the project-template repo gets forked and the role Dockerfiles get customized — primarily the coder-daemon image (which carries the build toolchain) and the auditor image (which carries adversarial tools). The methodology files are unchanged.

---

## 9. Gotchas

- **UID mismatch.** The `agent` user inside containers is UID 1000 by default. If your host UID differs and you bind-mount, you'll see permission errors. Either rebuild with `--build-arg UID=$(id -u)` or use named volumes only (recommended).
- **Claude Code authentication.** `claude-code` (installed via apt as in §5.1) uses OAuth interactively on first run, storing credentials in `~/.claude/`. Ephemeral containers (planner, coder subshells, auditor) cannot do interactive OAuth — fresh containers have no `~/.claude/`, no browser, and would block on the auth prompt. Two workable options:

  *(a) `ANTHROPIC_API_KEY`.* Set the env var in the ephemeral container; `claude-code` accepts it in lieu of OAuth. Simple but pay-per-token, and bypasses any subscription the architect's user has.

  *(b) Volume-shared OAuth credentials (substrate default).* Two named volumes:

  - `claude-state-architect` — mounted read/write at `/home/agent/.claude` in the architect. Holds the *full* `~/.claude/` directory (session state, history, plugins, anything else `claude-code` writes). Survives container restarts; this is the architect's persistent session.
  - `claude-state-shared` — mounted at `/home/agent/.claude` in every ephemeral role (planner, coder-daemon, auditor). Holds *only* `.credentials.json` — never the architect's history or session state. Populated by a refresh helper that copies `.credentials.json` from the architect volume; ephemeral roles consume it but should never write through it (the substrate enforces this by convention, since the volume is mounted writable so claude-code can update it on token rotation if absolutely necessary, but in practice the refresh helper is the single writer).

  Both volumes are declared `external: true` with fixed names so they survive `compose down -v` of the per-pair ephemeral project — a routine teardown of a planner pair must not wipe the user's auth. Setup creates them via `docker volume create` before `compose up` so compose does not auto-create project-prefixed copies.

  **OAuth refresh cadence.** Anthropic OAuth access tokens rotate on the order of every several hours. When the architect's token rotates, the architect's `.credentials.json` updates in `claude-state-architect`, but `claude-state-shared` still holds the previous token until it is refreshed. Ephemeral roles spawned against a stale shared volume will fail auth in cryptic ways (typically a 401 from the API, surfaced as an opaque claude-code error). The refresh is a one-shot `cp` from the architect volume to the shared volume, run via a `debian:bookworm-slim` helper container with both volumes mounted; see `verify.sh` in the project-template repo for the canonical implementation. Re-running `verify.sh` is the operator's "re-sync after the architect rotated" gesture; it is idempotent and safe to run on every commission.

  Option (a) is simpler if your project has only one user and you do not mind metering costs to the API rather than the subscription; (b) is the substrate default because it lets the architect's user identity propagate cleanly to every ephemeral role. They are mutually compatible — `claude-code` prefers `ANTHROPIC_API_KEY` when set — so a project may default to (b) and let individual operators opt into (a) by setting the env var.
- **Disk usage from named volumes.** `compose down -v` in the pair script removes the daemon's sqlite volume on planner exit. Architect volumes persist by design. Run `docker volume ls` periodically to spot abandoned volumes from killed sessions.
- **Network DNS.** The daemon hostname is `coder-daemon` (the service name) inside the agent network. Don't try to reach the daemon via `localhost` from the planner — they're in different containers, even though they're on the same compose network.
- **sqlite WAL file.** If the daemon crashes mid-write, sqlite leaves `commissions.db-wal` and `-shm` files. better-sqlite3 handles recovery on next open; nothing for the operator to do.
- **Coder subshell hung.** If a coder hangs (claude-code stops responding, no exit), the daemon's `wait()` blocks. The human can `POST /commission/{id}/cancel` from the host (proxying through the daemon's network) or just `docker compose -p ... kill coder-daemon` and tear the pair down.
- **Architect's auditor clone going stale.** The architect needs to `git fetch` the auditor clone after each audit. The architect-guide should remind the architect to do this; alternatively, the audit.sh script can `docker compose exec architect git -C /auditor fetch` after the auditor exits.

---

## 10. What this document does not cover

- **The actual project's source build/test setup.** Goes in the coder-daemon image. Project-specific.
- **CI integration.** Standard CI on PRs to section branches, outside the methodology.
- **Production deployment of the project's product.** Methodology stops at "section merged to main, audit passed."
- **Backups.** The bare repos' named volumes need backing up like any git remote. Operator's choice.
- **Multi-host deployments.** Out of scope; the methodology assumes a single host. A multi-host deployment would replace the compose network with explicit service discovery and is its own design problem.
