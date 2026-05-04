# s008 — section report: deterministic-commissioning

## Brief echo

The s008 section brief at `briefs/s008-deterministic-commissioning/section.brief.md`
identifies two structural weaknesses in human-driven commissioning,
introduced when s007 first produced a working substrate:

1. **Non-deterministic role bootstrap.** `commission-pair.sh` and
   `audit.sh` printed a "paste this prompt into the planner / auditor"
   block and relied on the human to actually paste it. Whatever the
   human typed (with whatever ad-hoc edits) became the role's
   commissioning prompt — variation between human sessions seeped into
   the agent's first instruction. Spec §9 already requires the opposite:
   "receiving the filename should be enough for the agent to read its
   instructions and proceed without further conversational setup."

2. **No brief-existence check.** The scripts would happily commission a
   planner or auditor against a section slug whose brief didn't exist.
   The agent only discovered this after spawn — wasting a commission
   cycle.

The section bundles both fixes. Three design calls were baked into the
brief and kept unchanged: optional `<section-slug>` argument with dual-
mode behaviour; `BOOTSTRAP_PROMPT` env var consumed by the role
entrypoints (not by command-line wrapping); brief-existence check via
`docker exec agent-architect test -f` (acceptable per the
methodology's assumption that the architect is up during commissions).

## Per-task summary

| Task  | Subject                                                | Commit    |
| ----- | ------------------------------------------------------ | --------- |
| 8.a   | Brief-existence check helper (`infra/scripts/lib/check-brief.sh`)        | `5243d74` |
| 8.b   | `commission-pair.sh` dual-mode                                           | `47327a0` |
| 8.c   | `audit.sh` dual-mode                                                     | `3b5809b` |
| 8.d/e | Planner + auditor entrypoints honour `BOOTSTRAP_PROMPT`                  | `fba61ae` |
| 8.f   | Substrate end-to-end tests cover bad-slug + bootstrap-passthrough        | `f50b55f` |
| 8.g   | Docs reflect deterministic commissioning (deployment-docker.md, README)  | `420ea5a` |

### 8.a — Brief-existence check helper

`infra/scripts/lib/check-brief.sh` exports `check_brief_exists()`. The
helper verifies the brief at `/work/<path>` inside the architect
container before either role script touches docker compose. It
distinguishes three failure modes with distinct error messages and exit
codes:

- Architect not running (rc=2). Hint: `docker compose up -d architect`.
- Brief absent (rc=1). Hint covers both common stale-state causes
  (committed but not pushed; on main but architect clone is behind),
  each recoverable in one command.
- Success (rc=0).

The helper accepts an `ARCHITECT_CONTAINER` env var override (default
`agent-architect`) so the substrate end-to-end test (8.f) can point it
at its scratch architect. Production callers leave it unset.

### 8.b — `commission-pair.sh` dual-mode

The script now accepts the section slug as an optional argument:

- **Argument supplied (commissioning mode).** Sources `check-brief.sh`
  and verifies `briefs/<slug>/section.brief.md` exists. Builds the
  deterministic planner bootstrap prompt (see "Canonical prompts"
  below). Brings up the daemon. Runs the planner with
  `BOOTSTRAP_PROMPT` in its environment.
- **No argument (manual mode).** Skips the brief check. Brings up the
  daemon. Drops to a planner shell with a manual-mode banner showing
  the daemon URL/token and a suggested prompt skeleton.

Existing port/token generation, `.pairs/.pair-<slug>.env` writeout (or
`.pair-shell-<pid>.env` for manual mode), and trap-driven `compose
down -v` teardown are unchanged.

### 8.c — `audit.sh` dual-mode

Mirrors 8.b for the auditor. Verifies `briefs/<slug>/audit.brief.md`,
builds the deterministic auditor bootstrap prompt, runs the auditor
container with `BOOTSTRAP_PROMPT`. The post-discharge "ferry the
report into main" reminder block is preserved.

### 8.d — Planner entrypoint honours `BOOTSTRAP_PROMPT`

`infra/planner/entrypoint.sh` gains a small block immediately before
`exec bash -l`:

```bash
if [ -n "${BOOTSTRAP_PROMPT:-}" ]; then
    echo
    echo "Bootstrap prompt detected; invoking claude non-interactively."
    echo "When claude discharges, you'll be dropped into a shell."
    echo
    claude -p "${BOOTSTRAP_PROMPT}" || true
    echo
    echo "Claude discharged. Dropping to interactive shell."
    echo
fi
```

The trailing `|| true` keeps the shell reachable for post-discharge
inspection even if claude exits non-zero. When `BOOTSTRAP_PROMPT` is
unset/empty, behaviour is unchanged: the existing banner prints, then
straight to `exec bash -l`.

### 8.e — Auditor entrypoint honours `BOOTSTRAP_PROMPT`

Mirrors 8.d in `infra/auditor/entrypoint.sh`.

### 8.f — Test extension

Two new phases on the existing s007 substrate end-to-end harness
(`infra/scripts/tests/test-substrate-end-to-end.sh`):

- **Phase 7 — bad-slug failure.** Invokes `commission-pair.sh` directly
  with `s999-does-not-exist-${pid}` and `ARCHITECT_CONTAINER=
  ${project}-architect` overriding the canonical container name.
  Asserts the script exits non-zero (rc=1), the error message names
  the missing brief path, and no docker-compose containers leak under
  the bad-slug project namespace.

- **Phase 8 — `BOOTSTRAP_PROMPT` passthrough.** Mounts a stub `claude`
  binary into the planner via `docker compose run -v
  ${stub}:/usr/local/bin/claude:ro`, sets `BOOTSTRAP_PROMPT` to a
  unique sentinel, and runs with `-T </dev/null` so `exec bash -l`
  reads EOF and exits cleanly. The stub records its argv into a
  marker file in the shared volume. Asserts: container exits 0, the
  entrypoint logs both the bootstrap-detected and post-discharge
  banners, the stub was invoked with `-p` as `$1` and the sentinel as
  `$2`.

The test rebuilds nothing — but note that running it requires
`agent-planner:latest` and `agent-auditor:latest` to have been rebuilt
since 8.d/8.e (the entrypoints are baked into the image at build
time). The first iteration of 8.f failed Phase 8 against a stale
planner image; rebuilding (`docker compose build planner auditor`)
and re-running passes 31/31.

### 8.g — Documentation

- `methodology/deployment-docker.md` §6.2 (section commission) and
  §6.3 (audit commission) describe both modes, the brief-verification
  mechanism, and quote the canonical bootstrap prompts verbatim.
- `README.md` "Commissioning" section reflects the new flow:
  brief-existence check is step 1, `BOOTSTRAP_PROMPT` replaces the
  old "paste this block" step, manual mode is documented as the
  substrate-iteration escape hatch.
- Script-internal comment headers updated in 8.b/8.c.

## Canonical prompts

These are the deterministic prompts the role scripts pass to their
respective entrypoints via `BOOTSTRAP_PROMPT`. They are the canonical
commissioning instructions the methodology now depends on.

### Planner (commission-pair.sh)

```
Read /work/briefs/<section>/section.brief.md and execute the section
per the methodology in /methodology/planner-guide.md (which is
symlinked as /work/CLAUDE.md). The coder daemon is at
http://coder-daemon:<port>. Your bearer token is in $COMMISSION_TOKEN.
Discharge when the section is done.
```

`<section>` is the slug supplied to `commission-pair.sh`; `<port>` is
the per-pair random port allocated by the script.

### Auditor (audit.sh)

```
Read /work/briefs/<section>/audit.brief.md and execute the audit per
/methodology/auditor-guide.md (symlinked as /work/CLAUDE.md). Your
private workspace is /auditor (writable). The main repo at /work is
read-only. Write the audit report to the auditor repo at the path
named in the brief, commit and push, then discharge.
```

## Test transcript

Captured from a clean run of
`bash infra/scripts/tests/test-substrate-end-to-end.sh` after 8.a–8.g
landed and `docker compose build planner auditor` had been run:

```
----------------------------------------------------------------------
Phase 0: prereqs
PASS: all required images present
----------------------------------------------------------------------
Phase 1: scaffold scratch substrate
PASS: generated scratch ssh keys
PASS: created scratch network 'turtle-core-test-s007e2e-19035-net'
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
PASS: planner up (cid=fec6fdf53164)
PASS: planner: ~/.claude.json is a symlink → /home/agent/.claude/.claude.json
PASS: planner: /work/CLAUDE.md is a symlink → /methodology/planner-guide.md
PASS: planner: .claude.json present and non-empty in shared volume
PASS: POST /commission accepted (commission_id=34ab87fc, no 503)
PASS: synthetic-coder commission completed: status=complete, exit=0, report at briefs/test-section/t001-stub.report.md
PASS: report file present at task-branch tip on origin
----------------------------------------------------------------------
Phase 7: commission-pair.sh bad-slug failure (s008)
PASS: commission-pair.sh bad-slug exited non-zero (rc=1)
PASS: bad-slug error message names the missing brief path
PASS: no compose containers leaked under 'turtle-core-s999-does-not-exist-19035'
----------------------------------------------------------------------
Phase 8: planner BOOTSTRAP_PROMPT passthrough (s008)
PASS: planner ran with BOOTSTRAP_PROMPT and exited 0
PASS: entrypoint logged 'Bootstrap prompt detected' banner
PASS: entrypoint logged the post-discharge banner (reached bash -l)
PASS: stub claude was invoked by the entrypoint
PASS: stub claude received '-p' as first argument
PASS: stub claude received the BOOTSTRAP_PROMPT sentinel as second argument
----------------------------------------------------------------------
Summary: 31 passed, 0 failed
```

## Residual hazards

1. **Architect-clone freshness.** The brief-existence check reads from
   the architect's `/work` clone, not from the bare repo (per design
   call 3). If the architect's clone is behind main, a brief that
   exists on origin will appear missing. The error message tells the
   human exactly how to recover (`docker exec agent-architect git -C
   /work fetch && pull`), but a careless re-trigger after the fetch
   has been started but not finished will still surface as "missing".
   This is acceptable: in normal use the human discusses the brief
   with the architect before commissioning, which means the architect
   has just authored or pulled it.

