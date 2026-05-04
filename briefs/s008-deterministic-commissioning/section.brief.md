# turtle-core update brief — s008 deterministic commissioning

## What this is

A follow-up to s007. The first end-to-end methodology run on the VPS
(architect → planner → coder → auditor for hello-world-with-time)
completed successfully and the substrate now functions, but the
human-driven commissioning ergonomics have a structural weakness:
`commission-pair.sh` and `audit.sh` print a "paste this prompt into
the agent" block and rely on the human to actually paste it. Two
problems:

1. **Non-deterministic role bootstrap.** Whatever the human types
   becomes the role's commissioning prompt. Variation between human
   sessions seeps into the agent's first instruction. The spec
   already requires (§9): "receiving the filename should be enough
   for the agent to read its instructions and proceed without
   further conversational setup." The scripts pretend to do this
   but actually don't.
2. **No brief-existence check.** The scripts will happily commission
   a planner or auditor against a section slug whose brief doesn't
   exist. The agent finds out the hard way after spawn — wasting a
   commission cycle.

This brief packages both fixes as one section,
**s008-deterministic-commissioning**.

---

## Recommendations baked in (override before dispatch)

Three design calls. Each flagged below; edit before dispatch to override.

1. **Optional argument, dual-mode behaviour.** Both scripts accept
   `<section-slug>` as an optional argument:
   - **With argument:** verify the brief exists, then bootstrap claude
     non-interactively with a deterministic prompt. The agent runs to
     completion, then the script drops the human into a shell for
     post-discharge inspection.
   - **Without argument:** drop directly into a shell. Human can run
     `claude` interactively, debug, inspect, do whatever. This
     preserves the existing "open a shell to manually poke the
     container" path.

   Considered alternative: always require the slug. Cleaner spec but
   loses the manual-inspection path, which has been useful during
   substrate iteration. The dual-mode preserves both.
   **Override:** specify always-required if you want to force the
   commissioning path.

