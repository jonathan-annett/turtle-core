# s007-substrate-end-to-end — section report

## Brief echo

Follow-up to s006. The first end-to-end methodology run on the VPS
surfaced three substrate gaps that s006's "Path B works" verification
did not catch. s006 verified credentials propagate; it did not verify
a planner can actually start claude-code, reach the daemon, and run a
coder.

Three fixes baked in:

1. **`.claude.json` propagation.** `~/.claude.json` is claude-code's
   config + project state file. It is a sibling to `~/.claude/`, not
   a child. Without intervention it lived in each container's writable
   layer, so the architect had it (after first `claude` run) and every
   ephemeral did not — the planner started without it and was treated
   by claude-code as a fresh install.
2. **Daemon source-IP guard removed.** The daemon resolved the
   planner's container IP via `getent hosts planner` and rejected
   anything else. The planner service has no `container_name` and no
   network alias on `agent-net` (deliberate, to keep multi-pair
   parallelism open), so reverse-DNS returned the container ID rather
   than `planner`. The check closed-failed and 503'd every commission.
3. **CLAUDE.md role anchors.** claude-code reads `CLAUDE.md` from the
   working tree on session start and treats it as the agent's prompt
   header. None of the role working trees had a `CLAUDE.md`, so each
   role needed a human seed prompt to load its methodology guide.

The four design calls in the brief — symlink-not-rebind for
`.claude.json`, drop-source-IP-entirely, symlink-not-copy for
`CLAUDE.md`, one-section-serial — were all accepted as written and
are reflected in the implementation.

Branch: `section/s007-substrate-end-to-end` off `main` at s006 merge
`fd4a581`.

## Per-task summary

### 7.a — `.claude.json` propagation  (commit `647eae4`)

- **Each role's entrypoint** (architect, planner, coder-daemon,
  auditor) now migrates any pre-existing regular `~/.claude.json`
  into `/home/agent/.claude/.claude.json` and then creates a symlink
  back at the canonical path. Idempotent on re-run; resilient to
  the symlink already existing, the regular file already existing,
  or both being absent.
- **`verify.sh` and `setup-common.sh`** now propagate `.claude.json`
  alongside `.credentials.json` from the architect volume into the
  shared volume on every run. Existing substrates self-repair on
  next `verify.sh` + architect restart, mirroring s006's retroactive
  property.

### 7.b — drop daemon source-IP guard  (commit `429d4af`)

- Removed `PLANNER_HOST`, `resolvePlannerIP()`, the cache state, and
  the source-IP express middleware from `infra/coder-daemon/daemon.js`.
- Updated the daemon's top-of-file comment to record the rationale.
- Updated `methodology/deployment-docker.md` §3.3 (enumeration drops
  from three checks to two; trailing paragraph preserves the s007
  rationale so future readers grepping for "source-IP" find context).
- Updated §5.2's reference-`daemon.js` paragraph for consistency.
- The daemon's parse-tool-surface tests (12/12) still pass; the
  removed code had no test coverage, consistent with the gap that
  motivated this section.

### 7.c — CLAUDE.md role anchors  (commit `d4b6028`)

- Architect / planner / auditor entrypoints symlink
  `/work/CLAUDE.md → /methodology/<role>-guide.md` after the working-
  tree clone. Each also adds `CLAUDE.md` to `/work/.git/info/exclude`
  so the symlink stays repo-local and `git status` is clean.
- For coders, the daemon writes a short inline `CLAUDE.md` into each
  commission's workdir (with `BRIEF_PATH` substituted) before
  spawning claude, and excludes it via `.git/info/exclude` so it
  never lands in the task-branch tip the planner merges. Content as
  specified in the brief.

### 7.d — substrate end-to-end test  (commit `27e6be7`)

- New harness at `infra/scripts/tests/test-substrate-end-to-end.sh`
  exercises a synthetic-coder commission against scratch volumes,
  scratch network, scratch ssh keys, and scratch git-server — all
  pid-suffixed, never touching the host's real substrate. Trap
  cleans up regardless of pass/fail.
- 22/22 PASS on first run on this branch. Transcript saved at
  `briefs/s007-substrate-end-to-end/synthetic-coder-test.transcript.txt`.
