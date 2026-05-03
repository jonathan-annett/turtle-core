# turtle-core update brief — auth-flow

## What this is

A follow-up to s005, surfaced during the first end-to-end run on a fresh
substrate (VPS deployment). Path B authentication does not work
end-to-end on a fresh install. Two related bugs surfaced during the run:

1. **The architect's `/home/agent/.claude/` mount is root-owned on
   first start**, so when `claude /login` runs as agent, the credentials
   write silently fails. Login appears to succeed (server-side OAuth
   completes) but no `.credentials.json` lands on disk, and every
   subsequent prompt reverts to "Not logged in." Workaround: a one-shot
   `docker exec -u root agent-architect chown -R agent:agent
   /home/agent/.claude`. Then re-run `/login`.

2. **`claude-state-shared` volume is created at setup time but
   `.credentials.json` is never copied into it.** Per
   `deployment-docker.md` §9, this volume is supposed to ferry
   credentials from the long-lived architect to ephemeral planners,
   coders, and auditors so they don't have to log in individually. The
   shared volume *was* scaffolded (it has `backups/` and `cache/`
   subdirectories with the agent UID), but the `.credentials.json`
   itself was not written. Effect: every ephemeral container needs its
   own interactive `/login` — same chown bug, same OAuth dance, every
   time.

The combination means a fresh substrate's first attempt to commission
a planner is blocked behind two manual interventions, neither of which
is documented in the README's Path B description, neither of which is
surfaced by `verify.sh`. The substrate's intended UX (architect logs
in once; ephemerals inherit) has never actually shipped working.

This brief packages the investigation and fix as one section,
**s006-auth-flow**.

---

## Recommendations baked in (override before dispatch)

Five calls. Each flagged below; edit before dispatch to override.