2. **Bootstrap via env var consumed by the role's entrypoint, not by
   command-line wrapping.** The script sets
   `BOOTSTRAP_PROMPT="..."` in the container's environment; the
   role's entrypoint checks for it and invokes `claude -p
   "$BOOTSTRAP_PROMPT"` before dropping to bash. Empty/unset → just
   the shell. Reasoning: keeps the script simple (env var is the
   contract); keeps role logic in role entrypoints (the entrypoint
   already orchestrates SSH, git clones, symlinks, banners — bootstrap
   prompt is one more thing in the same place); and lets the
   architect, if it ever runs unattended, follow the same pattern.

   Considered alternative: have the script invoke `docker compose run
   ... bash -lc "claude -p '...'; exec bash -l"` directly. Works but
   pushes role-specific logic into the script and complicates quoting.
   **Override:** specify the in-script approach if you'd rather keep
   entrypoints pure.

3. **Brief-existence check via the architect's clone, not via the
   bare repo volume directly.** `docker exec agent-architect test -f
   /work/<brief-path>` is simpler than mounting the bare-repo volume
   into a throwaway alpine container with safe-directory dance. The
   architect's clone is durable across substrate restarts and will
   reflect main as long as the architect has fetched recently — which
   is the architect's normal mode of operation.

   Considered alternative: read the bare repo directly via
   `docker run --rm -v <bare>:/repo:ro alpine git -C /repo cat-file
   -e main:<path>`. More correct (no dependency on the architect being
   up-to-date), but heavier and needs the bare-volume name dance.
   **Override:** specify bare-repo if you want strict
   architect-independence.

   Note: this design call ties the script to the architect being
   running. Acceptable for this section because the methodology
   already assumes the architect is running when commissions happen
   (the human-as-architect discusses with claude before commissioning).
   If that assumption changes, revisit.

---

## Top-level plan

**Goal.** Make planner and auditor commissioning deterministic when a
section slug is provided, and fail fast when its brief doesn't exist.
Preserve the no-argument path for shell-only inspection.

**Scope.** One section. No parallelism.

**Sequencing.** Execute after s007 lands in `main`.

**Branch.** `section/s008-deterministic-commissioning` off `main`.

---

## Section s008 — deterministic-commissioning

### Section ID and slug

`s008-deterministic-commissioning`

### Objective

Replace the human-paste prompt loop in `commission-pair.sh` and
`audit.sh` with a deterministic bootstrap. The scripts:

1. Accept `<section-slug>` as an optional argument.
2. If argument supplied: verify the brief exists at the canonical
   path on main (via `docker exec agent-architect test -f`). If
   missing, fail fast with a useful error. If present, set
   `BOOTSTRAP_PROMPT` in the role container's environment.
3. If argument absent: skip the brief check; drop straight to shell.

The role entrypoints (planner, auditor) honour `BOOTSTRAP_PROMPT`:
when set, invoke `claude -p "$BOOTSTRAP_PROMPT"` before dropping to
`exec bash -l`. When unset, just the shell.

### Available context

The current `commission-pair.sh` and `audit.sh` (committed at s007
merge) print a "Paste this into the planner" block and rely on the
human. The first end-to-end run on hello-world-with-time used this
path successfully but the human had to manually paste twice (once
for planner, once for auditor) and the prompts were lightly
edited by the human in flight. That edit isn't a problem in itself,
but it's the kind of variability the methodology's "self-bootstrapping
brief" property exists to eliminate.

The architect is always running when commissions happen (it's the
human's working partner; commissioning happens after the human
discusses the brief with the architect). So `docker exec
agent-architect` is reliably available as a verification surface.

The role entrypoints (`infra/<role>/entrypoint.sh`) already do
substantial setup work — SSH key permissions, git clones, identity,
CLAUDE.md symlinks (s007 7.c), banners. Adding a `BOOTSTRAP_PROMPT`
check is one more idempotent step in the same shape.

`claude -p "<prompt>"` is claude-code's non-interactive invocation:
runs the prompt to completion, exits when claude reaches a stopping
point. This is the same mechanism the coder daemon already uses
(per s007 entrypoint design) so the pattern is established.

The coder commissioning path is **out of scope** for this section.
The daemon already writes an inline CLAUDE.md and spawns claude
deterministically (s007 7.c); there is no human in that loop. Only
planner and auditor scripts need this fix.

### Tasks (informal decomposition)

The agent may decompose differently, but this is the suggested
ordering:

**8.a — Brief-existence check helper.**

Add a shared helper in `infra/scripts/lib/check-brief.sh` (or
similar) that takes a brief path and returns 0 if it exists in
the architect's `/work` clone, non-zero with a useful message
otherwise:

```bash
check_brief_exists() {
    local brief_path="$1"
    if ! docker exec agent-architect test -f "/work/${brief_path}"; then
        cat >&2 <<EOF
FATAL: brief not found at ${brief_path} (in agent-architect:/work).

If the architect has just committed the brief, ensure it has been pushed:
    docker exec agent-architect git -C /work push

Or run an architect fetch if the brief is on main but not in the
architect's clone:
    docker exec agent-architect git -C /work fetch && git -C /work pull
EOF
        return 1
    fi
}
```

The error message should help the human distinguish the two
common causes (brief committed but not pushed, brief on main but
architect clone stale). Both are recoverable in one command each.

**8.b — `commission-pair.sh` dual-mode.**

Modify the existing script:

- Argument validation: accept 0 or 1 args. If 0, skip brief check
  and skip bootstrap-prompt setup (current shell-only path
  preserved). If 1, do the check, build the prompt, pass it to
  the planner via `BOOTSTRAP_PROMPT` env.
- The deterministic prompt for the planner should mirror the
  current paste-block content but be authoritative:

  ```
  Read /work/briefs/<section>/section.brief.md and execute
  the section per the methodology in /methodology/planner-guide.md
  (which is symlinked as /work/CLAUDE.md). The coder daemon is at
  http://coder-daemon:<port>. Your bearer token is in
  $COMMISSION_TOKEN. Discharge when the section is done.
  ```

- The "Planner commissioning summary" output block stays in the
  no-argument path (or when --verbose is passed) for human
  visibility. When argument is supplied, replace it with a more
  concise "Commissioning planner against briefs/<section>/section.brief.md"
  line.
- Remove the "Paste this into the planner" instruction in the
  argument-supplied path — there's nothing for the human to paste.
- The `docker compose ... run --rm planner` invocation grows
  `-e BOOTSTRAP_PROMPT="${prompt}"` when in argument mode.

**8.c — `audit.sh` dual-mode.**

Mirror 8.b for the auditor. The deterministic prompt is similar
but reflects the auditor's role:

```
Read /work/briefs/<section>/audit.brief.md and execute the audit
per /methodology/auditor-guide.md (symlinked as /work/CLAUDE.md).
Your private workspace is /auditor (writable). The main repo at
/work is read-only. Write the audit report to the auditor repo
at the path named in the brief, commit and push, then discharge.
```

Same env-var pattern, same dual-mode, same brief-existence check.

**8.d — Planner entrypoint honours `BOOTSTRAP_PROMPT`.**

In `infra/planner/entrypoint.sh`, after the existing setup steps
(SSH, .claude.json, git clone, identity, CLAUDE.md symlink, banner)
and before the final `exec bash -l`, add:

```bash
if [ -n "${BOOTSTRAP_PROMPT:-}" ]; then
    echo
    echo "Bootstrap prompt detected; invoking claude non-interactively."
    echo "When claude discharges, you'll be dropped into a shell."
    echo
    cd /work
    claude -p "${BOOTSTRAP_PROMPT}" || true
    echo
    echo "Claude discharged. Dropping to interactive shell."
    echo