- The test should have caught all three issues s007 closes; running
  it on a pre-s007 substrate fails on exactly those points.

## Entrypoint logic per role  (post-s007 reference)

This section captures what each role's `entrypoint.sh` does at
container start, in order. It is the canonical reference until a
future section changes the volume model again.

### Architect (`infra/architect/entrypoint.sh`)

1. **SSH key permissions.** Copy `/home/agent/.ssh/*` (mounted
   read-only from `infra/keys/architect/`) to a writable
   `/home/agent/.ssh-rw/`, chmod 700/600, export `GIT_SSH_COMMAND`
   pointing at the writable copy with `StrictHostKeyChecking=no`,
   `UserKnownHostsFile=/dev/null`, `LogLevel=ERROR`.
2. **`.claude.json` migration + symlink (s007 7.a).** If
   `/home/agent/.claude.json` is a regular file (legacy or first
   container-layer write), `mv` it into
   `/home/agent/.claude/.claude.json` (inside the volume). Then
   `ln -sfn /home/agent/.claude/.claude.json /home/agent/.claude.json`.
3. **Working clone of main.** If `/work/.git` is absent, `git clone`
   `git@git-server:/srv/git/main.git` into `/work`.
4. **Read-only auditor clone.** If `/auditor/.git` is absent,
   `git clone git@git-server:/srv/git/auditor.git /auditor`. Failure
   is non-fatal — the auditor repo may be empty until the first
   audit lands.
5. **Git identity.** `architect` / `architect@substrate.local` on both
   `/work` and `/auditor` (when present).
6. **CLAUDE.md role anchor (s007 7.c).**
   `ln -sfn /methodology/architect-guide.md /work/CLAUDE.md`. Add
   `CLAUDE.md` to `/work/.git/info/exclude` if not already present.
7. **Banner + `cd /work` + `exec bash -l`** for interactive use.

### Planner (`infra/planner/entrypoint.sh`)

1. **SSH key permissions.** Same pattern as architect, against
   `infra/keys/planner/`.
2. **`.claude.json` migration + symlink (s007 7.a).** Same logic as
   architect; the regular-file branch is a defensive no-op for fresh
   ephemerals (the planner image's writable layer ships nothing at
   this path).
3. **Working clone of main.** Same as architect — fresh clone each
   commission is correct (the planner is ephemeral, the repos are
   small).
4. **Git identity.** `planner` / `planner@substrate.local` on `/work`.
5. **CLAUDE.md role anchor (s007 7.c).**
   `ln -sfn /methodology/planner-guide.md /work/CLAUDE.md` plus the
   exclude entry.
6. **Banner + `cd /work` + `exec bash -l`.**

### Auditor (`infra/auditor/entrypoint.sh`)

1. **SSH key permissions.** Same pattern, against
   `infra/keys/auditor/`.
2. **`.claude.json` migration + symlink (s007 7.a).** Same logic.
3. **Read-only working copy of main.** `git clone` into `/work`. The
   git-server enforces read-only via the per-role hook, not the
   filesystem.
4. **Writable auditor workspace.** `git clone` `auditor.git` into
   `/auditor`; if empty, `git init -q -b main` and add the remote.
5. **Git identity.** `auditor` / `auditor@substrate.local` on both.
6. **CLAUDE.md role anchor (s007 7.c).**
   `ln -sfn /methodology/auditor-guide.md /work/CLAUDE.md` plus the
   exclude entry. (The architect's `/work` hook would reject any
   auditor push anyway; this keeps `git status` clean for the human.)
7. **Banner + `cd /work` + `exec bash -l`.**

### Coder daemon (`infra/coder-daemon/entrypoint.sh`)

1. **SSH key permissions.** Same pattern, against `infra/keys/coder/`.
   The daemon's coder subshells share this filesystem, so the same
   `GIT_SSH_COMMAND` covers both daemon git operations and coder
   pushes.
2. **`.claude.json` migration + symlink (s007 7.a).** Same logic; the
   coder subshells inherit this symlink.
3. **Git identity.** `coder` / `coder@substrate.local` set globally
   so coder subshells use it without per-workdir re-config.
4. **`cd /daemon && exec node daemon.js`.** The node process runs
   the HTTP server documented in `methodology/deployment-docker.md`
   §4.

