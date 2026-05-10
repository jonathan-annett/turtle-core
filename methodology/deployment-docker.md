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

The daemon enforces two checks on every incoming request, in order:

1. **Network**: daemon binds to its compose-network interface (not `0.0.0.0`, not host-routable). The compose-project namespace isolates each planner/daemon pair from every other pair on the host; no other container — in any project — can route to this daemon's bound address.
2. **Token**: every request must carry `Authorization: Bearer <token>` matching `COMMISSION_TOKEN`. Failure returns 401 immediately, before any logic runs.

The first check is the boundary that does the work; the second is belt and braces.

A third source-IP guard (resolving the planner's container IP via `getent hosts planner` and rejecting requests from any other source) lived here through s006 and was removed in s007. It was intended as defense in depth but was brittle in practice: the planner service has no `container_name` and no network alias on `agent-net` (deliberate, to keep multi-pair parallelism open), so reverse-DNS on the source IP returned the container ID rather than `planner`, the check closed-failed, and every commission was 503'd. Compose-project network isolation plus the bearer token are the real boundaries; the IP guard added no defensive value commensurate with its breakage rate.

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

### 3.5 Substrate identity

A substrate is a single coupled set of artefacts: a working tree on the host (with per-role SSH keys under `infra/keys/<role>/`) and a set of Docker volumes (auth state, bare repos, container working volumes). The pair is meaningful only when the tree and the Docker state belong to the same substrate. This is normally true by construction — but a host may legitimately host more than one tree (a substrate-development clone alongside a real substrate; two unrelated projects), and Docker state is global per host. A setup invocation that runs against the wrong combination of tree and Docker state can silently mutate one side away from the other (e.g. by regenerating per-role keys when host directories happen to be empty) without producing an obvious failure.

To make the tree↔Docker pairing checkable, every substrate carries an explicit identity:

- **`.substrate-id`** — a file at the repo root containing a single line: a UUID v4. Mode `0644`. Generated at first-time setup. Gitignored (per-clone, never committed). Removing this file is operator-visible because it disables every subsequent setup invocation until either a new install, an adoption, or a deliberate reset takes place.

- **`app.turtle-core.substrate-id=<uuid>`** — a label on the `claude-state-architect` Docker volume, set at volume-create time (Docker local volumes do not support label updates after creation; `docker volume update` exists only for cluster volumes). The architect volume is the natural carrier because it is the substrate's most stable, owned-once artefact.

Setup checks both before doing any state mutation. The five outcomes of the on-disk × in-Docker matrix are:

| `.substrate-id` on disk | architect volume | architect-volume label | Setup behavior |
|---|---|---|---|
| absent | absent | n/a | Fresh install: generate UUID, write sentinel, create labelled volume. |
| absent | present | absent or any | Fail loudly: this tree does not know about the live Docker state. Suggest `--adopt-existing-substrate` or `docker compose down -v` for a clean slate. |
| present | absent | n/a | Fail loudly: tree claims a substrate that has no live Docker state. Suggest `--adopt-existing-substrate` (if intentional) or `rm .substrate-id` (for fresh install). |
| present | present | mismatched | Fail loudly: tree and Docker state belong to different substrates. Surface both UUIDs; suggest `docker compose down -v` (wrong tree present) or restoring the right tree. |
| present | present | matching | Proceed: ordinary re-setup. |

The check is the first state-mutation gate in setup. Anything that runs before it (platform detection, prereq verification, the `~/.docker` ownership preflight from s002) is read-only; everything after it (key generation, volume create, image build, `compose up`) is gated by it.

`infra/scripts/generate-keys.sh` is no longer a standalone-safe entry point — it inherits the same gate via an environment-variable contract with the setup scripts. Invoking it directly bails out with a message redirecting the user to `setup-linux.sh` / `setup-mac.sh`, which run the proper diagnosis.

The migration command `--adopt-existing-substrate` (on both setup-linux.sh and setup-mac.sh) covers the one-shot transition for substrates that predate the sentinel: it generates a UUID, writes the sentinel, and recreates `claude-state-architect` with the label while preserving its contents (the architect is briefly stopped, the volume is rotated through a helper container, and the architect is restarted). The flag refuses to run if `.substrate-id` already exists.

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

The reference `daemon.js` is ~150 lines: an Express server with the four endpoints from §4.2, child_process to spawn claude-code, better-sqlite3 for state, plus the bearer-token middleware (the s006-era source-IP middleware was removed in s007 — see §3.3). Lives in the project-template repo, not in this spec doc.

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

The script (commissioning mode — slug supplied):
- Verifies the section brief exists at `briefs/s003-feature/section.brief.md` on main, by querying the architect's `/work` clone via `docker exec agent-architect test -f`. Fails fast with a recovery hint if missing (committed but not pushed; on main but architect clone stale).
- Generates port and token.
- Writes `.pairs/.pair-s003-feature.env` (0600).
- Brings up `coder-daemon` for this section.
- Builds a deterministic bootstrap prompt and passes it to the planner container via the `BOOTSTRAP_PROMPT` env var.
- Brings up `planner` in the foreground.

The planner's entrypoint detects `BOOTSTRAP_PROMPT` and invokes
`claude -p "$BOOTSTRAP_PROMPT"` non-interactively before dropping to
a shell. The canonical prompt for s003-feature is:

> Read /work/briefs/s003-feature/section.brief.md and execute the section per the methodology in /methodology/planner-guide.md (which is symlinked as /work/CLAUDE.md). The coder daemon is at http://coder-daemon:$port. Your bearer token is in $COMMISSION_TOKEN. Discharge when the section is done.

The planner decomposes the section, commits task briefs, posts each commission to the daemon, polls for completion, merges PRs, writes the section report, discharges. The container drops to a shell so the human can inspect post-discharge state; on shell exit the script tears everything down.

**Manual mode (no slug).** Running `./commission-pair.sh` without an argument skips the brief check and any bootstrap prompt; the planner drops straight to a shell so you can run `claude` interactively, debug, or inspect the container. Useful during substrate iteration.

### 6.3 Audit commission

Architect produces an audit brief, commits it to `main` at `briefs/s003-feature/audit.brief.md`. The human runs:

```bash
./audit.sh s003-feature
```

The script (commissioning mode — slug supplied):
- Verifies the audit brief exists at `briefs/s003-feature/audit.brief.md` on main, by the same `docker exec agent-architect test -f` mechanism used by `commission-pair.sh`.
- Builds a deterministic bootstrap prompt and passes it to the auditor container via `BOOTSTRAP_PROMPT`.
- Brings up `auditor` in the foreground.

The canonical prompt for s003-feature is:

> Read /work/briefs/s003-feature/audit.brief.md and execute the audit per /methodology/auditor-guide.md (symlinked as /work/CLAUDE.md). Your private workspace is /auditor (writable). The main repo at /work is read-only. Write the audit report to the auditor repo at the path named in the brief, commit and push, then discharge.

Auditor reads the audit brief, produces the audit report into the auditor repo, discharges. The architect (still running in its container) detects the new audit report on its next `git fetch` of the auditor clone, and copies it to `briefs/s003-feature/audit.report.md` on `main`.

**Manual mode (no slug).** Running `./audit.sh` without an argument skips the brief check and any bootstrap prompt; the auditor drops straight to a shell.

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

  - `claude-state-architect` — mounted read/write at `/home/agent/.claude` in the architect. Holds the *full* `~/.claude/` directory (session state, history, plugins, anything else `claude-code` writes). Survives container restarts; this is the architect's persistent session. **Implementation note:** the agent-base image must pre-create `/home/agent/.claude` as `agent:agent` mode `0700`. Docker initialises an empty named volume's mount root by copying the image-layer's ownership at the same path; without the pre-create, the mount root is `root:root 0755` and `claude-code` (running as `agent`) silently fails to write `.credentials.json` on first `claude auth login` (Path B). The same pre-create covers ephemerals' write-through path on token rotation.
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

## 10. Platforms

The substrate's role images are language-and-toolchain neutral by
default. To target a specific build/test stack — Go, Rust, C/C++,
Python tooling, Node-extras, embedded firmware — the human selects
one or more **platforms** at substrate setup time. The selected
platforms compose with the static role templates to produce
`Dockerfile.generated` for `coder-daemon` and `auditor`; the resulting
images carry the platform's apt packages, language installers, env
vars, and verify commands.

The platform plugin model also covers **runtime device passthrough**.
Embedded targets (the canonical case is ESP32 via PlatformIO) test
their firmware by flashing it to a board over USB and reading test
results back over UART; without serial access, the auditor can only
do static analysis and the coder can't TDD the way embedded coders
actually work. Platforms can declare device requirements
(`runtime.device_required`, `runtime.device_hint`,
`runtime.groups`); the operator wires devices in via `--device`.

The full schema reference (build-time toolchain block + runtime
device block + architect/planner defaults) and the per-platform
catalog live in **`methodology/platforms/README.md`**. This section
covers the substrate-level mechanics and operator workflow.

### 10.1 Selecting a platform at setup

```bash
# Linux:
./setup-linux.sh --platform=go
./setup-linux.sh --platform=go,python-extras
./setup-linux.sh --platform=platformio-esp32 --device=/dev/ttyUSB0

# macOS:
./setup-mac.sh --platform=rust
```

Repeated `--platform` flags concatenate
(`--platform=go --platform=python-extras` is equivalent to
`--platform=go,python-extras`). Empty / absent → `default` (no
toolchain layers added; substrate behaves as it did before s009).

`--device=<host-path>` may be repeated similarly; each path must
exist on the host at parse time. Platforms that declare
`runtime.device_required: true` (currently `platformio-esp32`) emit
a setup-time warning if no `--device` is supplied — this is a
warning, not a failure, because a "compile-only" workflow is
legitimate (operator may add the bridge later).

### 10.2 The ship-with platform catalog

| Platform              | Use case                                  | Approx size add |
| --------------------- | ----------------------------------------- | --------------- |
| `default`             | Baseline; current behaviour               | 0               |
| `go`                  | Go projects                               | ~150MB          |
| `rust`                | Rust projects                             | ~400MB          |
| `python-extras`       | Python with uv / poetry / pytest          | ~100MB          |
| `node-extras`         | Node with pnpm / yarn / typescript        | ~50MB           |
| `c-cpp`               | C / C++ with cmake / valgrind / gdb       | ~300MB          |
| `platformio-esp32`    | Embedded ESP32 via PlatformIO; HIL serial | ~500MB          |

New platforms are added by writing
`methodology/platforms/<name>.yaml` per the schema in that
directory's README. The validator
(`infra/scripts/lib/validate-platform.sh`) runs at every setup
invocation and aborts setup on schema failure with a clear
diagnostic identifying the file and the failing field.

### 10.3 The setup pipeline

When `--platform` (or `--add-platform`) is present, setup-common.sh
extends the canonical setup with these additional steps:

1. **Validate** each named platform YAML.
2. **Render** `infra/coder-daemon/Dockerfile.generated` and
   `infra/auditor/Dockerfile.generated` from the static template plus
   the selected platform layers (apt → install → env → verify).
   Generated files are gitignored.
3. **Render device override.** If `--device` was supplied,
   `docker-compose.override.yml` is written at the repo root with a
   `devices:` block on coder-daemon and auditor. Compose autoloads
   this file, so every existing call site
   (`commission-pair.sh`, `audit.sh`, `verify.sh`, the substrate
   end-to-end test) gets device wiring transparently — no code
   change in those scripts.
4. **Build** `agent-base`, then run `docker compose --profile
   ephemeral build` against the generated Dockerfiles.
5. **Setup-time verify.** For each non-default platform, each role
   image runs the platform's `verify` command list inside a one-shot
   container (`docker run --rm --entrypoint bash <image> -c <cmd>`).
   Failure aborts setup with a per-platform/role/command diagnostic.
6. **Write substrate state.** `.substrate-state/platforms.txt` and
   `.substrate-state/devices.txt` are populated at the repo root.
   The architect compose service mounts the directory read-only at
   `/substrate`. `SUBSTRATE_PLATFORMS` and `SUBSTRATE_DEVICES` are
   also exported to the architect's container env.
7. **Re-emit the device-required warning** at the very end of setup
   so it's the last thing the human sees (easy to miss in
   scrollback otherwise).

