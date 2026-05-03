# turtle-core update brief — s007 substrate end-to-end

## What this is

A follow-up to s006. The first end-to-end methodology run on the VPS
(architect commissions planner via `commission-pair.sh`, planner
commissions coder via daemon, coder produces task report, planner
merges PR) surfaced three substrate gaps that s006's "Path B works"
test didn't catch. s006 verified credentials propagate; it didn't
verify a planner can actually start claude-code, reach the daemon,
and run a coder. This section closes those gaps.

The headline finding: **the substrate works for the architect because
it's been hand-debugged into shape, and breaks for ephemeral roles
because they've never been exercised end-to-end before.** Each fresh
role surfaced gaps the architect path covered up.

This brief packages the fixes as one section, **s007-substrate-end-to-end**.

---

## Recommendations baked in (override before dispatch)

Four design calls. Each flagged below; edit before dispatch to override.

1. **Symlink approach, not bind-home, for `.claude.json`.** Carry it
   inside the existing `claude-state-architect` / `claude-state-shared`
   volumes (which mount at `/home/agent/.claude/`) at the path
   `.claude/.claude.json`, with each role's entrypoint creating a
   symlink `~/.claude.json → ~/.claude/.claude.json` at startup. Smaller
   surgery than rebinding the volume to `/home/agent/`; uses existing
   plumbing.

   Considered alternative: rebind volumes to `/home/agent/` so the
   whole agent home is persistent. Cleaner architecturally and
   future-proof for any new dotfile claude-code adopts, but requires
   moving `.bashrc`, `.profile`, `.ssh` into the volume model and
   bigger entrypoint logic. Punt to s008+ if claude-code adds more
   dotfiles.
   **Override:** specify rebind-home if you'd prefer the bigger surgery.

2. **Drop the daemon's source-IP guard entirely.** Bearer token plus
   per-pair compose-project isolation are the real boundaries.
   Source-IP-as-defence-in-depth is brittle: it failed in this run
   because compose doesn't register the planner's container by a
   stable hostname, and the daemon's reverse-DNS check closed-failed
   on a container ID. Belt-and-braces value isn't worth the breakage.

   Considered alternatives: (a) add a `planner` network alias to
   compose — works for single-pair, breaks for multi-pair (alias
   becomes ambiguous on shared `agent-net`); (b) pass the planner's
   container ID at startup and check IP-matches-container-ID — more
   complex, same defensive value. Token alone is simpler and correct.
   **Override:** specify keep-with-network-alias if you want to retain
   the IP guard at the cost of single-pair-only operation.

3. **CLAUDE.md role-anchor symlinks at container/commission time.**
   Each role's entrypoint creates `CLAUDE.md → /methodology/<role>-guide.md`
   in the working tree before exec'ing claude-code. Coders get an
   inline `CLAUDE.md` written by the daemon at task commission (since
   coders have no canonical guide). This was proven manually in this
   session: renaming the architect's symlinked `architect-guide.md`
   to `CLAUDE.md` made claude-code load the role anchor automatically,
   no human seed prompt needed.

   Considered alternative: copy guide contents into CLAUDE.md instead
   of symlinking. Symlinks have zero drift risk — the canonical
   methodology files in `/methodology/` are always the source of truth.
   **Override:** specify copy-not-symlink if you want CLAUDE.md to
   travel with section snapshots.

4. **One section, executed serially after s006.** The work is tightly
   coupled — substrate-state model, role identity, daemon access — and
   shares the same entrypoint and verify.sh code paths. Splitting
   would introduce more coordination cost than it saves. Architect's
   call whether to honour or split.
   **Override:** request a split.

---

## Top-level plan

**Goal.** Close the three substrate gaps surfaced in the first
end-to-end methodology run. After this section merges, a fresh
substrate must support a planner→daemon→coder commission cycle
without manual intervention.

**Scope.** One section. No parallelism.

**Sequencing.** Execute after s006 lands in `main`. (s006 is
already merged at `fd4a581`; ready to dispatch.)

**Branch.** `section/s007-substrate-end-to-end` off `main`.

---

## Section s007 — substrate-end-to-end