1. **Two tasks: investigate first, then fix.** The chown bug is
   pinned down (architect volume's mount root is root-owned). The
   credential-sharing gap is partly pinned down (shared volume is
   created but never populated) but the *why* isn't — could be a
   missing refresh-helper invocation in setup-linux.sh, could be a
   wired-up-but-broken helper, could be a planner Dockerfile that
   doesn't mount the shared volume at all. Investigation has to land
   before fix scope is fixable. Splitting also gives the architect a
   review gate between "what we found" and "what we'll do about it."

   Considered alternative: one task that covers both. Rejected
   because the fix shape depends on what investigation reveals.
   **Override:** request a single combined task.

2. **Fix the architect chown via entrypoint, not via post-setup
   helper.** The architect's `entrypoint.sh` is the right place: run
   the entrypoint as root, chown `/home/agent/.claude` if
   not-already-agent-owned, then `exec gosu agent` (or equivalent) for
   the rest of the entrypoint. Idempotent, transparent, no setup
   script involvement.

   Considered alternatives: (a) chown in setup-linux.sh after volume
   create — works but requires the volume to be mounted in a one-shot
   container at setup time, more moving parts; (b) chown in
   verify.sh — wrong layer, verify.sh is a smoke test, not a
   provisioning step.
   **Override:** specify (a) or another mechanism.

3. **Same fix shape applies to the planner, coder, and auditor
   images.** All four agent roles' `entrypoint.sh` files should chown
   `/home/agent/.claude` before dropping privileges. The bug class is
   identical; the fix is identical. Apply uniformly.

   **Override:** request the fix only on the architect (deferring the
   ephemerals until separately confirmed broken).

4. **Credential-sharing fix: setup-linux.sh / setup-mac.sh should
   trigger an explicit `verify.sh --refresh-credentials` step after
   the architect first logs in.** That mode of verify.sh runs a
   one-shot helper container that mounts both `claude-state-architect`
   (read-only) and `claude-state-shared` (read-write) and copies
   `.credentials.json` across with correct ownership and permissions.
   Path B's documented workflow becomes:

   - User runs setup-linux.sh / setup-mac.sh (idempotent, creates
     volumes, builds images, starts long-lived services).
   - User runs `./attach-architect.sh`, runs `claude /login`, exits.
   - User runs `./verify.sh --refresh-credentials` (or simply
     `./verify.sh` if we want to make the refresh implicit when
     verify.sh detects newly-written architect credentials).
   - From then on, ephemerals inherit.

   Considered alternatives: (a) make the architect's entrypoint
   write through to the shared volume on every credential write — too
   invasive, requires patching claude-code or watching the file; (b)
   periodic cron-style sync — overkill, OAuth refresh tokens last days,
   sync-on-demand is fine.

   **Override:** specify (a) or a different mechanism.

5. **Investigation task should also surface the OAuth refresh-token
   story.** Per `deployment-docker.md` §9, OAuth access tokens rotate
   every several hours. The substrate documents that
   `verify.sh --refresh-credentials` re-syncs them. That code path
   was supposed to exist; the investigation should confirm whether it
   does and whether it actually triggers when the architect's
   `.credentials.json` mtime changes. If broken, fix in scope.

   **Override:** defer rotation handling to a future section.

---

## Top-level plan

**Goal.** Make Path B authentication actually work end-to-end on a
fresh substrate, on first try, without manual interventions. Eliminate
the chown bug uniformly across all four agent images. Wire up the
credential-sharing mechanism the substrate's docs already describe.

**Scope.** One section, two tasks: investigation, then implementation.

**Sequencing.** Execute after s005. Standalone, no dependencies on
other in-flight work.

**Branch.** `section/s006-auth-flow` off `main`.

---

## Section s006 — auth-flow

### Section ID and slug

`s006-auth-flow`

### Objective

Make Path B authentication work end-to-end on a fresh substrate
without manual intervention. Specifically: the architect logs in once
via `claude /login`, then `verify.sh` (or an explicit refresh command)
propagates credentials to the shared volume, then ephemeral planners,
coders, and auditors inherit those credentials and start in a
logged-in state. Neither the architect nor any ephemeral should
require a manual chown to make `~/.claude` writable.

### Available context

The bug pattern was identified during the first attempted end-to-end
methodology run on a fresh VPS substrate (Ubuntu 24.04, x86_64,
turtle-core repo at `c80b018`). The architect was started, claude-code
was installed, `claude /login` was attempted. Symptoms:

- `/login` reported "Login successful."
- The next user prompt reported "Not logged in. Please run /login."
- Inspection of `/home/agent/.claude/` revealed the directory was
  root-owned mode 0755 with the agent user (uid 1000) unable to write.
- After `docker exec -u root agent-architect chown -R agent:agent
  /home/agent/.claude`, `/login` was retried and succeeded:
  `.credentials.json` now exists, mode 0600, owned by agent.
- A planner was then commissioned via `commission-pair.sh s001-cli`.
  The planner container had the same chown bug. After fix, login was
  required again — confirming the shared-volume mechanism didn't
  carry the architect's credentials over.
- Inspection of `claude-state-shared` (via a one-shot alpine
  container) showed `backups/` and `cache/` subdirectories owned by
  uid 1000 but no `.credentials.json`. Something scaffolded the
  shared volume's directory structure but never copied the
  credentials file.

Read these before beginning:
- `methodology/deployment-docker.md` §9 — the OAuth refresh and
  dual-volume design as currently documented.
- `infra/architect/entrypoint.sh` — the long-lived architect's
  entrypoint, where the chown fix should land.
- `infra/planner/entrypoint.sh`, `infra/coder/entrypoint.sh`,
  `infra/auditor/entrypoint.sh` — the ephemeral entrypoints with the
  same fix.
- `verify.sh` — to find the refresh-helper code if it exists, and to
  add the `--refresh-credentials` mode if not.
- `setup-linux.sh` and `setup-mac.sh` — to wire the refresh into the
  setup story.
- `docker-compose.yml` — to confirm the shared volume's mount points
  in each ephemeral image.
- `briefs/s000-setup/section.report.md` — the original SETUP-BRIEF
  report. May contain context on what the original substrate-builder
  agent intended for Path B.

### Tasks (informal decomposition)

**6.a — Investigation. Read-only; no code changes.**

Task ID: `t006.001-investigate`. Goal: pin down the gap between Path
B as documented and Path B as implemented. Deliverable: a short
investigation report committed to the section branch at
`briefs/s006-auth-flow/investigation.md`, covering:

1. What the architect's `entrypoint.sh` does. Specifically, whether
   it runs as root or agent at start, whether it ever chowns
   `/home/agent/.claude`, and what happens to ownership when the
   `claude-state-architect` volume is freshly created vs. reused.
2. Same for the three ephemeral images' entrypoints (planner, coder,
   auditor). Are they the same entrypoint? Different? Does each
   chown? Does any?
3. The `claude-state-shared` volume: where does its current content
   come from? What scaffolds the `backups/` and `cache/`
   subdirectories with uid 1000? Trace the create-and-populate path.
4. Whether `verify.sh` has any code path that copies
   `.credentials.json` from `claude-state-architect` to
   `claude-state-shared`. If yes, what triggers it? If no, where
   would such code most cleanly live?
5. Whether the planner / coder / auditor images mount
   `claude-state-shared` in their `docker-compose.yml` definitions,
   and at what path inside the container. (The intended path is
   `/home/agent/.claude` mounted read-only — but is it actually
   wired?)
6. Whether `deployment-docker.md` §9's description of the dual-volume
   pattern matches what's actually implemented. Note any divergences.

The investigation report should answer: "what is the minimum set of
changes that makes Path B work as documented?" The fix task uses that
answer as its scope.

**6.b — Implementation. Drives the fix scope from 6.a's findings.**

