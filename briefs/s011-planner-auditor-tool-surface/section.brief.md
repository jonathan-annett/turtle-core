# turtle-core update brief — s011 planner/auditor tool surface

## How to read this brief (read first)

**This is a substrate-iteration brief, not a project-methodology
brief.** s011 modifies the substrate's methodology spec, role
guides, and role entrypoints. It is implemented the same way s001
through s010 were implemented: a single agent on the host, working
directly on a section branch, committing files, pushing, writing a
section report, and discharging. There is no architect, planner,
coder, or auditor involved in implementing s011 itself.

The brief mentions "planner" and "auditor" extensively because those
are the names of the **substrate roles whose tool-surface mechanism
this section completes**. The brief also references the methodology
spec and role guides because s011 updates them. None of this implies
running the project-methodology pipeline during s011 itself — until
the very last task (11.h), which is a smoke-test methodology run that
validates the completed work.

So: do not commission a planner or auditor for tasks 11.a–11.g. Read
this brief on the section branch, implement 11.a–11.g directly in the
working tree, commit each task as a separate commit (or as task
branches merged into the section branch — either pattern is fine for
substrate-iteration, matching s001–s010), then run 11.h as a manual
methodology-run smoke test, capture its transcript, and only then
write the section report and discharge. The human handles the
section→main merge.

## What this is

A regression discovered during an attempted first real methodology
run on embedded HIL (which was supposed to follow s010's remote-host
integration). The substrate has shipped ten sections and runs
end-to-end *for substrate-iteration work*, but **non-interactive
methodology runs cannot proceed past the planner**. The planner's
claude-code session has no tool surface and is silently denied
every git operation it needs.

The root cause is an asymmetry in the substrate's tool-surface
mechanism:

- **Coder** (s001 era, commit `d109188`): the coder-daemon reads
  `--allowed-tools` from the task brief authored by the planner.
  Works. Has worked since s001.
- **Planner** (s008 introduced non-interactive bootstrap, `47327a0`
  / `fba61ae`): runs `claude -p "$BOOTSTRAP_PROMPT"` with no
  `--allowed-tools` argument and no upstream tool-surface field in
  the section brief. Methodology-required git operations (`git
  checkout`, `git branch`, `git commit`, `git push`, `git merge`)
  are denied by default. The planner correctly self-diagnoses as
  "brief insufficient" — that's good behaviour, but the cause is
  in the substrate, not the brief.
- **Auditor**: same as planner (no plumbing, same shape of gap).

The s007-era hello-world-with-time methodology run worked because
the planner was *interactive* — the human attached and approved
each Bash command claude requested. s008 introduced non-interactive
bootstrap without extending the existing brief→`--allowed-tools`
mechanism one level up the hierarchy. The regression was masked
because s009 and s010 shipped substrate machinery (platform plugin
model, remote-host integration) without exercising a real
methodology run end-to-end. s011 closes both the mechanism gap and
the discipline gap that allowed the regression to ship.

The fix shape is symmetric and follows the existing pattern:
**architect authors a "Required tool surface" field into section
briefs and audit briefs; planner and auditor entrypoints extract it
and pass `--allowed-tools` to claude.** Parallel to how planner
already authors a tool-surface field into task briefs and the
coder-daemon translates it for coders.

This brief packages the mechanism fix, the documentation update,
three already-discovered substrate defects, and a discipline-
establishing methodology-run smoke test as one section,
**s011-planner-auditor-tool-surface**.

---

## Recommendations baked in (override before dispatch)

Six design calls. Each flagged below; edit before dispatch to
override.