2. **Architect required for any argument-mode invocation.** Both
   scripts now refuse to run (rc=2) if `agent-architect` isn't up. The
   manual mode (no argument) is unaffected. Anyone who relied on
   running `commission-pair.sh <slug>` while the architect was down
   will need to either bring it up or fall back to manual mode and
   paste the prompt themselves.

3. **No-argument path is now strictly for manual inspection.** The
   shell-only path no longer prints a "paste this prompt" block tied
   to a specific section slug; it prints a generic skeleton with the
   slug as `<section>`. If anyone was relying on that block in a
   workflow, they'll need to feed the slug to the script instead.
   This was the intent.

4. **Real-claude execution still untested by the harness.** Phase 8
   uses a stub `claude` binary; the test verifies the entrypoint's
   passthrough behaviour, not that the real claude-code binary
   honours `claude -p` the way we expect. The first true end-to-end
   confirmation will be the next architect-driven section commission
   on the VPS — same shape as the s007 hello-world-with-time run, but
   with the human paste step gone.

5. **`agent-planner` and `agent-auditor` images must be rebuilt** after
   any future change to the role entrypoints (this section's changes
   are baked into the image, not bind-mounted). The s007 setup
   scripts already do this on first install; substrate iterators
   doing partial rebuilds need to remember `docker compose build
   planner auditor` for changes here to take effect. The 8.f test
   exposes this neatly: a stale image silently passes the "container
   exits 0" assertion (since the entrypoint just falls through to
   `exec bash -l`) but fails the bootstrap-detected banner assertion.