fi

exec bash -l
```

The `|| true` ensures non-zero claude exit doesn't kill the bash
session — the human can still inspect post-discharge. (The script
side may want to capture claude's exit code separately for logging;
TBD by the agent.)

**8.e — Auditor entrypoint honours `BOOTSTRAP_PROMPT`.**

Mirror 8.d in `infra/auditor/entrypoint.sh`. Same shape, same
location in the entrypoint flow.

**8.f — Test extension.**

Add to `infra/scripts/tests/test-substrate-end-to-end.sh` (the
s007 harness):

- New test: invoke commission-pair.sh with a known-bad slug
  (e.g., `s999-does-not-exist`). Expect non-zero exit and an
  error message containing the brief path.
- New test: invoke commission-pair.sh with a known-good slug
  pointing at a synthetic brief committed during the test setup;
  set BOOTSTRAP_PROMPT to a stub that exits 0 immediately
  (override claude with a stub that just echoes its arg);
  confirm the planner container exits cleanly, the bootstrap
  was passed through, and the entrypoint reached bash.

The synthetic-claude-stub approach matches s007 7.d's pattern.

**8.g — Documentation.**

Update:

- `methodology/deployment-docker.md` §6.2 (Section commission
  workflow) to describe both modes of `commission-pair.sh`.
- `methodology/deployment-docker.md` §6.3 (Audit commission) to
  describe both modes of `audit.sh`.
- The script-internal comment headers to document both modes.
- README.md if it has a quickstart section that walks through
  commissioning.

### Constraints

- **Coder commissioning is untouched.** The daemon's existing
  inline-CLAUDE.md + claude-spawn pattern stays. Only the human-
  driven planner and auditor commissioning scripts change.
- **No-argument behaviour preserved exactly.** Existing operators
  who use `commission-pair.sh <slug>` get a different (improved)
  experience; existing operators who manually drop into a shell
  for inspection see no change.
- **Architect must be running** for argument-mode brief check to
  work. This is acceptable per design call 3. The script should
  fail clearly if the architect isn't reachable.
- **No changes to the methodology spec.** The four canonical role
  guides stay untouched. Only `deployment-docker.md` needs
  updating, and only its workflow sections.
- **Idempotent entrypoints.** Re-running with `BOOTSTRAP_PROMPT`
  set on a container that's already had bootstrap run should
  do the right thing — currently containers are ephemeral so
  this is moot, but if a future architect runs in BOOTSTRAP_PROMPT
  mode the entrypoint logic should be safe.

### Definition of done

- `commission-pair.sh <good-slug>` verifies brief, commissions
  planner with deterministic prompt, agent runs to discharge, human
  lands in shell post-discharge.
- `commission-pair.sh <bad-slug>` fails fast with useful error.
- `commission-pair.sh` (no arg) drops to shell as before.
- `audit.sh` mirrors all three behaviours.
- Planner and auditor entrypoints honour `BOOTSTRAP_PROMPT` env
  var when set; behave as today when unset.
- s007 end-to-end test extended with bad-slug and bootstrap-passthrough
  tests; passes.
- `deployment-docker.md` §6.2 and §6.3 updated.
- Section report at
  `briefs/s008-deterministic-commissioning/section.report.md`
  including: brief echo, per-task summary, the deterministic prompts
  in full (this becomes the canonical reference), test transcript,
  any residual hazards.

### Out of scope

- The platform plugin model (target language toolchains via
  `platforms/<target>.yaml`). That's a separate larger section,
  s009 or later. See handover-s008-drafted.md for context.
- Changes to the coder daemon's commissioning path. Already
  deterministic; not touched.
- Architect bootstrap prompt for unattended startup. The architect
  is interactive by design today. If unattended-architect becomes a
  use case, it can adopt the same `BOOTSTRAP_PROMPT` pattern then.
- Any changes to `--allowedTools` semantics or task brief field
  layout. Out of scope.

### Repo coordinates

- Base branch: `main` (at s007 merge or later).
- Section branch: `section/s008-deterministic-commissioning`.
- Tasks branch from there per spec §6.

### Reporting requirements

Section report at `briefs/s008-deterministic-commissioning/section.report.md`
on the section branch. Must include:

- Brief echo.
- Per-task summary.
- The deterministic prompts (planner + auditor) in full, since
  these become the canonical commissioning prompts the
  methodology depends on.
- Test transcript from 8.f.
- Any residual hazards.

---

## Execution

Single agent on the host (same pattern as s001–s007). Work through
8.a–8.g in order, committing per task. The agent may pause briefly
after 8.b/8.c if there's ambiguity in the deterministic prompt
content — these become canonical and worth a sanity check.

If the agent finds genuine ambiguity that this brief doesn't
resolve, the right move is "brief insufficient" + discharge. Same
discipline as before.