1. **Tool-surface authoritative source: section/audit brief authored
   by architect.** The architect already authors section briefs and
   audit briefs. Adding a "Required tool surface" field is symmetric
   with how planner authors the same field into task briefs, and
   reuses the existing mental model. The mechanism becomes uniform
   across all three role-pair handoffs: architect→planner,
   planner→coder, architect→auditor.

   Considered alternative: a methodology-wide config file (e.g.,
   `methodology/role-tool-surfaces.yaml`) that specifies static
   defaults for each role. Simpler but less flexible — different
   sections legitimately need different tool surfaces (e.g., a
   section that involves no remote-host operations doesn't need
   `ssh` in the planner's allowlist). The per-brief approach mirrors
   what works for the coder.

   Considered alternative: hybrid (methodology-wide defaults
   merged with section-brief overrides). Lower ceremony for typical
   cases. Worth a future enhancement once the per-brief approach is
   in place and we've seen what gets repeated across sections.

   **Override:** specify methodology-wide config or hybrid if
   preferred.

2. **Fail clean when tool surface is absent.** If a section brief
   or audit brief doesn't include a "Required tool surface" section,
   the planner/auditor entrypoint should exit non-zero with a clear
   error pointing at the spec section that defines the field — *not*
   fall back to a hardcoded default. This avoids silently allowing
   too much (security/correctness hazard) and avoids silently
   denying everything (the current opaque behaviour).

   The error message should be actionable: "Brief at /work/<path>
   has no '## Required tool surface' section. The architect must
   author this field; see methodology/agent-orchestration-spec.md
   §<section>."

   Considered alternative: warn and apply a conservative default
   (read-only). Lower friction for migrating old briefs. Defers the
   problem rather than solving it.

   **Override:** specify warn-and-default if you want a softer
   migration path.

3. **Tool-surface field format: mirror the existing task-brief
   format.** Whatever format the coder-daemon currently parses from
   task briefs for `--allowed-tools` is the format section briefs
   and audit briefs should use. Don't invent a new schema. The
   agent should inspect coder-daemon's parser (likely in
   `infra/coder-daemon/`) and write planner/auditor parsers that
   accept the same input shape.

   This means: one parser pattern, one documentation pattern, one
   mental model. Architects who already understand how planners
   author task-brief tool surfaces will recognise the section-brief
   field immediately.

   **Override:** specify a different format if the coder-daemon's
   format is wrong for some reason (in which case the override
   probably warrants its own section to fix the coder-daemon side
   too).

4. **Spec is canonical; guides are regenerated.** The role guides
   begin with "This guide is a derivative of the canonical
   methodology spec (v2.1). When the spec changes, this is
   regenerated from it. Do not hand-edit." So the spec
   (`methodology/agent-orchestration-spec.md`) is the source of
   truth.

   If there is a regeneration script in `infra/scripts/` or
   `methodology/`, use it. If regeneration is manual ("derivative"
   may mean human-curated rather than scripted), hand-edit each
   affected guide consistently with the spec change. The agent
   should inspect and proceed accordingly.

   **Override:** specify the regeneration approach explicitly if
   you know which it is.

5. **F42/F43/F44 porting: re-implement directly in turtle-core, do
   not copy patches from hello-turtle.** Three substrate-defect
   fixes were applied to a downstream clone (`~/hello-turtle/`)
   during the aborted Option B run:

   - **F42** — `setup-common.sh` verify-runner uses `bash -lc`
     which re-sources profile scripts and overrides the
     Dockerfile's `ENV PATH`, breaking venv-installed tools. Fix:
     `bash -c` instead of `bash -lc` for the verify invocation.
   - **F43** — verify-runner doesn't wrap commands with
     `set -o pipefail`, so pipeline failures are silently masked.
     Fix: wrap with `bash -c "set -o pipefail; ${cmd}"`.
   - **F44** — platform YAML uses `pio platform show espressif32 |
     head -1` as a verify command, which fails under pipefail due
     to SIGPIPE on pio. Fix: change to `pio platform show
     espressif32 >/dev/null` in
     `methodology/platforms/platformio-esp32.yaml`.

   The agent should re-implement each fix from the description
   above, not by patch-copying. The line numbers and surrounding
   context in turtle-core may differ from hello-turtle. Re-implementing
   ensures the fixes actually fit the canonical code.

   **Override:** specify patch-copy if you'd rather just lift the
   diffs.