#### Coder subshell (s007 7.c, written by daemon at commission time)

When the daemon spawns a coder, after fresh-cloning main into
`/work/coder-<id>/` and checking out the section + task branch but
*before* spawning claude, the daemon writes:

- **`/work/coder-<id>/CLAUDE.md`** — short inline role anchor with
  the brief path substituted in, content per the s007 brief.
- **`/work/coder-<id>/.git/info/exclude`** appended with `CLAUDE.md`
  so the anchor never lands in the task-branch tip.

The daemon then `spawn`s `claude` from PATH with the coder
invocation flags from `deployment-docker.md` §4.5 and waits for it
to finish + push the report.

## Propagation file list

The architect → shared volume sync (run by `setup-common.sh`'s
`provision_auth` and by every `verify.sh` invocation) now propagates:

- **`.credentials.json`** (s006). Mode 0600, owned 1000:1000.
- **`.claude.json`** (s007). Mode 0600, owned 1000:1000.

Mount-root ownership/perms (`chown 1000:1000 /dst && chmod 0700 /dst`)
runs unconditionally on every sync, retroactively repairing any
volume whose mount root predates s006.

No additional files were discovered during 7.a. The directory
contents under `/home/agent/.claude/` (history, plugins, project-
specific subdirs) are intentionally NOT copied into the shared
volume — only the two top-level files claude-code needs at startup
are. If a future claude-code release adds a third top-level dotfile,
extending the helper is a one-line addition; the brief flagged this
as a future possibility (design call 1's "rebind-home" override).

## Synthetic-coder test transcript (7.d)

Full output of `bash infra/scripts/tests/test-substrate-end-to-end.sh`
on this branch, running against the rebuilt `agent-{base,architect,
planner,coder-daemon,git-server}:latest` images:

```
----------------------------------------------------------------------
Phase 0: prereqs
PASS: all required images present
----------------------------------------------------------------------
Phase 1: scaffold scratch substrate
PASS: generated scratch ssh keys
PASS: created scratch network 'turtle-core-test-s007e2e-<pid>-net'
PASS: created scratch volumes (mount-roots normalised)
PASS: wrote scratch compose + env
----------------------------------------------------------------------
Phase 2: scratch git-server + bare repos
PASS: git-server up, main.git + auditor.git initialised
----------------------------------------------------------------------
Phase 3: architect entrypoint (7.a + 7.c symlinks)
PASS: architect: ~/.claude.json is a symlink → /home/agent/.claude/.claude.json
PASS: architect: /work/CLAUDE.md is a symlink → /methodology/architect-guide.md
PASS: architect: CLAUDE.md is in /work/.git/info/exclude
PASS: architect: regular ~/.claude.json migrated into volume on restart, symlink restored
----------------------------------------------------------------------
Phase 4: seed main.git with a synthetic section/task brief
PASS: seeded section.brief.md + t001-stub.brief.md on origin/main
PASS: created section/test-section on origin
----------------------------------------------------------------------
Phase 5: coder-daemon + .claude.json propagation
PASS: .claude.json propagated into shared volume (architect → shared)
PASS: coder-daemon up and listening
PASS: stub claude installed at /usr/local/bin/claude inside daemon
----------------------------------------------------------------------
Phase 6: planner entrypoint + synthetic commission
PASS: planner up (cid=<short>)
PASS: planner: ~/.claude.json is a symlink → /home/agent/.claude/.claude.json
PASS: planner: /work/CLAUDE.md is a symlink → /methodology/planner-guide.md
PASS: planner: .claude.json present and non-empty in shared volume
PASS: POST /commission accepted (commission_id=<short>, no 503)
PASS: synthetic-coder commission completed: status=complete, exit=0,
      report at briefs/test-section/t001-stub.report.md
PASS: report file present at task-branch tip on origin
----------------------------------------------------------------------
Summary: 22 passed, 0 failed
```

The unredacted transcript is saved at
`briefs/s007-substrate-end-to-end/synthetic-coder-test.transcript.txt`
on this branch.

## Residual hazards

### Things that may still surprise the next end-to-end run

1. **Real claude-code as coder is still untested by automation.** 7.d
   uses a stub claude (injected at `/usr/local/bin/claude` in the
   daemon container) so no Anthropic credentials are consumed. The
   first real-claude-code coder commission after s007 merges will be
   the integration test for the daemon's actual coder spawn path.
   Plausible failure modes: claude-code refusing to run with no
   stdin attached, claude-code's `-p` prompt parsing differing from
   the daemon's expectations, claude-code writing to paths the
   `--allowedTools` allowlist surprised the operator on. None of
   these are known-broken; they are simply not yet exercised.

2. **PATH ordering for the coder spawn.** The daemon spawns `claude`
   from PATH. The agent-base image installs claude-code via apt
   (lands at `/usr/bin/claude`). Debian default PATH places
   `/usr/local/bin` before `/usr/bin`, which is what 7.d relies on
   for stub injection. A future image change reordering PATH would
   silently make the stub injection a no-op. The test would then
   fail loudly on /wait timeout rather than passing on the wrong
   binary, but the regression is worth flagging.

3. **claude-code may write hidden files this section did not catch.**
   `.claude.json` is the obvious one; `.credentials.json` was the
   s006 one. claude-code might in the future drop, say, `.claude-
   trace.log` or another sibling. The propagation helper is a
   per-file allowlist, not a glob — adding a third file is a one-
   line addition (per design call 1), but discovery is operator-
   driven, not automated.

4. **Multi-pair concurrent operation.** Out of scope per the brief.
   `claude-state-shared` is a single named external volume; running
   two planner/daemon pairs simultaneously means both pairs share
   one `.claude.json` and one `.credentials.json`. For a single-
   user single-host substrate this is fine. For multi-pair work, a
   future section will need per-pair shared volumes (or a different
   credential-distribution model).

5. **The architect's `/work` working tree picks up `CLAUDE.md` as an
   untracked-but-excluded file on first start.** The
   `.git/info/exclude` entry keeps it out of `git status`, but a
   human running `git clean -fdx` would delete it (the symlink is
   untracked). The next architect start recreates it. Not a bug,
   but worth knowing.

6. **The architect's git-server hook would reject `CLAUDE.md`** if
   it were ever staged + committed + pushed (allowed paths are
   `briefs/**`, `SHARED-STATE.md`, `TOP-LEVEL-PLAN.md`, `README.md`,
   `MIGRATION-*.md`). So the symlink cannot accidentally land in
   `main`. The planner's hook is path-permissive on `section/*`
   and `task/*`; the `.git/info/exclude` entry is the planner's
   safety net. Coder workdirs are throwaway; the same exclude entry
   keeps it out of task-branch tips.

7. **Operator must rebuild role images before the next end-to-end
   run** because s007 changes COPY'd entrypoint scripts and (for
   the daemon) COPY'd `daemon.js`. `setup-linux.sh` /
   `setup-mac.sh` rebuild on re-run; an operator who skips that
   step will still see the pre-s007 behaviour. 7.d's prereq check
   does not catch this — it only checks images exist, not their
   content.

