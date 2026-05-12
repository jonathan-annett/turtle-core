# s014 — code migration agent smoke runbook

**Operator-driven, post-merge.** This runbook is shipped by Section B's implementing agent; the operator executes it against a freshly-set-up substrate after the s014 section branch is merged into main. The two phases together cover the code migration agent end-to-end and the deferred F50 four-role dance.

## Prerequisites

- A working host substrate. If you ran setup before s014 merged, re-run it so the new role image and the rebuilt git-server land:
  ```bash
  ./setup-linux.sh    # or ./setup-mac.sh
  ```
  Setup builds `agent-code-migration:latest` from `infra/code-migration/Dockerfile` and rebuilds `agent-git-server:latest` (whose entrypoint now loads the `code-migration` key). The s009 setup-time renderer also writes `Dockerfile.generated` for the existing roles.

- The host's claude-code authentication propagated into `claude-state-shared` (verify via `./verify.sh` if it's been a while since the last setup or the architect's OAuth has rotated — F48 staleness applies to the new role too).

- Anthropic API key in your shell environment (or `./onboard-project.sh` will fail at the first claude invocation):
  ```bash
  export ANTHROPIC_API_KEY=...
  ```

## Phase 1 — code migration agent end-to-end

This phase exercises the new three-phase onboarding flow: onboarder elicitation, code-migration dispatch, onboarder synthesis. The output is a populated handover at `briefs/onboarding/handover.md` whose section 3 carries the agent's structural findings.

### Setup

```bash
# Set ${UUID} to whatever value you want for the per-run substrate id
# capture below — used only by the F53-style restore note at the end
# of this section. Concrete value, not the placeholder syntax that
# bash interprets as input redirection.
UUID=$(cat .substrate-id)
echo "substrate UUID: ${UUID}"
```

### Run

```bash
# From a fresh substrate (main.git at the initial empty commit only;
# single-shot enforcement will refuse otherwise).
./onboard-project.sh infra/scripts/tests/fixtures/code-migration-smoke/ --type 1
```

Expected operator-visible flow:

1. **Source import** banner: `[onboard-import] pushed import commit.`
2. **Platform inference** banner: `[onboard] inferred platforms from /source: python-extras`.
3. **Onboarder image composition** banner: `[onboard] composing onboarder image...`.
4. **Phase 1 — interactive onboarder.** Claude opens an interactive session inside the onboarder container. Drive the elicitation:
   - Confirm the inferred platforms (`python-extras` only).
   - Provide minimal operator context — for a smoke run, "this is a synthetic fixture for testing the code-migration plumbing" is enough; the elicitation pass should stay short.
   - Confirm the migration brief and draft handover look right (the draft's section 3 should be the TODO placeholder).
   - Type `exit` (or Ctrl-D) to drop out of the bash-l shell once claude discharges.
5. **Phase 1 verification** banner: `[onboard] phase 1 outputs present: code-migration.brief.md, handover.draft.md.`
6. **Phase 2 — code-migration dispatch.** No operator interaction. Expected banners:
   - `[dispatch] verifying migration brief exists on main...`
   - `[dispatch] platforms: python-extras`
   - `[compose-image] ...` then `[dispatch] composed image: agent-code-migration-platforms:<hash12>`
   - `[dispatch] tool surface: ...`
   - `[dispatch] validating composed image against tool surface...`
   - `[dispatch] commissioning code-migration agent...`
   - (Agent runs autonomously; report-write progress in claude's stdout.)
   - `[dispatch] code-migration agent discharged; report committed at briefs/onboarding/code-migration.report.md.`
7. **Phase 3 — interactive onboarder again.** Claude opens a fresh session in a new onboarder container. The phase-3 prompt directs it to integrate the migration report's findings into section 3 of the handover. Confirm the integration looks reasonable; type `exit` when claude discharges.
8. **Phase 3 verification** + architect restart + next-step banner pointing at `./attach-architect.sh`.

### Verification checklist

After `./onboard-project.sh` returns:

```bash
# All three onboarding artifacts present on main:
docker exec agent-architect git -C /work fetch -q origin main
docker exec agent-architect git -C /work cat-file -e origin/main:briefs/onboarding/code-migration.brief.md
docker exec agent-architect git -C /work cat-file -e origin/main:briefs/onboarding/code-migration.report.md
docker exec agent-architect git -C /work cat-file -e origin/main:briefs/onboarding/handover.md

# Migration report has the six required headings:
docker exec agent-architect git -C /work show origin/main:briefs/onboarding/code-migration.report.md | \
    grep -E '^## [1-6]\. (Brief echo|Per-component intent|Structural completeness|Findings|Operational notes|Open questions)$' | wc -l
# Expect: 6

# Migration report surfaces the expected findings:
docker exec agent-architect git -C /work show origin/main:briefs/onboarding/code-migration.report.md | \
    grep -iE 'requestz|orphan'
# Expect: at least one match for each — the typo'd dependency and the orphan file.

# Handover section 3 is no longer the phase-1 TODO placeholder:
docker exec agent-architect git -C /work show origin/main:briefs/onboarding/handover.md | \
    grep 'TODO: code migration agent dispatching'
# Expect: NO match (phase 3 should have replaced the placeholder).

# Handover section 3 references the migration report by path:
docker exec agent-architect git -C /work show origin/main:briefs/onboarding/handover.md | \
    grep 'briefs/onboarding/code-migration.report.md'
# Expect: at least one match.
```

### Attach architect and confirm bootstrap

```bash
./attach-architect.sh
```

Inside the architect's claude session, observe that the first-attach bootstrap fired against the handover (the entrypoint logs "Onboarding handover detected" and seeds the architect with the handover's contents). The architect's first prompt should already know about the structural findings from the agent's report. Detach (Ctrl-P Ctrl-Q) when satisfied.

### Restore note (per F53)

If you need to tear the smoke down and try again:

```bash
docker compose --profile ephemeral down -v --remove-orphans
docker volume rm claude-state-architect claude-state-shared 2>/dev/null || true
docker volume ls -q | xargs -r docker volume rm 2>/dev/null || true
# Then re-run setup against substrate ${UUID} or with --adopt-existing-substrate.
```

## Phase 2 — F50 four-role dance (deferred from s013)

This phase exercises the full platform-composition path through commission-pair.sh + audit.sh — the methodology-run smoke that s013's T11 deferred. Folding it into B's smoke per the s013 handover's recommendation (b) is economical: the new code-migration role is the natural consumer of F50, and s013's infrastructure tests already cover composition mechanics exhaustively in isolation.

### Setup

Either:
- **Synthetic source** — re-run phase 1's smoke and then continue with the architect drafting a `TOP-LEVEL-PLAN.md` declaring `## Platforms: [python-extras]`, plus a section brief with `Required platforms: [python-extras]`. The architect can ratify the candidate from the handover.
- **Real source** — if hello-turtle (or another real project) has grown a platform-declaring section by the time this smoke runs, use that instead.

### Run

1. Architect commits `TOP-LEVEL-PLAN.md` and `briefs/sNNN-<slug>/section.brief.md` to main (the existing s013 pattern; the architect-guide's "Decomposing a multi-platform project" subsection covers the shape).
2. Operator runs:
   ```bash
   ./commission-pair.sh sNNN-<slug>
   ```
3. Operator observes the planner-pair come up. Verify each role's image carries python-extras:
   ```bash
   docker exec <pair-planner-container> bash -lc 'command -v ruff && python3 --version'
   docker exec <pair-coder-daemon-container> bash -lc 'command -v ruff && python3 --version'
   ```
4. Run the section to audit-pass (operator-mediated planning + coding).
5. After the section report lands and the architect writes the audit brief, run:
   ```bash
   ./audit.sh sNNN-<slug>
   ```
6. Verify the auditor's image also carries python-extras (same shape as the planner check).

### Expected outcomes

- Each role's image is `agent-<role>-platforms:<hash12>` (not `agent-<role>:latest`).
- All three roles (planner, coder-daemon, auditor) have python-extras tooling on PATH.
- `validate-tool-surface.sh` runs at commission time and passes; brief authors don't see the s011 spurious-deny class of bugs.

### Restore note

```bash
docker compose -p <pair-project> --profile ephemeral down -v --remove-orphans
```

per-pair compose project; cleanup is local to that pair.

## What this smoke does NOT exercise

- The history migration agent (Section C territory).
- Cross-substrate or cross-host migration.
- Real-claude survey quality on a complex real project — both phases use either a synthetic fixture (phase 1) or a small section (phase 2). The first real-project run waits for Section C.

## Reporting back

Capture operator notes from the actual run in a follow-up document (do not amend the section report — that's frozen at section-merge time). Suggested path: `briefs/s014-code-migration-agent/smoke-operator-notes.md`, but not load-bearing — anywhere the next chat-Claude instance can find it works.