### Section ID and slug

`s007-substrate-end-to-end`

### Objective

Make the substrate support an end-to-end methodology run on a fresh
install: architect commissions planner, planner commissions coder
via daemon, coder produces task report, planner merges PR. Three
underlying fixes:

1. `.claude.json` carried by the volume model and propagated to all
   roles.
2. Daemon source-IP guard removed; bearer token alone enforces
   commissioning auth.
3. CLAUDE.md role-anchor symlinks created at container start /
   commission time so each role's claude-code session loads its
   guide automatically.

### Available context

The first end-to-end methodology run on the VPS surfaced these
issues in this order, on a fresh `~/hello-vps-turtle/` install
post-s006-merge:

1. **`.claude.json` not in any persisted volume.** The architect's
   `~/.claude.json` (claude-code's config + project state, ~25KB)
   lives in the container's writable layer, not in
   `claude-state-architect`. The volume mounts at
   `/home/agent/.claude/`, which is the directory; `.claude.json` is
   a sibling to that directory, not a child. When `commission-pair.sh`
   started the planner, the planner's `~/.claude.json` was missing
   entirely. claude-code treated the planner as a fresh install and
   prompted for OAuth login — even though `.credentials.json` was
   correctly propagated by s006's verify.sh path.

   Manually unstuck by: `docker cp` from architect to host, copy
   into `/var/lib/docker/volumes/claude-state-shared/_data/`,
   `chown 1000:1000`, then `ln -s ~/.claude/.claude.json ~/.claude.json`
   in the planner shell. Planner then started authenticated.

2. **Daemon source-IP guard.** Once auth was unstuck, the planner's
   first `POST /commission` to the daemon returned 503 with the
   error `"planner host not yet resolvable; daemon source-IP guard
   is closed-fail"`. The planner's diagnostic showed
   `getent hosts planner` returns nothing on the compose network —
   the planner service has no `container_name` and no network alias
   (deliberately omitted to allow multi-pair parallelism), so the
   daemon's reverse-DNS check on the source IP returns the container
   ID rather than `planner`. The check closed-fails (correctly) when
   it can't verify, blocking all commissions.

3. **CLAUDE.md as role anchor.** The architect's first run was given
   a "build a hello-world CLI" prompt and produced bash code directly
   — bypassed the methodology entirely. Symlinking
   `methodology/architect-guide.md` to `CLAUDE.md` at the architect's
   working-tree root made the next run pick up the role automatically
   without any methodology seeding in the prompt. This pattern is
   currently manual; it should be automatic.

   Same pattern applies to planner, auditor, and (with an inline
   variant) coder.

The architect-guide is currently exposed inside the architect via
a manual symlink at `/work/architect-guide.md → /methodology/architect-guide.md`,
which Jonathan created during this session and verified works.

The volume layout is in `docker-compose.yml` at repo root. The
relevant entrypoints are in `infra/<role>/entrypoint.sh` (and
`infra/base/entrypoint.sh` for shared logic). The daemon's
auth/access-control code is in `infra/coder-daemon/daemon.js`.
verify.sh and `setup-common.sh` carry the s006 propagation logic
that needs extending in 7.b.

The current substrate at `~/hello-vps-turtle/` is in a **manually
unstuck state**: the architect's `.claude.json` was hand-copied
into both `claude-state-architect` (via `docker cp` to host then
into the volume) and `claude-state-shared`. The planner's
`~/.claude.json` was symlinked manually. Don't depend on this
state surviving teardown — Jonathan plans to tear down and restart
fresh once s007 lands.

### Tasks (informal decomposition)

The agent may decompose differently, but this is the suggested
ordering:

**7.a — `.claude.json` propagation.**

Three sub-changes:

- **Each role's entrypoint creates the `~/.claude.json` symlink at
  startup.** Architect, planner, coder-daemon, auditor. The symlink
  points at `/home/agent/.claude/.claude.json`. Idempotent — if the
  symlink already exists and is correct, do nothing. If a regular
  file exists at `~/.claude.json` (the architect's first-login case),
  move it into the volume location first, then symlink.

  Logic per entrypoint (or factored into a shared helper):

  ```bash
  if [ -f /home/agent/.claude.json ] && [ ! -L /home/agent/.claude.json ]; then
    # Migrate existing container-layer file into volume
    mv /home/agent/.claude.json /home/agent/.claude/.claude.json
  fi
  ln -sfn /home/agent/.claude/.claude.json /home/agent/.claude.json
  ```

  Note `ln -sfn`: -f forces overwrite, -n treats existing symlinks as
  files (don't follow). Idempotent on re-run.

- **`verify.sh` and `setup-common.sh` propagate `.claude.json`.**
  Currently the alpine helper that copies `claude-state-architect`
  contents to `claude-state-shared` may use a glob that misses
  hidden files. Verify the glob form. If it's `cp -a /src/* /dst/`,
  change to `cp -a /src/. /dst/` (the trailing dot copies hidden
  files too). Same for `setup-common.sh`'s Path A copy and the
  architect→shared sync.

- **Retroactive repair.** Like s006, the fix should self-apply on
  next `verify.sh` run without requiring teardown. Existing substrates
  with `.claude.json` only in the architect's container layer get
  migrated on architect restart (entrypoint runs migration); existing
  substrates with `.claude.json` already in `claude-state-architect`
  but missing in `claude-state-shared` get propagated by the next
  `verify.sh` run.

**7.b — Drop daemon source-IP guard.**

In `infra/coder-daemon/daemon.js`, remove the source-IP check from
the auth middleware. Bearer token check stays; it is the only auth
boundary going forward.

Update `methodology/deployment-docker.md` §3.3 to remove the
source-IP check from the access-control list (item 3 in the
"daemon enforces three checks" enumeration). The remaining checks
are network isolation (compose-project boundary) and bearer token.

Update §3.3.2 / §3.3.3 wording so the document accurately reflects
the new design. Don't reframe the security model dramatically —
just remove item 3 and note the rationale ("removed in s007:
brittle in practice; compose-project network isolation plus
bearer token are the real boundaries").

**7.c — CLAUDE.md role-anchor symlinks.**

For each long-lived or ephemeral role, ensure the working tree
that claude-code starts in has a `CLAUDE.md` symlink to the
appropriate methodology guide:

- **Architect.** In `infra/architect/entrypoint.sh` (or wherever the
  architect's working clone is initialised), create
  `/work/CLAUDE.md → /methodology/architect-guide.md`. Idempotent.
- **Planner.** In `infra/planner/entrypoint.sh` after the
  `git clone /work` step that the existing entrypoint already does,
  create `/work/CLAUDE.md → /methodology/planner-guide.md`.
- **Auditor.** In `infra/auditor/entrypoint.sh`, create
  `/work/CLAUDE.md → /methodology/auditor-guide.md`.
- **Coder.** Coders have no methodology guide. The daemon, when
  spawning a coder subshell, writes a small inline `CLAUDE.md` into
  the working tree before invoking claude-code. Suggested content:

  ```markdown
  # You are the coder.

  Your task brief is at <BRIEF_PATH>. Read it. Do exactly what it says.
  Commit your work and a task report to your task branch, open a PR
  back to the section branch, then exit.

  You operate on the brief alone. You do not commission other agents.
  Your tool surface is constrained by `--allowedTools` from the brief's
  "Required tool surface" field; out-of-list actions deny.

  Discharge when done.
  ```

  Substituting `<BRIEF_PATH>` with the actual brief path at write
  time.

**7.d — End-to-end commissioning verification.**

A new test in `infra/scripts/tests/` that exercises the daemon
mechanics end-to-end:

1. Bring up a fresh substrate (volumes pre-existing or fresh).
2. Verify architect entrypoint migrates `.claude.json` if a regular
   file is present.
3. Verify `commission-pair.sh` brings up planner with CLAUDE.md
   symlink, `~/.claude.json` symlink, working credentials.
4. Synthetic commission: planner POSTs to the daemon with a stub
   task brief; daemon spawns subshell; subshell runs a stub script
   (not real claude-code — substrate-level test only) that writes a
   stub task report and exits. Daemon records exit, planner polls
   to completion.
5. Tear down cleanly.

The synthetic-coder approach is sufficient for substrate
verification; the real-claude-code coder execution is exercised
when the architect dispatches actual section work after s007
merges. Don't conflate the two.

This is the test that should have caught all three issues. Going
forward, "substrate end-to-end" means daemon-mechanics-verified,
not just "creds propagate."

### Constraints

- The methodology spec stays untouched. Only `deployment-docker.md`
  changes (§3.3 in 7.b).
- The four canonical role guides stay untouched.
- The substrate-id mechanism from s004 stays untouched. Don't
  re-litigate.
- All fixes must be retroactive on existing substrates where
  reasonable (s006-style: next `verify.sh` repairs the gap).
- No changes to coder-daemon's container toolchain (still bash +
  perl only). The hello-cli end-to-end test that surfaced these
  issues correctly stayed in that envelope.
- The planner's deliberate lack of `container_name` (for future
  multi-pair parallelism) is preserved. 7.b removes the daemon
  check that depended on it; nothing else changes.

### Definition of done

- Fresh substrate setup → architect login → restart architect →
  `verify.sh` → `commission-pair.sh` succeeds, planner enters
  authenticated claude-code session with `CLAUDE.md` already in
  place.
- Planner can `POST /commission` to the daemon and receive 200 +
  commission_id (no source-IP rejection).
- Daemon spawns a coder subshell; subshell runs to completion;
  task report appears in the section branch.
- Synthetic-coder integration test in 7.d passes.
- Existing broken substrates self-repair on next `verify.sh` +
  architect restart (no teardown needed, mirroring s006's retroactive
  property).
- `deployment-docker.md` §3.3 reflects the dropped source-IP check.
- Section report at `briefs/s007-substrate-end-to-end/section.report.md`
  including: brief echo, per-task summary, the entrypoint logic
  spelled out for each role (this becomes the future-of-the-substrate
  reference), the synthetic-coder test transcript, and any residual
  hazards spotted during the work.

### Out of scope

- Multi-pair concurrent operation. The substrate currently supports
  one pair at a time on a host (since `claude-state-shared` is a
  single named external volume). Document this limitation in the
  section report if the work surfaces it; don't fix it here.
- macOS Path B verification. Still flagged from s006, still out of
  scope.
- Findings 8–18 from the s006 handover (bash 3.2, colima profile,
  bbolt corruption, etc.). Each is its own section if it gets one.
- Real claude-code coder execution under the daemon. The synthetic
  stub coder in 7.d is sufficient for substrate verification.
  Real-claude-code-as-coder gets exercised on the next end-to-end
  hello-cli run after s007 merges.
- Auto-detection of when CLAUDE.md should be regenerated (e.g., if
  the methodology guide changes). Symlink resolves at read time, so
  this isn't an issue today, but if 7.c chooses copy-not-symlink
  per the override in design call 3, this becomes a real concern.

### Repo coordinates

- Base branch: `main` (at s006 merge `fd4a581` or later).
- Section branch: `section/s007-substrate-end-to-end`.
- Tasks branch from there per spec §6.

### Reporting requirements

Section report at `briefs/s007-substrate-end-to-end/section.report.md`
on the section branch. Must include:

- Brief echo.
- Per-task summary.
- Entrypoint logic per role (in full, since this becomes the
  future-of-the-substrate reference for what each role's startup
  shell does).
- The propagation file list (what verify.sh now copies; not just
  `.credentials.json` and `.claude.json` but anything else discovered
  during 7.a).
- Synthetic-coder test transcript from 7.d.
- Any residual hazards. Especially: anything claude-code expects on
  disk that this section didn't catch.

---

## Execution

Single agent on the host (same pattern as s001–s006). The agent
works through 7.a–7.d in order, committing per task. After 7.b
the agent should pause briefly to confirm the spec change in
`deployment-docker.md` is the right shape — that's a documentation
change to a spec-companion document and worth a sanity check before
merging.

If the agent finds genuine ambiguity that this brief doesn't
resolve, the right move is "brief insufficient" + discharge. Same
discipline as before.