6. **Methodology-run smoke test: minimal hello-world, single
   section, captured transcript.** The smoke test in 11.h proves
   that 11.a–11.g actually restored non-interactive methodology-run
   capability. The smoke should be:

   - Minimal scope: a hello-world script (Python or shell) that
     prints "hello, world." No platforms, no remote hosts, no
     embedded toy — keep it tight so a failure is unambiguously a
     methodology issue, not a toolchain issue.
   - Authored on a fresh substrate clone (so prior state from
     `~/hello-turtle/` doesn't contaminate). The agent sets up a
     fresh clone in a scratch location, runs `./setup-linux.sh`,
     attaches to the architect, drafts TOP-LEVEL-PLAN.md / SHARED-
     STATE.md / section.brief.md including the new "Required tool
     surface" field, commissions the planner non-interactively,
     watches it complete, runs audit, captures everything.
   - Transcript captured under
     `infra/scripts/tests/manual/methodology-run-smoke.md` and
     referenced in the section report.

   Considered alternative: automated end-to-end test in
   `infra/scripts/tests/` that spins up a fresh substrate and
   runs the methodology cycle. Stronger ongoing protection but
   substantially more work and harder to debug when it breaks.
   Worth doing as a follow-up section once the manual procedure
   is established.

   **Override:** specify automated test if you want the stronger
   shape now.

---

## Top-level plan

**Goal.** Restore non-interactive methodology-run capability for
the planner→coder→auditor pipeline by extending the existing
brief→`--allowed-tools` mechanism from task briefs up to section
briefs and audit briefs. Port three substrate-defect fixes from
the downstream hello-turtle clone. Establish methodology-run
smoke as a discipline for future sections that touch commission
machinery.

**Scope.** One section. Eight tasks (11.a–11.h). No parallelism.

**Sequencing.** Execute after s010 lands in `main`. Currently at
`1890ee4` (s010 merge).

**Branch.** `section/s011-planner-auditor-tool-surface` off `main`.

---

## Section s011 — planner-auditor-tool-surface

### Section ID and slug

`s011-planner-auditor-tool-surface`

### Objective

After this section lands:

1. The methodology spec (`methodology/agent-orchestration-spec.md`)
   defines a "Required tool surface" field for section briefs and
   audit briefs, with the same schema/format as the existing
   task-brief field.
2. The role guides (`architect-guide.md`, `planner-guide.md`,
   `auditor-guide.md`) reflect the spec change — architect-guide
   teaches the architect to author the field; planner-guide and
   auditor-guide note where the role's own tool surface comes from.
3. `infra/planner/entrypoint.sh` and `infra/auditor/entrypoint.sh`
   parse the tool-surface field from their brief and pass
   `--allowed-tools` to claude. Fail-clean if the field is absent.
4. F42, F43, F44 are fixed in turtle-core's `setup-common.sh` and
   `methodology/platforms/platformio-esp32.yaml`.
5. A minimal hello-world methodology run completes end-to-end
   non-interactively on a fresh substrate clone, with captured
   transcript demonstrating the fix.

### Available context

- The aborted Option B run on `~/hello-turtle/` exercised the
  architect (who produced a clean section brief without the new
  field, since it didn't exist) and the planner (who self-discharged
  with "brief insufficient" because every git operation was denied).
  The architect-generated artefacts on hello-turtle are not
  authoritative reference — they were produced before the spec
  change this section makes.
- The coder-daemon's existing `--allowed-tools` parsing is in
  `infra/coder-daemon/` (most likely in the daemon's JavaScript
  sources, since the `coder-daemon` service uses Node per the
  Dockerfile structure). The parser implementation, input format,
  and error semantics there are the reference for symmetrically
  implementing the same in planner/auditor entrypoints.
- The planner-guide already documents the task-brief "Required tool
  surface" field (see the field list in §"Writing a task brief").
  The spec wording for the new section-brief / audit-brief field
  should match the existing task-brief wording — modify in one
  place, propagate via guide regen.
- F42/F43/F44 fixes in hello-turtle live at:
  - `setup-common.sh` line ~182 (the `if docker run --rm
    --entrypoint bash "${image}" -c "set -o pipefail; ${cmd}"`
    line; original was `-lc "${cmd}"` without pipefail).
  - `methodology/platforms/platformio-esp32.yaml` coder-daemon
    verify list (the `pio platform show espressif32 >/dev/null`
    entry; original was `... | head -1`).

### Tasks (informal decomposition)

The agent may decompose differently, but this is the suggested
ordering:

**11.a — Spec update.**

Edit `methodology/agent-orchestration-spec.md`. Add the "Required
tool surface" field to the section-brief schema and audit-brief
schema, with wording mirroring the existing task-brief field.
The field is mandatory; absent → planner/auditor entrypoints
fail clean with the error message specified in design call 2.

If the spec has a version number (e.g., "v2.1"), increment it
(e.g., "v2.2") and note the change in any changelog or version-
history section.

**11.b — Architect-guide update.**

Update `methodology/architect-guide.md` to instruct the architect
to author "Required tool surface" sections into:
- Every section brief (for the planner).
- Every audit brief (for the auditor).

Specify the field format (same as task-brief tool surface). Give
the architect concrete guidance on what tool surface to author —
e.g., for a methodology run that involves git operations only,
the planner needs `Bash(git ...)` patterns; for a section involving
remote-host SSH, also `Bash(ssh ...)` and `Bash(scp ...)`; etc.

If the guide-regen process is scripted, run the script; if
manual, hand-edit consistently with the spec change.

**11.c — Planner-guide update.**

Update `methodology/planner-guide.md` to note: "Your tool surface
comes from the 'Required tool surface' field in your section brief,
in the same shape you author for coders in task briefs. If the
field is absent, the substrate fails clean before your claude
session starts."

Note the symmetry explicitly — the planner is now both producer
(of task-brief tool surfaces) and consumer (of section-brief tool
surfaces). This is the canonical pattern.

**11.d — Auditor-guide update.**

Same shape as 11.c for `methodology/auditor-guide.md`. The
auditor reads its tool surface from the audit brief. Note that
audit briefs may legitimately need different surfaces from section
briefs — auditors typically need read-only git, plus whatever
verification tooling the audit requires (test runners, build
commands, HIL access via remote host).

**11.e — Planner entrypoint plumbing.**

Edit `infra/planner/entrypoint.sh`. Before invoking `claude -p
"${BOOTSTRAP_PROMPT}"`, parse the "Required tool surface" field
from the section brief (path is in `${BOOTSTRAP_PROMPT}` or can
be derived from `${SECTION_SLUG}` or similar — agent inspects).

The parsing logic should mirror what coder-daemon does for task
briefs. Pass the parsed list as `--allowed-tools` arguments to
the `claude` invocation:

```bash
claude -p "${BOOTSTRAP_PROMPT}" \
    --allowed-tools 'Bash(git checkout:*)' \
    --allowed-tools 'Bash(git commit:*)' \
    ... etc
```

If the field is absent in the brief, print the actionable error
from design call 2 and exit non-zero. The `|| true` and `exec
bash -l` at the end of the existing entrypoint should still
catch the failure case so the operator can post-mortem in the
container.

**11.f — Auditor entrypoint plumbing.**

Same shape as 11.e for `infra/auditor/entrypoint.sh`. Audit
briefs use the same field format; the parser can be shared via
a helper script if convenient (e.g.,
`infra/scripts/lib/parse-tool-surface.sh` or extending the
coder-daemon's parser to be invokable from shell — agent's
judgment on factoring).

**11.g — Port F42, F43, F44 fixes.**

Three small fixes per design call 5:

- F42: `setup-common.sh` verify-runner — change `-lc` to `-c`
  on the docker-run invocation that runs platform verify
  commands.
- F43: same line — wrap the command with `set -o pipefail; ` so
  pipeline failures surface honestly.
- F44: `methodology/platforms/platformio-esp32.yaml` coder-daemon
  verify list — change the second entry from `pio platform show
  espressif32 | head -1` to `pio platform show espressif32
  >/dev/null`.

Three small edits; one commit (or three commits — agent's
judgment) with a clear rationale referencing this brief.

**11.h — Methodology-run smoke test.**

Set up a fresh substrate clone in a scratch location (e.g.,
`/tmp/turtle-core-s011-smoke/` or `~/turtle-core-smoke/`). Run
`./setup-linux.sh` (no `--platform=`, no `--remote-host=` — keep
it minimal). Verify 10/10 smoke. Attach to the architect.

Draft inside the architect:
- `TOP-LEVEL-PLAN.md` with a single section "hello".
- `SHARED-STATE.md` with whatever's appropriate (likely minimal).
- `briefs/s001-hello/section.brief.md` for a trivial section:
  e.g., "create `hello.py` that prints `hello, world.`; tests
  via `python hello.py | grep -q '^hello, world\\.$'`."
- Include a "Required tool surface" field per the new spec —
  this is the architect now applying 11.b's instructions.

Commit, exit architect, run
`./commission-pair.sh s001-hello`. The planner should now
run non-interactively to completion: create section branch,
author task brief (also with tool surface), commission coder,
coder writes hello.py, planner merges task into section,
writes section report, discharges.

Then `./audit.sh s001-hello` (or whatever the audit invocation
is — agent inspects). Auditor runs the verification command,
green.

Capture the full operator-side transcript (terminal output) of
the architect conversation, the planner run, and the audit run.
Save under
`infra/scripts/tests/manual/methodology-run-smoke.md` with
sections for each phase.

If anything fails at this step, that's a discovered defect in
11.a–11.g and the agent investigates / fixes / re-runs until
green. **This is the actual integration test.** Tear down the
scratch clone after capture; do not commit it.

### Constraints / invariants

- **Coder commissioning is untouched.** The coder-daemon's existing
  `--allowed-tools`-from-task-brief mechanism stays. Only planner
  and auditor get the parallel mechanism added.
- **No changes to claude-code's permission model itself.** This
  section uses `--allowed-tools` exactly as claude-code already
  documents it.
- **Interactive paths preserved.** If `BOOTSTRAP_PROMPT` is empty/
  unset, the entrypoint should drop straight to shell as today —
  the new tool-surface parsing only activates in the bootstrap
  path. (Otherwise we'd break the manual-inspection workflow.)
- **No changes to git-server push semantics.** `section/*` and
  `task/*` push permissions stay. This section adds tool-surface
  plumbing; git-server's hooks already enforce the right shape on
  the ref side.
- **F42/F43/F44 fixes are local to specific files.** No broad
  refactor; just the three edits described.
- **The smoke test in 11.h does NOT touch the production substrate
  on `~/hello-turtle/` or `~/turtle-core/`.** It runs in a scratch
  clone and is torn down after capture.

### Definition of done

- Spec defines "Required tool surface" field for section briefs and
  audit briefs.
- Architect-guide instructs authoring the field.
- Planner-guide and auditor-guide note where the role's tool
  surface comes from.
- `infra/planner/entrypoint.sh` parses the field and passes
  `--allowed-tools` to claude, fail-clean when absent.
- `infra/auditor/entrypoint.sh` same.
- F42, F43, F44 fixed in turtle-core (setup-common.sh,
  platformio-esp32.yaml).
- Methodology-run smoke test transcript captured under
  `infra/scripts/tests/manual/methodology-run-smoke.md`, showing
  planner+coder+auditor completing non-interactively end-to-end
  on a fresh substrate.
- Section report at
  `briefs/s011-planner-auditor-tool-surface/section.report.md`
  including: brief echo, per-task summary with commit hashes,
  the deterministic prompts for planner and auditor (in case they
  changed), the smoke-test transcript referenced, any residual
  hazards or new findings.

### Out of scope

- Platform plugin model changes. The platform YAML's
  `defaults.allowed_tools` field stays as-is (categories list);
  if it should be richer in the future, that's a separate section.
  This section's tool-surface mechanism operates on briefs, not on
  platform YAML.
- Hybrid methodology-wide config + per-brief override scheme. Per
  design call 1, keep it simple: brief-only authoritative source.
- F46 (LAN smoke test false negative on Crostini). Separate finding,
  smaller scope, not blocking.
- F47 (commission-pair from wrong clone uses wrong keys). UX
  paper-cut; can fold in if trivially adjacent during entrypoint
  work, otherwise leave for a follow-up.
- F48 (ephemeral creds stale after architect OAuth refresh).
  Documented workaround exists (re-run verify.sh). UX paper-cut
  not in scope here.
- Substrate-iteration discipline doc (Finding 32 from older
  handover). Out of scope — substrate-iteration is what this
  section *is*, not what it documents.
- Automated end-to-end methodology test in `infra/scripts/tests/`.
  Per design call 6, manual procedure suffices; automation is a
  later section.
- Architect-side equivalent. The architect is interactive by design
  and the human approves its tool calls live. If/when an unattended
  architect becomes a use case, it can adopt the same pattern then.

### Repo coordinates

- Base branch: `main` (at `1890ee4` — s010 merge).
- Section branch: `section/s011-planner-auditor-tool-surface`.
- Task commits or task branches off the section branch are both
  fine — same as s001–s010 used.

### Reporting requirements

Section report at
`briefs/s011-planner-auditor-tool-surface/section.report.md` on
the section branch. Must include:

- Brief echo.
- Per-task summary (11.a through 11.h) with commit hashes.
- The deterministic prompts for planner and auditor as they end
  up after this section. If 11.e/11.f change them at all, the
  new versions are canonical and worth recording in full here.
- Reference to the methodology-run smoke transcript at
  `infra/scripts/tests/manual/methodology-run-smoke.md` (do not
  inline the full transcript in the section report — point to it).
- Any new findings discovered during implementation. Specifically:
  if the parser implementation reveals shape mismatches between
  what coder-daemon does for task briefs and what makes sense for
  section/audit briefs, document them.
- Residual hazards. F46/F47/F48 deferred status. Anything else
  noticed during 11.h that the next handover should pick up.

---

## Execution

Single agent on the host (Chromebook clone of turtle-core, at
`~/turtle-core/`), same pattern as s001–s010. **Do not commission
any other agents for tasks 11.a–11.g — this is substrate-iteration
work.** Work through 11.a–11.g in order, committing per task. 11.h
is the smoke methodology-run; that one *does* exercise the
substrate's pipeline (architect → planner → coder → auditor) on a
fresh scratch clone, but only as integration test, not as
implementation pathway.

If the agent finds genuine ambiguity that this brief doesn't
resolve, the right move is to ask the human for a brief amendment
or, if that's not available, to discharge with "brief insufficient"
and document the gap in a partial section report. Same discipline
as before.

**Discipline establishment note for future sections.** This
section's DoD includes a methodology-run smoke test specifically
because the s008 → s009 → s010 sequence shipped a regression that
went undetected for three sections. The convention this brief
establishes: **any future section that touches commissioning,
tool-surface, role entrypoints, or the methodology spec must
include a methodology-run smoke in its DoD.** Document this
convention in the section report so the next handover carries it
forward.

Push the section branch to origin before discharge (Finding 35
discipline: brief explicitly mandates push). Architect handles
the section→main merge.