Task ID: `t006.002-fix`. Three or four sub-deliverables expected, the
exact shape determined by 6.a:

- **Chown fix in all four entrypoints.** Architect, planner, coder,
  auditor. The architect runs as root briefly, chowns the mount, then
  drops to agent. Same for ephemerals. The fix must be idempotent
  (running it on an already-agent-owned directory is a no-op) and
  must not change anything about already-populated mounts.

- **Credential-sharing mechanism.** Either a new `verify.sh
  --refresh-credentials` mode that runs the alpine-style copy from
  architect-volume to shared-volume, or — if the investigation finds
  this code was supposed to exist but is broken — fix it. Either way,
  setup-linux.sh / setup-mac.sh should trigger this after the
  architect first writes credentials. The "after the architect first
  writes credentials" trigger probably means "the user runs
  `./verify.sh` after `claude /login`," but the investigation may
  surface a better hook.

- **Shared-volume mount in ephemeral compose entries.** If the
  investigation reveals that the planner / coder / auditor don't
  actually mount `claude-state-shared` at `/home/agent/.claude`,
  add the mount declarations.

- **Documentation.** Update `deployment-docker.md` §9 to match what's
  actually implemented after the fix, and update README's Path B
  section to walk the user through it accurately.

### Constraints

- The chown fix must be uniform across all four agent images. Don't
  fix only the architect.
- The credential-sharing mechanism should not require the user to
  manually run `docker run` commands. The substrate's setup scripts
  and verify.sh should encapsulate it.
- The fix must not regress Path A (host-side credentials ferried in
  via setup script). If the user has `~/.claude/.credentials.json`
  on the host, the existing Path A behavior should still work.
- No changes to the methodology spec. This is a substrate fix, not
  a methodology change.
- The OAuth refresh-token rotation case (per `deployment-docker.md`
  §9) must continue to work after the fix. If it was working before
  the fix lands (unlikely given Path B never worked), preserve the
  behavior. If it wasn't, fix it as part of the credential-sharing
  work.

### Definition of done

- Investigation report at `briefs/s006-auth-flow/investigation.md`
  committed to the section branch, answering questions 1–6 from task
  6.a.
- All four agent images' entrypoints chown `/home/agent/.claude` to
  agent ownership idempotently before dropping privileges.
- The architect, after a fresh setup and `claude /login`, has
  credentials persisted in `claude-state-architect` (already true,
  but should remain true).
- After the architect's first login plus a documented refresh
  command, `claude-state-shared` contains the `.credentials.json`
  file owned by agent, mode 0600.
- A freshly commissioned planner sees the architect's credentials
  via the read-only shared-volume mount and starts in a logged-in
  state. Same for coder and auditor.
- `verify.sh` reports auth state correctly: it should not say
  "credentials not yet present" when they actually are.
- `deployment-docker.md` §9 and README accurately describe the
  flow.
- The full sequence — `setup-linux.sh`, `attach-architect.sh`, log
  in once, `commission-pair.sh <slug>` — works without manual
  chown or per-container login.
- Section report at `briefs/s006-auth-flow/section.report.md`
  including: brief echo, summary of investigation findings, summary
  of fix, which entrypoints were modified, manual test transcript
  showing the end-to-end Path B flow working, residual hazards.

### Out of scope

- Changes to claude-code itself.
- Path A changes (host-side credential ferrying).
- A "refresh creds via web hook" or similar dynamic mechanism.
  Refresh on demand via verify.sh is sufficient.
- Multi-architect support (single architect per substrate is the
  documented model; this is not the section to change that).
- Anything to do with the methodology spec itself.

### Repo coordinates

- Base branch: `main`.
- Section branch: `section/s006-auth-flow`.
- Task branches: `task/006.001-investigate` and `task/006.002-fix`
  off the section branch.

### Reporting requirements

Section report at `briefs/s006-auth-flow/section.report.md` on the
section branch. Must include:

- Brief echo.
- Summary of investigation findings (or pointer to
  `investigation.md`).
- Summary of fix.
- Which entrypoints were modified, with diff context.
- Manual test transcript: a clean run of setup → login → refresh →
  commission planner, showing everything works without manual
  chown.
- Confirmation that verify.sh's auth-state reporting is now
  accurate.
- Any residual hazards or edge cases (e.g. what happens if the
  architect's credentials expire while a planner is mid-run).

---

## Execution

Single agent on the host (same pattern as s001–s005). Investigate
first, surface findings to the architect (you), get scope
acknowledged, then fix. The agent may pause between 6.a and 6.b for
human review of the investigation report — this is a feature, not a
delay; the fix scope depends on what's found.

If the investigation reveals the gap is larger than this brief
anticipates (e.g. claude-code's credential location has changed in a
recent version, or the dual-volume pattern was never fully designed),
the agent should surface that in `investigation.md` and pause for
architect review rather than expand scope unilaterally.
