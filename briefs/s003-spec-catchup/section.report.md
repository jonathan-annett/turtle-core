# s003-spec-catchup — section report

## Brief echo

Two doc-only items bringing the methodology and the substrate's own
history into alignment: (3.a) expand `deployment-docker.md` §9's
Claude-Code-authentication note to cover the dual-volume OAuth pattern,
rotation cadence, and the verify.sh refresh mechanism;
(3.b) retroactively file the SETUP-BRIEF discharge report under
`briefs/s000-setup/` with a sibling reconstructed brief, so the
substrate's own history aligns with the section-numbering convention
it enforces on managed projects.

## Per-task summary

### Task 3.a — deployment-docker.md §9 expansion

**Status:** done.

The previous §9 "Claude Code authentication" bullet referenced an
`architect-claude-state` named volume that does not match the
substrate's actual implementation (the compose file declares
`claude-state-architect` and `claude-state-shared`, both
`external: true` with fixed names; see `docker-compose.yml` lines
129–134). The bullet also did not document either the dual-volume
split or the OAuth-rotation refresh cadence — operationally critical
properties that the substrate ships with but the spec was silent on.

The new bullet covers:

1. **Dual-volume split:**
   - `claude-state-architect` — read/write at `/home/agent/.claude` in
     the architect; full `~/.claude/` (session, history, plugins).
   - `claude-state-shared` — at `/home/agent/.claude` in every
     ephemeral role (planner, coder-daemon, auditor); only
     `.credentials.json`, populated from the architect volume by a
     refresh helper.
2. **`external: true` with fixed names** so the volumes survive
   `compose down -v` of the per-pair ephemeral project — a routine
   teardown of a planner pair must not wipe the user's auth.
3. **OAuth rotation cadence** (every several hours) and the silent-
   fail mode it produces in ephemeral roles when the shared volume
   goes stale.
4. **Refresh mechanism:** a one-shot `debian:bookworm-slim` helper
   container with both volumes mounted that copies
   `.credentials.json` from architect → shared. Idempotent;
   re-running before each commission is safe. `verify.sh` is the
   canonical entry point (per the README "Refreshing ephemeral-role
   credentials" section).

The two-options framing (ANTHROPIC_API_KEY vs volume-shared OAuth) is
preserved; the bullet now states explicitly that volume-shared OAuth
is the substrate default and explains why an operator might prefer
either. The §5.1 cross-reference to `claude-code` install via apt is
preserved.

Diff: see commit `c3c2556`.

### Task 3.b — retroactive s000-setup filing

**Status:** done.

Moved `SETUP-BRIEF.report.md` from the repo root to
`briefs/s000-setup/section.report.md` via `git mv` (history preserved;
`git log --follow briefs/s000-setup/section.report.md` chains back to
the original commit `6318f34 add SETUP-BRIEF.report.md (discharge
report)`). Added a one-paragraph "Filing note (s003)" preamble at the
top of the moved file pointing readers at the move and explaining that
the report's body is verbatim historical text — references it makes to
"this file is at the repo root" are historical, not current.

Created `briefs/s000-setup/section.brief.md` as a retroactive
reconstruction. **The original `setup-scripts-brief.md` prompt text was
not located in the repository or in any artifact accessible to the
agent.** The reconstruction is therefore reverse-engineered from:
- The report's quoted brief sections (§1, §3, §4.1, §4.3, §4.5, §4.6,
  §4.10, §6, §7, §9 — only sections the report explicitly cites).
- The substrate as it actually exists on `main`.

Reconstruction caveats are stated explicitly at the top of the file:
- Sections the report does not cite are not invented (the original
  brief almost certainly had a §2 introduction and a §5 testing
  block; the report does not quote them, so this brief asserts no
  content for them).
- Where the report does not pin down original wording, the brief
  states what the substrate as committed *demonstrably implements*,
  not what the original brief might have asked for.
