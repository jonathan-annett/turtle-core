# s000-setup — section brief (retroactively reconstructed)

> **Reconstruction note.** This brief is a retroactive reconstruction.
> The original commission was not performed under the methodology — a
> one-off prompt named `setup-scripts-brief.md` drove a single fresh
> claude-code agent to build the initial substrate template. The
> original prompt text is not preserved in the repository. This brief
> is reverse-engineered from the report at `section.report.md` (which
> directly quotes brief sections by number — §1, §3, §4.1, §4.3, §4.5,
> §4.6, §4.10, §6, §7, §9 — and recapitulates the deliverable) plus
> the committed substrate as it actually exists on `main`.
> Reconstruction is intentionally conservative: where the report does
> not pin down an original wording, this brief states what the
> substrate as committed *demonstrably implements*, not what the
> original brief might have asked for. Items the report flags as
> deliberate deviations are noted as such rather than retconned into
> the brief.

## Section ID and slug

`s000-setup`

## Objective

Build a self-contained, reusable project-template repository that
implements the methodology's deployment variant A (Docker; spec §3.4
and `methodology/deployment-docker.md`). After cloning the template
and running a single setup script, the operator must have:

- A long-lived `architect` container with a persistent claude-code
  session.
- A long-lived `git-server` container hosting `main.git` and
  `auditor.git` as bare repos, with per-role SSH key auth and an
  `update` hook that enforces the spec §3.3 access table.
- Scripts to spawn ephemeral planner+coder-daemon pairs per section
  (`commission-pair.sh`) and ephemeral auditors per audit (`audit.sh`).
- A verification script (`verify.sh`) that smoke-tests the substrate
  and doubles as the OAuth-creds refresh helper for ephemeral roles.
- README, methodology copies, and `.env.example` covering all four
  user platforms (Linux, macOS, Crostini, Windows-via-WSL2).

## Available context

- `methodology/agent-orchestration-spec.md` (v2.1) — the contract this
  substrate must satisfy. §3.3 (per-role access table), §3.4 (Docker
  variant), §6 (branch strategy), §7 (artifacts) are the load-bearing
  sections.
- `methodology/deployment-docker.md` — the operational companion. The
  five-container model (§1), reference compose skeleton (§2), network
  and per-pair credentials model (§3), commission daemon API (§4),
  per-role image hierarchy (§5), and templating (§8) are the design
  the substrate must instantiate.
- `methodology/architect-guide.md`, `planner-guide.md`,
  `auditor-guide.md` — role guides that the architect, planner, and
  auditor containers must mount read-only at `/methodology` so each
  ephemeral instance can read its own role guide.

## Constraints

- **Faithful translation.** Implement what the spec and deployment-doc
  say. Where they differ, the spec wins (this is the standing rule
  documented at the top of deployment-docker.md). Empirically verify
  any flag/value that looks like a typo before "correcting" it.
- **No host port exposures.** All inter-container communication goes
  over the `agent-net` bridge network. The compose network must be
  unreachable from outside the host.
- **Auth never crosses the host shell as a variable.** `~/.claude/`
  credentials must be copied file-to-file via a one-shot helper
  container, not read into a host-side env var or shell variable, so
  the credentials file content can never leak into a committed file
  or build output.
- **Idempotent setup.** Re-running setup-linux.sh / setup-mac.sh on a
  host that has already been set up must be a no-op (or update-only),
  not a destructive re-init.
- **No project source code.** The substrate is empty of project
  content. The first project (a proof-of-concept "hello timestamps"
  CLI) is built later via the methodology, not here.
- **Per-role write boundaries are git-server-enforced.** The git-server
  `update` hook must reject:
  - architect pushes outside `briefs/**`, `SHARED-STATE.md`,
    `TOP-LEVEL-PLAN.md`, `README.md`, and `MIGRATION-*.md` on `main`.
  - planner pushes outside `section/*` and `task/*` branches.
  - auditor pushes to anything in main.git (read-only access only).
  - any push to `main.git` that does not come from the human role.
  These are the §3.3 access table; violation is a critical bug.

## Definition of done

The full deliverable, reconstructed from the report's §1 file list and
verified against the committed tree:

```
project-template/
├── README.md                ← covers Linux, macOS, Crostini, WSL2
├── docker-compose.yml       ← shared external network + named volumes
├── setup-linux.sh           ← Linux + Crostini entry point
├── setup-mac.sh             ← macOS entry point
├── setup-common.sh          ← cross-platform body
├── verify.sh                ← smoke test + creds-refresh helper
├── commission-pair.sh       ← per-section planner+coder-daemon launcher
├── audit.sh                 ← per-audit auditor launcher
├── attach-architect.sh      ← convenience wrapper
├── infra/
│   ├── base/Dockerfile      ← debian + claude-code via Anthropic apt repo
│   ├── architect/           ← Dockerfile + entrypoint
│   ├── planner/             ← Dockerfile + entrypoint
│   ├── coder-daemon/        ← Dockerfile + daemon.js + package.json + entrypoint
│   ├── auditor/             ← Dockerfile + entrypoint
│   ├── git-server/          ← Dockerfile + entrypoint + init-repos.sh +
│   │                          git-shell-wrapper + hooks/update
│   ├── keys/<role>/.gitkeep ← gitignored runtime key directories
│   └── scripts/generate-keys.sh
├── methodology/             ← verbatim copies of spec + role guides
├── briefs/.gitkeep          ← runtime
├── .pairs/.gitkeep          ← runtime
├── .gitignore
├── .env.example             ← documents optional ANTHROPIC_API_KEY
└── (this report)            ← discharge report at the repo root
```

Verification is the spec §7-equivalent flow:

```
git clone <project-template> /tmp/testproject
cd /tmp/testproject
./setup-linux.sh           # or setup-mac.sh on Darwin
./verify.sh                # must pass cleanly
```

§3.3 access-table enforcement must be tested directly by attempting
each in-table and out-of-table push from each role's key, and
verifying the git-server's `update` hook accepts and rejects exactly
the expected operations.

## Out of scope

- **Native Windows entry point.** The README documents WSL2 as the
  Windows path; no PowerShell script.
- **Linux distros beyond Debian / Ubuntu / Crostini.** Other distros
  are mentioned only with a pointer to docker.com.
- **Project source.** The substrate is empty; project content arrives
  later via the methodology.
- **CI / production deployment.** Methodology stops at "section merged
  to main, audit passed."
- **Multi-host deployment.** Single-host compose only.
- **OAuth-token management beyond what verify.sh provides.** Token
  rotation is documented; long-running monitor processes are not part
  of this section.

## Repo coordinates

This was a one-off commission, so it pre-dates the methodology's
section-branch convention. The reconstruction places the artifacts
under `briefs/s000-setup/` to retroactively align with spec §6, but
the work itself was committed directly to `main` in three commits:

1. `initial template` — the whole tree.
2. `generate-keys: preserve invoking-user ownership when run via sudo`
   — a small robustness fix discovered during testing.
3. `integration fixes from end-to-end test` — substantive fixes
   (git-user lock, login-shell wrapper, /auditor permissions, volume
   external+fixed-name handling).

## Reporting requirements

A discharge report at `section.report.md` (sibling to this brief) must
record:

- What was built (deliverable layout).
- What was tested (the verify-flow output and the §3.3 access-table
  enforcement matrix).
- Bugs found during testing and their fixes.
- Assumptions and platforms not exercised.
- Deviations from the brief (any deliberate departures and the
  reasoning).
- Open questions for the human.
- Done-criteria checklist confirming each item in this brief's
  Definition of done.

## Reconstruction caveats

The report explicitly cites the original brief's:

- §1 (file list / deliverable layout) — recapitulated above as the
  Definition-of-done tree, drawn from the report's §1.
- §3 (verification flow) — recapitulated as the verify section above.
- §4.1 ("setup-linux.sh and setup-mac.sh are the two entry points") —
  reflected in the deliverable list.
- §4.3 (subshell mechanics), §4.5 (concurrency lock) — these section
  numbers also appear in `infra/coder-daemon/daemon.js`'s comments and
  refer to the deployment-docker.md companion, not to the original
  brief itself; they are pointers, not original brief content.
- §4.6 (architect-writable path list) — the report quotes the list
  verbatim; reflected above in Constraints.
- §4.10 (two-volume OAuth split) — reflected in Available context
  (deployment-docker.md companion now also documents this; see s003
  task 3.a).
- §6 ("faithful translation rule") — reflected above in Constraints.
- §9 (done criteria) — reflected above in Definition of done.

What this reconstruction does **not** invent: any wording for sections
the report does not cite (e.g. the original brief almost certainly
had a §2 introduction and a §5 testing-strategy block of its own; the
report does not quote them, so no content is asserted here). Anyone
needing the original prompt text should consult the human's local
chat history; this brief is a methodology-shaped substitute, not a
recovered original.