The architect-guide directs the architect to read
`/substrate/platforms.txt` and `/substrate/devices.txt` when
initializing or updating `SHARED-STATE.md`, recording each platform
under "Target platform(s)" and each device under
"Hardware-in-the-loop devices". This is the substrate's contract
with the project methodology: the architect captures the chosen
platform configuration as a project-wide decision so future agents
(planner, coder, auditor) and future architect sessions inherit it.

### 10.4 Extending a running substrate: `--add-platform`, `--add-device`

```bash
./setup-linux.sh --add-platform=rust
./setup-linux.sh --add-device=/dev/ttyUSB0
./setup-linux.sh --add-platform=platformio-esp32 --add-device=/dev/ttyUSB0
```

`--add-platform=<name>` re-renders `Dockerfile.generated` with
`<existing>,<new>`, rebuilds coder-daemon + auditor (architect /
git-server are unaffected), runs setup-time verify for the new
platform only, and updates `.substrate-state/platforms.txt`. By
default it **refuses** if either:

- An ephemeral container is running (planner / coder-daemon /
  auditor) — silently changing the toolchain underneath an in-flight
  pair would invalidate its assumptions.
- A `section/*` branch on origin has commits ahead of main —
  conservative heuristic: if any section has unmerged work, it might
  depend on the current toolchain.