### Things deliberately out of scope (per the brief)

- macOS Path B verification (carried over from s006).
- Real-claude-code coder execution (will be exercised on the next
  hello-cli run).
- Findings 8–18 from the s006 handover.
- Multi-pair concurrent operation.
- Auto-detection of CLAUDE.md regeneration (not needed under the
  symlink approach; would matter under the override-3 copy
  approach).

## Definition-of-done check

| Brief criterion | Status |
|---|---|
| Fresh substrate setup → architect login → restart → verify.sh → commission-pair.sh succeeds, planner enters authenticated session with CLAUDE.md in place | exercised in 7.d (synthetic-coder); real-claude-code path will be exercised by the next end-to-end hello-cli run |
| Planner can `POST /commission` and receive 200 + commission_id (no source-IP rejection) | PASS in 7.d |
| Daemon spawns coder subshell; subshell runs to completion; task report appears in section branch | PASS in 7.d (with stub) |
| Synthetic-coder integration test in 7.d passes | PASS (22/22) |
| Existing broken substrates self-repair on next verify.sh + architect restart | implemented in 7.a; not VPS-verified yet |
| `deployment-docker.md` §3.3 reflects the dropped source-IP check | done in 7.b |
| Section report at `briefs/s007-substrate-end-to-end/section.report.md` | this file |