- Items the report flags as deliberate deviations are described as
  such, not retconned into the brief.

Updated dangling `SETUP-BRIEF.report.md` references in
`briefs/s001-tool-surface/section.report.md` (two occurrences in the
"Risks and open issues" subsection) to point at the new path.

Diff: see commit `b66e95f`.

## Verification

- `grep -rn 'SETUP-BRIEF' .` after the move surfaces references in
  exactly three files:
  - `briefs/s000-setup/section.report.md` — the moved file's own
    title, my preamble note, the historical tree-diagram, and a
    historical done-criteria checkmark. Disambiguated by the preamble.
  - `briefs/s001-tool-surface/section.report.md` — references updated
    to the new path.
  - `turtle-core-update.brief.md` — the meta-brief driving this work;
    its references to `SETUP-BRIEF.report.md` describe the *task* of
    moving the file, not a current pointer to it.
- `git log --follow briefs/s000-setup/section.report.md` returns two
  commits, confirming history was preserved through the rename.
- No reference to the old `SETUP-BRIEF.report.md` path resolves to a
  missing file (the only string-match in the repo is
  `turtle-core-update.brief.md`, which is the brief itself and
  describes the move it commissions).
- `methodology/deployment-docker.md` §9 now contains "dual-volume",
  "rotation", "verify.sh", and the correct volume names; the previous
  incorrect `architect-claude-state` reference is gone.

## Aggregate surface area

Files touched:
- `methodology/deployment-docker.md` — §9 Claude-Code-authentication
  bullet expanded.
- `briefs/s000-setup/section.brief.md` — created (retroactive
  reconstruction with explicit caveats).
- `SETUP-BRIEF.report.md` → `briefs/s000-setup/section.report.md` —
  moved with `git mv`; preamble note added.
- `briefs/s001-tool-surface/section.report.md` — two dangling-path
  references updated.

Files NOT touched:
- Any other §9 bullets in deployment-docker.md.
- README.md (it never referenced `SETUP-BRIEF.report.md`; verified by
  `grep -n SETUP-BRIEF README.md`).
- Other historical artifacts; the brief was explicit about scope being
  limited to SETUP-BRIEF.

## Risks and open issues

- **The reconstructed brief is not the original.** It is methodology-
  shaped and conservative, but a reader who needs to know what the
  human originally prompted will not find it here. The reconstruction
  caveats at the top of the brief say so explicitly. If the human
  later locates the original prompt, replacing the reconstruction
  with the verbatim original (and updating the preamble) would
  improve fidelity.
- **References inside the moved report (the body) still describe the
  file as living "at the repo root."** These are historical, not
  current — the preamble note disambiguates. Changing the body would
  mutate a discharge report and conflict with the reconstruction-
  conservative principle. Left intact.
- **§9 expansion may need a future cross-reference** to s001's §4.5
  (per-role invocation flags) once a planner / auditor / coder
  actually exercises the OAuth-shared-volume path end-to-end on a
  fresh host with token rotation in flight. Not yet exercised; future
  audit territory.

## Suggested next steps and dependencies for downstream sections

- s003 has no downstream dependencies inside this brief.
- A potential follow-up: lift the residual hazard around
  `generate-keys.sh` flagged in the s002 report ("running setup with
  an empty `infra/keys/` against a live substrate silently regenerates
  keys"). Out of scope for this update brief but a natural next
  section.
- A second potential follow-up: when a real planner+coder run
  exercises the new `parseToolSurface` daemon code (s001) and the
  expanded §9 OAuth refresh path together, an audit section to
  validate end-to-end behaviour on a fresh host would close the
  loop.

## Pointers to commits (in lieu of separate task reports)

- `c3c2556` — deployment-docker §9 OAuth refresh + dual-volume
  pattern (task 3.a).
- `b66e95f` — retroactively file SETUP-BRIEF under
  `briefs/s000-setup/` with reconstructed brief (task 3.b).