Pass `--force` to skip both pre-flights. The operator owns the
consequences. The brief intentionally chose the more conservative
of the two readings ("just check running containers" vs. "also
check pending sections") — see the s009 brief design call 4.

`--add-device=<host-path>` updates
`.substrate-state/devices.txt`, re-renders
`docker-compose.override.yml`, and skips the image rebuild (devices
are runtime, not build-time). It refuses only on running containers
(adding a device cannot invalidate an in-progress section's
assumptions).

`--add-platform` and `--add-device` may be combined in one
invocation; `--add-platform` runs first (rebuild), `--add-device`
second (no rebuild). Combining either with the initial-setup
`--platform` / `--device` flags is rejected with a clear message —
the two modes are conceptually distinct.

### 10.5 Hardware-in-the-loop testing

For embedded targets, the dominant test pattern is:

1. Compile test firmware on the host (via the platform's toolchain
   inside coder-daemon / auditor).
2. Flash the firmware to the device over USB.
3. The device runs the test code and reports pass/fail back over
   UART.
4. The host (test runner inside the role container) reads the serial
   output and decides pass/fail.

PlatformIO's `pio test` defaults to exactly this. esptool flashes
ESP32 over the device's USB-to-serial bridge (`/dev/ttyUSB0` or
`/dev/ttyACM0` on Linux). To make this work end-to-end, the role
container needs:

- The PlatformIO toolchain installed (handled by the
  `platformio-esp32` platform's image layers).
- Read/write access to the host serial device (handled by passing
  `--device=/dev/ttyUSB0` at setup, which renders a `devices:` entry
  in `docker-compose.override.yml`).
- The agent user in the `dialout` group (handled by
  `runtime.groups: [dialout]` in the platform YAML, which the
  renderer translates into a `usermod -a -G dialout agent` line at
  image build time).

`pio test -e native` (host-side native tests, no flash) still works
for pure-logic code regardless of device wiring, but timing,
peripheral interaction, and actual device behaviour can only be
validated with HIL.

### 10.6 Forward reference: remote serial bridge

The substrate runs Docker on a single host. Most VPS-style hosts
don't have an ESP32 plugged into them. The **planned next section
after s009** is a remote serial bridge: a small daemon running on a
Raspberry Pi (or Chromebook, or any host with the device physically
connected) that tunnels its serial port to the VPS where Docker
runs, presenting a virtual `/dev/tty*` on the Docker host that
behaves like a local USB serial device.

s009's `--device=<host-path>` mechanism is built in anticipation of
consuming this virtual path transparently. From the substrate's
point of view, what's behind a host device path — real USB, virtual
PTY pointing at a tunnelled remote port — is opaque. The platform
contract is "supply a host device path"; the bridge tooling is the
only thing that needs to know it's a tunnel. So the platform model
shipped in s009 is forward-compatible with the bridge without
schema changes.

---

## 11. What this document does not cover

- **The actual project's source build/test setup.** Goes in the coder-daemon image. Project-specific.
- **CI integration.** Standard CI on PRs to section branches, outside the methodology.
- **Production deployment of the project's product.** Methodology stops at "section merged to main, audit passed."
- **Backups.** The bare repos' named volumes need backing up like any git remote. Operator's choice.
- **Multi-host deployments.** Out of scope; the methodology assumes a single host. A multi-host deployment would replace the compose network with explicit service discovery and is its own design problem.
