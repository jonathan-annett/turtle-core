# turtle-core update brief — adopt-fix

## What this is

A follow-up to s004 (substrate identity sentinel). The
`substrate_id_adopt` flow shipped in s004 has a real bug, surfaced
during operator-side adoption on hello-turtle: the architect container
is stopped before the `claude-state-architect` volume is removed, but
stopped-but-not-removed containers still hold volume references, so
`docker volume rm` fails.

The script bailed cleanly when this happened — diagnostic preserved,
original volume untouched, scratch volume held the data. Manual
recovery (remove the stopped container, then rerun the remaining steps)
completed the rotation successfully; the substrate is now sealed
(`7eb785ba-fefe-4d11-8f76-3c26d4c0bf43`), verify.sh 10/10, Path A
re-synced.

The substrate-identity flow itself is correct. Only the
container-removal step needed fixing.

This brief packages the fix as one section, **s005-adopt-fix**.

---

## Recommendations baked in (override before dispatch)

Three calls. Each flagged below; edit before dispatch to override.

1. **Use `docker compose rm -f architect` after the existing `stop`,
   rather than restructuring the flow.** Smaller diff, easier to
   review, preserves the existing structure of `substrate_id_adopt`.
   `-f` skips the confirmation prompt. The preceding
   `docker compose stop architect` already halts the container, so
   `rm`'s `-s` (stop first) flag is redundant. This pattern matches
   the operator-verified manual recovery (`docker rm agent-architect`
   on the stopped container, then volume rm succeeded).

   Considered alternatives: (a) `rm -sf` for defensive insurance against
   the stop step somehow not completing — rejected as redundant given
   the immediately preceding stop; (b) replace the `stop` + volume-rm
   pair with `docker compose down --no-volumes` scoped to the architect
   service — equivalent effect, rejected on diff size.
   **Override:** specify `rm -sf` or the `down --no-volumes` approach.

2. **Extend the existing test harness rather than adding a new file.**
   `infra/scripts/tests/test-substrate-identity.sh` already has
   per-scenario scaffolding (pid-suffixed scratch volumes, etc.). The
   regression scenario for this bug fits naturally as another scenario
   in that harness.

   Considered alternative: separate test file dedicated to adoption
   regression. Rejected as fragmenting test coverage of the same flow.
   **Override:** request a separate file.

3. **Let s005's section report stand alone; do not retroactively edit
   s004's report.** Cleaner audit trail — each section's report
   reflects what was known at the time. The s005 report links the bug
   back to s004 in its brief echo and summary; that's discoverability
   enough.

   Considered alternative: append a loop-closing note to s004's
   residual-hazards section. Rejected on audit-trail cleanliness.
   **Override:** request the s004-report update.

---

## Top-level plan

**Goal.** Fix the `--adopt-existing-substrate` flow so volume rotation
completes without operator intervention.

**Scope.** One section, single bug fix plus regression test plus
optional s004-report update.

**Sequencing.** Execute after s004 has settled (it has).

**Branch.** `section/s005-adopt-fix` off `main`.

---

## Section s005 — adopt-fix

### Section ID and slug

`s005-adopt-fix`

### Objective

Eliminate the manual-intervention step in `substrate_id_adopt` by
removing (not just stopping) the architect container before the volume
rm. Add a regression scenario reproducing the original failure
prerequisite.

### Available context

The bug was hit during operator-side adoption on hello-turtle. The
sequence in `substrate_id_adopt` (probably in `setup-common.sh`, called
from `setup-linux.sh` / `setup-mac.sh` via `--adopt-existing-substrate`):

1. `docker compose stop architect`
2. (data preservation into scratch volume — works)
3. `docker volume rm claude-state-architect` — **fails here**
4. Volume recreation with new label — never reached
5. Restore data from scratch volume — never reached
6. Start architect — never reached

Cause: `docker compose stop` halts the container but doesn't remove
it. The stopped container still has a reference to the volume, which
prevents `docker volume rm` from succeeding.

Manual recovery (operator-confirmed): `docker compose rm -f architect`,
then rerun the remaining adoption steps. Worked first time; volume
rotated correctly, data preserved, substrate-id sealed. The fix
codifies that recovery into the script.

### Tasks (informal decomposition)

The agent may decompose differently, but this is the suggested order.

**5.a — Locate `substrate_id_adopt`.**

Likely in `setup-common.sh` (the shared setup body). If the function
is split or duplicated across `setup-linux.sh` / `setup-mac.sh` /
`setup-common.sh`, identify all call sites and apply the fix
consistently.

**5.b — Insert container removal between stop and volume rm.**

Immediately after the existing `docker compose stop architect`, add:

```bash
docker compose rm -f architect
```

`-f` skips the confirmation prompt. `-s` (stop first) is not needed:
the preceding `stop` has already halted the container. The command is
idempotent — if the container is already removed (e.g., adoption is
being re-run after a partial completion), `rm -f` succeeds without
effect.

**5.c — Add a regression scenario to the test harness.**

In `infra/scripts/tests/test-substrate-identity.sh`, add a scenario
that:

1. Sets up the adoption precondition (volume present, no
   `.substrate-id` on disk).
2. Stops the architect container *without removing it* — this is the
   key step that mimics a real adoption from a running substrate.
3. Runs `--adopt-existing-substrate`.
4. Asserts the adoption completed: `.substrate-id` exists, volume has
   the matching label, container is running again.

Use the harness's existing pid-suffixed scratch-volume pattern for
isolation. Follow the conventions of the existing scenarios.

### Constraints

- The fix must not alter the data-preservation logic. Data goes into
  the scratch volume and back into the recreated volume, the same way
  s004 designed it.
- The fix must remain idempotent. Re-running the adoption after a
  partial failure should still complete cleanly.
- No changes to role Dockerfiles, daemon.js, or methodology docs. This
  is a substrate-only bug fix.
- All existing scenarios in `test-substrate-identity.sh` must continue
  to pass after the new scenario is added.

### Definition of done

- `substrate_id_adopt` removes the architect container before
  attempting `docker volume rm`.
- Running `--adopt-existing-substrate` against a substrate with a
  running architect completes without manual intervention.
- The test harness has a new scenario reproducing the original failure
  prerequisite, and that scenario passes.
- All previously existing test scenarios still pass.
- Section report at `briefs/s005-adopt-fix/section.report.md`
  including: brief echo, summary of fix, which `substrate_id_adopt`
  site(s) were modified, test output for the new scenario plus all
  existing scenarios, residual hazards (if any).

### Out of scope

- Other unrelated bugs the agent might notice in setup scripts. Flag
  them in the section report; don't fix.
- Refactoring `substrate_id_adopt` or the surrounding flow beyond the
  targeted insertion.
- README / troubleshooting changes. The existing entries cover
  adoption pathologies generically; no specific entry needed.
- Generalizing the fix into a "stop and remove" helper. The one-line
  insertion is fine.

### Repo coordinates

- Base branch: `main`.
- Section branch: `section/s005-adopt-fix`.
- Task branches from there per spec §6 (likely a single task branch).

### Reporting requirements

Section report at `briefs/s005-adopt-fix/section.report.md` on the
section branch. Must include:

- Brief echo.
- Summary of the fix (one paragraph).
- Confirmation of which `substrate_id_adopt` site(s) were modified.
- Test output for the new regression scenario.
- Test output (pass/fail) for all existing scenarios in
  `test-substrate-identity.sh`.
- Any residual hazards spotted during the work.

---

## Execution

Single agent on the host (same pattern as s001–s004). The fix is small
and surgical; the agent should land it in one or two commits and
discharge.

If the agent finds genuine ambiguity (e.g., `substrate_id_adopt` turns
out to live in multiple places that don't share a single
implementation, or the harness pattern doesn't accommodate the new
scenario cleanly), surface it in the section report and note what was
done — don't "brief insufficient" / discharge for a fix this small.
