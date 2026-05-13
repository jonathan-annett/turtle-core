# s014 — Code migration agent: section report

## Brief echo

Section B of the migration-onboarding machinery (A → F50 → B → C). Adds the **code migration agent** as a sub-agent of the onboarder: a single-shot, ephemeral role dispatched once per brownfield onboarding to perform structural review of `/source` (lint, syntax, dependency resolution, import-graph closure, orphan-file / stale-directory detection — **not** build, not behavioural test). Its output is a severity-graded, descriptive-not-gate-shaped survey report at `briefs/onboarding/code-migration.report.md` that the onboarder folds into section 3 of the handover brief. Adjacent additions: the role's container, compose service, keypair, git-server hook clause, dispatch helper, migration brief and report templates, onboarder integration that turns brownfield onboarding into a three-phase flow, spec bump to v2.5 with the platform-composition paragraph extended for the new role, and an infrastructure plumbing test with a synthetic Python fixture.

The override-during-implementation latitude was used three times during initial + amendment implementation (B.6 host-side dispatch, B.4 python-extras YAML ride-along, B.11 option (a) vs (b)) and twice in post-merge stabilisation as the operator-driven hotfix path (F60 accepted as-is, F61 polished from operator's first cut). Everything else hewed to the brief's recommendations as written. Full enumeration in the "Override-during-implementation deviations and operator-driven post-merge fixes" section below.

## Per-task summary

### B.1 — Code migration agent role guide

`methodology/code-migration-agent-guide.md`. Parallels the existing role guides in shape but adapted for the sub-agent-of-onboarder scope: structural review only, no behavioural testing, no further sub-agent dispatch, single-shot, survey-feedstock report. Severity legend HIGH / LOW / INFO matches `FINDINGS.md` but framed "for the architect's attention" rather than gate-shaped. Confidence-calibration markers (Confirmed / Inferred / Speculative) carry across from the onboarder-handover-template.

Commit: `0a6e763`.

### B.2 — Migration brief & report templates

Two "must contain" specifications:

- `methodology/code-migration-brief-template.md` — six sections (Objective, Available context, Required platforms, Required tool surface, Output destination, Reporting requirements). Same shape as section/audit briefs (§7.2, §7.6) so the agent's brief-reading contract is uniform across commissioning events. Required-platforms field documented as **authoritative on its own** rather than subset-of-superset (the migration brief is authored before TOP-LEVEL-PLAN.md exists).
- `methodology/code-migration-report-template.md` — six sections (Brief echo, Per-component intent, Structural completeness, Findings, Operational notes, Open questions). Shape differs from §7.5 section-report (survey feedstock, not work-completed).

Both are documented as "must contain" rather than fillable form, per design call 7.

Commit: `ed890fa`.

### B.3 — Container

`infra/code-migration/Dockerfile` (FROM agent-base + `# PLATFORM_INSERT_HERE` sentinel) and `infra/code-migration/entrypoint.sh`. The entrypoint mirrors planner/auditor in shape: clones main.git into /work, parses the migration brief's "Required tool surface" via the shared `parse-tool-surface.sh` (bind-mounted at `/usr/local/lib/turtle-core/parse-tool-surface.sh`), invokes claude in `-p` mode (design call 5) with `--permission-mode dontAsk + --allowed-tools`. Symlinks `/methodology/code-migration-agent-guide.md` as `/work/CLAUDE.md` so the role anchor loads automatically.

Commit: `f7becd2`.

### B.4 — Compose service, keypair, git-server clauses

A six-file substrate-plumbing change to make the new role first-class:

- `docker-compose.yml` — new `code-migration` service in `ephemeral` profile with `CODE_MIGRATION_IMAGE` env override (s013 F50 pattern). Mirrors the onboarder/auditor shape; volumes include `claude-state-shared`, `/methodology` read-only, the `code-migration` keypair, `/source` from `SOURCE_PATH` env, and the parse-tool-surface.sh bind mount.
- `infra/scripts/generate-keys.sh` + `setup-common.sh` — `code-migration` added to the roles array and the keys-directory mkdir list.
- `infra/git-server/entrypoint.sh` — `code-migration` added to the authorized-keys loop.
- `infra/git-server/hooks/update` — new `code-migration` case. Refs restricted to `refs/heads/main` only, paths restricted to exactly `briefs/onboarding/code-migration.report.md`. Distinct from the onboarder's path-unrestricted clause (F57): code-migration touches one file so the hook can be strict. `auditor.git` deny list extended to mention code-migration explicitly.
- `infra/scripts/{render-dockerfile,compose-image}.sh` + `infra/scripts/lib/validate-platform.sh` — role allowlists extended with `code-migration`.
- `methodology/platforms/python-extras.yaml` — new `code-migration` role block installing `ruff` and `mypy` (plus python3-venv + pip from the venv) on the code-migration image. Survey-grade probes only; no test runner, no project build tooling. The YAML edit invalidates any cached hashes from prior python-extras compositions per s013's hash-by-file-bytes semantics, but the rebuild produces byte-equivalent content for non-code-migration roles — harmless beyond a one-time cache miss.

Commit: `e0ca613`.

### B.5 — Dispatch helper

`infra/scripts/dispatch-code-migration.sh`. Host-side dispatcher (see B.6 override note for why). Inputs: source path (via `SOURCE_PATH` env or `--source-path` flag), substrate containers (verified running via `is_running`). Flow:

1. Reads migration brief from the architect's `/work` clone (same pattern as `check-brief.sh`).
2. Resolves platforms via `parse-platforms.sh` directly (the brief's field is authoritative on its own — see Section 9.5 of the spec amendment for the platform-resolution asymmetry).
3. Composes a hash-tagged `agent-code-migration-platforms:<hash12>` image via `compose-image.sh`.
4. Validates the brief's tool surface against the composed image via `validate-tool-surface.sh` (F52 closure).
5. Sets a deterministic `BOOTSTRAP_PROMPT` (canonical code-migration commissioning prompt; see below).
6. Runs the agent via `docker compose -p <project> --profile ephemeral run --rm code-migration` with `BRIEF_PATH` env to bypass heuristic path extraction.
7. Verifies the report exists on `origin/main` after the agent discharges.
8. Tears down the compose project on cleanup.

Exit codes: 0 success, 1 substrate/brief errors, 2 bad args, 3 agent ran but failed to produce a report.

Commit: `5dd501f`.

### B.6 — Onboarder integration

Largest task. Four files:

- `infra/scripts/infer-platforms.sh` — new heuristic platform-inference helper. Walks canonical signal files at the source root (`package.json`, `requirements.txt` / `pyproject.toml` / `setup.py`, `Cargo.toml`, `go.mod`, `platformio.ini`, `CMakeLists.txt`, standalone `Makefile`) and emits a comma-separated CSV. Standalone `Makefile` triggers `c-cpp` only when no other signal fires (else it's likely a wrapper for a language-specific build).
- `onboard-project.sh` — new `--platforms=<csv>` flag (independent of `--type`). New multi-phase orchestration: phase 1 (interactive onboarder writes migration brief + draft handover at `briefs/onboarding/handover.draft.md`), phase 2 (host runs `dispatch-code-migration.sh`), phase 3 (fresh interactive onboarder reads draft + migration report, writes final `briefs/onboarding/handover.md`). The draft path differs from canonical `handover.md` so the architect's first-attach detection (s012 A.6) does not fire prematurely.
- `methodology/onboarder-guide.md` — rewritten "How you work", "Sub-agent naming convention", and "Lifecycle from your seat" sections to reflect the three-phase flow. Section 3 description flipped from "future code migration agent" to phase-3 fill-in-from-report. Section 4 (history review) stays "future" (Section C ships it).
- `methodology/onboarder-handover-template.md` — section 3 description rewritten to specify the phase-1 placeholder + phase-3 fill-in flow, the migration-report integration shape (per-component intent / structural completeness / findings / reference), and the cross-integration discipline (operational notes and open questions feeding back into other handover sections).

Commit: `7b81ada`.

#### Override-during-implementation (s013 pattern)

The section B brief at B.6 reads "the dispatch call" as sitting inside the onboarder's entrypoint. The clean alternative is to keep dispatch host-side (mirroring `audit.sh` / `commission-pair.sh`, all host-orchestrated) and let `./onboard-project.sh` drive the multi-phase flow. This avoids mounting `/var/run/docker.sock` into the onboarder container — a real privilege elevation we don't otherwise need. The trade-off is splitting the onboarder's interactive work across two containers (phase 1 and phase 3); persistent state lives in `/work` (the project clone) across the phases. Operator's interactive experience is split, but explicitly so: phase 1 is "elicitation + migration brief", phase 3 is "synthesis + handover" — content-aligned phases rather than arbitrary cut.

### B.7 — Spec updates v2.4 → v2.5

`methodology/agent-orchestration-spec.md`:

- Top: new v2.5 changelog entry summarising the code-migration sub-agent addition.
- §3.3 access table: new `code-migration` row. Reads /source + main repo; writes ONLY `briefs/onboarding/code-migration.report.md` on `refs/heads/main`; no auditor-repo access.
- §4 Onboarder: refreshed sub-agent collaboration paragraph (flips "future" → "active" for the code migration agent; history migration agent stays "not yet shipped").
- §4 new role section "Code migration agent": sub-agent scope, read-only /source mount, platform composition via the migration brief, structural-review-only activity profile, severity-graded for-architect's-attention findings (not gate-shaped), single-shot, path-restricted write access.
- §7.9 Migration brief (onboarder → code migration agent): pointer to `methodology/code-migration-brief-template.md` with field summaries.
- §7.10 Migration report (code migration agent → onboarder): pointer to `methodology/code-migration-report-template.md` with section summaries.
- §8 step 0: three-phase enumeration (phase 1 elicit + commission; phase 2 dispatch; phase 3 integrate + finalise).
- §9 "Platform composition" paragraph (the B.7 amendment from the dispatch chat): refactored from "applies uniformly" prose to a role-by-role enumeration covering planner/coder-daemon/auditor (section-brief subset semantics), onboarder (empty set by design), and the new code migration agent (authoritative migration-brief field, no subset enforcement).

Commit: `658fbca`.

### B.8 — Infrastructure test + smoke fixture

Two artifacts in one commit:

- `infra/scripts/tests/fixtures/code-migration-smoke/` — 5-file synthetic Python fixture. `requirements.txt` carries the deliberate `requestz` typo (HIGH-finding bait), `pyproject.toml` is a minimal PEP 518 manifest, `smoke/main.py` imports `smoke/greeting.py` (clean import pair), `smoke/orphan.py` is the deliberate orphan (LOW-finding bait), plus a README explaining the fixture's purpose and the expected findings.
- `infra/scripts/tests/test-code-migration.sh` — full plumbing test paralleling s012's `test-onboarder-shell.sh`. 37 assertions across 10 phases. Stub-claude handles `-p` mode invocation (F56 generalisation note) by ignoring all args and just writing the canonical six-section report.

Test run: **37/37 PASS** (transcript at `briefs/s014-code-migration-agent/test-code-migration.transcript`).

Regression suites: s011 `test-parse-tool-surface.sh` **15/15 PASS**; s013 `test-platform-composition.sh` **26/26 PASS**.

The test required rebuilding `agent-git-server` (B.4 entrypoint.sh change) and building `agent-code-migration:latest` (new in s014). The setup-linux/setup-mac path rebuilds these as part of ordinary setup; a stale pre-s014 substrate needs `./setup-linux.sh` re-run before the test passes — documented in the test's prereq phase.

Commit: `7c1b2cf`.

### B.9 — Smoke runbook

`briefs/s014-code-migration-agent/smoke-runbook.md`. Operator-driven, post-merge two-phase runbook:

- **Phase 1** — code migration agent end-to-end. Operator runs `./onboard-project.sh infra/scripts/tests/fixtures/code-migration-smoke/`, observes the three-phase orchestration, verifies all four onboarding artifacts (import commit, migration brief, migration report, final handover) land on main, and checks that the handover's section 3 references the migration report and names the fixture's deliberate findings (`requestz`, orphan).
- **Phase 2** — F50 four-role dance (deferred from s013 per the s013 handover's recommendation b). Architect drafts a platform-declaring `TOP-LEVEL-PLAN.md` and section brief; operator runs `commission-pair.sh` and `audit.sh` and verifies the planner / coder-daemon / auditor images carry the declared platforms.

The fixture itself is owned by B.8's commit (the test depends on it); B.9 ships the runbook only.

Used `${UUID}` placeholder syntax per F53 (bash interprets `<placeholder>` as input redirection).

Commit: `78d891e`.

### B.10 — Documentation updates

- `methodology/deployment-docker.md`: version reference v2.3 → v2.5. §1 "six-container model" → "seven-container model" with code-migration row added. §6.4 onboarding workflow rewritten end-to-end to describe the new three-phase flow, including the canonical phase-1 / phase-3 / code-migration bootstrap prompts. "Why dispatch is host-side" rationale paragraph added.
- `README.md`: tagline mentions the code-migration sub-agent. Container table grows a code-migration row. Brownfield quickstart rewritten for three-phase flow + `--platforms=<csv>` flag + `--type` / `--platforms` independence note. Onboarder commissioning section restructured to the 8-step phase-annotated flow. Role-lifecycle one-liner updated. Layout tree includes `infra/code-migration/`, `dispatch-code-migration.sh`, `infer-platforms.sh`. Pointers section gains the agent-guide and the two migration templates.

Commit: `ef979c6`.

## Canonical code-migration bootstrap prompt (reference)

Set by `infra/scripts/dispatch-code-migration.sh`. Becomes the methodology's reference for code-migration commissioning, parallel to s008's planner/auditor prompts and s012's onboarder prompt:

> Read /work/briefs/onboarding/code-migration.brief.md, which is your migration brief. Read /methodology/code-migration-agent-guide.md (symlinked as /work/CLAUDE.md) and /methodology/code-migration-report-template.md for your operating boundaries and report shape. The brownfield source materials are at /source (read-only). Perform structural review per the brief — survey, do not build or run the project. Produce the migration report at /work/briefs/onboarding/code-migration.report.md following the six-section structure in the template. When the report is complete, commit with the exact message 'onboarding: code-migration report', push to origin main, and discharge.

## Canonical onboarder phase-1 and phase-3 bootstrap prompts (reference)

Set by `./onboard-project.sh`. Both phases run interactive (no `-p`, F56) — the operator is in the loop. Full text of both is in `methodology/deployment-docker.md` §6.4 and matches the prompt strings hard-coded into `onboard-project.sh`'s `bootstrap_prompt_phase_1` and `bootstrap_prompt_phase_3` variables.

## Dispatch-helper shape (reference for future similar helpers)

`infra/scripts/dispatch-code-migration.sh`:

- **Inputs.** `SOURCE_PATH` env (or `--source-path` flag). `ARCHITECT_CONTAINER` + `GIT_SERVER_CONTAINER` env overrides for tests. `DISPATCH_COMPOSE_PROJECT` env override for ephemeral compose-project naming.
- **Outputs.** Composed image emitted on stdout by `compose-image.sh`; informational logs on stderr prefixed `[dispatch]`. Exit code per success/error.
- **Exit code semantics.** 0 success, 1 substrate/brief errors (substrate not up, missing brief, malformed brief), 2 bad args, 3 agent ran but failed (agent container exited non-zero or report not committed).
- **Cleanup.** `trap`-on-exit tears down the ephemeral compose project. The bare-repo on the long-lived `git-server` is preserved (the report committed there is the durable artifact).

## Inference-helper shape (reference)

`infra/scripts/infer-platforms.sh <source-dir>`:

Signals (project-root markers; subdirs deliberately NOT walked):

| Signal file at root            | Inferred platform     |
| ------------------------------ | --------------------- |
| `package.json`                 | `node-extras`         |
| `requirements.txt`             | `python-extras`       |
| `pyproject.toml`               | `python-extras`       |
| `setup.py`                     | `python-extras`       |
| `Cargo.toml`                   | `rust`                |
| `go.mod`                       | `go`                  |
| `platformio.ini`               | `platformio-esp32`    |
| `CMakeLists.txt`               | `c-cpp`               |
| `Makefile` (no other signal)   | `c-cpp`               |

Returns the CSV on stdout (empty is a legitimate output). Inference is heuristic and intentionally conservative; the operator confirms / corrects during phase-1 elicitation, and `--platforms=<csv>` bypasses inference entirely.

## Migration brief template section headings (reference)

From `methodology/code-migration-brief-template.md`:

1. `## Objective`
2. `## Available context`
3. `## Required platforms`
4. `## Required tool surface`
5. `## Output destination`
6. `## Reporting requirements`

## Migration report template section headings (reference)

From `methodology/code-migration-report-template.md`:

1. `## 1. Brief echo`
2. `## 2. Per-component intent`
3. `## 3. Structural completeness`
4. `## 4. Findings`
5. `## 5. Operational notes`
6. `## 6. Open questions`

## Spec diff (v2.4 → v2.5)

| Section | Change |
|---|---|
| Top | New v2.5 changelog entry. v2.4 preserved. |
| §3.3 | New `code-migration` row in the access table. |
| §4 Onboarder | "Sub-agents" paragraph refreshed: code migration agent flipped to **active**; history migration agent stays "not yet shipped". New paragraph noting onboarder runs across two operator-facing phases (1 and 3). |
| §4 (new) | New "Code migration agent (ephemeral, sub-agent of onboarder, one per onboarding)" role section. |
| §7.9 (new) | Migration brief artifact entry. |
| §7.10 (new) | Migration report artifact entry. |
| §8 step 0 | Single paragraph replaced with three-phase enumeration (phase 1 elicit, phase 2 dispatch, phase 3 integrate). |
| §9 | "Platform composition" paragraph refactored from uniform-applies prose to a role-by-role enumeration covering the new code-migration agent's authoritative-brief-field semantics (no project superset to subset against at onboarding time). |

## Override-during-implementation deviations and operator-driven post-merge fixes

Five items, covering the full arc from initial implementation through amendment to post-merge stabilisation. Items 1-3 are implementing-agent override-during-implementation calls (the s013 pattern — "cleaner move found mid-flight, document in section report"). Items 4-5 record the operator's direct contribution to the section's stabilisation via the post-merge hotfix path, in the same convention.

1. **B.6 dispatch hosting (host-side, not in-onboarder).** The brief reads "the dispatch call" as sitting inside the onboarder's entrypoint. Host-side dispatch via `./onboard-project.sh` avoids mounting `/var/run/docker.sock` into the onboarder container (real privilege elevation). Trade-off: split-phase interactive UX. Recorded as F63 (informational design call) for future-implementer discoverability. Detail in B.6 above.

2. **B.4 platform-YAML ride-along.** The brief's B.4 enumeration doesn't mention platform-YAML edits, but `methodology/platforms/python-extras.yaml` needed a `code-migration` role block for the smoke fixture's Python case to actually compose a useful image (otherwise the agent's tool surface — `pip`, `ruff`, `mypy` — would fail validation against an empty image). Added it as a one-platform ride-along, scoped to the smoke-relevant case; other ship-with platforms (node-extras, rust, go, platformio-esp32, c-cpp) can grow code-migration blocks when their first onboarding consumer surfaces.

3. **B.11 (amendment) — option (a) over option (b).** The amendment offered two suggested shapes for the F59 fix: (a) external network reference, (b) run onboarder in the long-lived project namespace with `--profile onboard`. Picked option (a) — which turned out to reduce to "delete two lines" once I noticed `agent-net` was already declared `external: true` and every other ephemeral role was already using it correctly. Option (b) would have required changes to `attach-architect.sh`, the cleanup logic in `onboard-project.sh`, and the compose-project-namespace convention — for no concrete win. Detail in Amendment section below.

4. **F60 hotfix accepted as-is from operator** (`2bd7652`). The B.5 implementation shipped a real path-resolution typo (`/..` should have been `/../..` for a script at `infra/scripts/`). Operator hit it in the post-merge smoke and authored a clean single-character fix. Polish review accepted it as-is — the fix is mechanically correct and there's nothing to refine. Records the operator's substrate-iteration participation: when the implementing agent ships a bug that surfaces only in real-substrate context, the operator's mid-merge fix is a legitimate path that the section can then incorporate via a polish-and-FINDINGS-entry commit rather than re-routing through a fresh substrate-iteration brief.

5. **F61 hotfix polished from operator's first-cut** (`2bd7652` → `f157da9`). The operator's hotfix added `git fetch + git pull` between the phase-2 banner and the dispatch invocation — correct in intent, but with three small issues: hardcoded `agent-architect` (breaks test-fixture overrides), redundant fetch (phase-1 verification just did one), silent pull failure (`&&` short-circuits on fetch failure but not on pull failure). Polished to use `${arch_container}`, single `git pull --ff-only -q origin main` consolidated into the phase-1 verification block (the logical home: "verification" should fully sync /work, not just refs), and fail-loud with a clear diagnostic. Behaviour identical on the working path; clarity improved on the error path. Same convention as item 4: operator's fix lands, implementing agent polishes for substrate consistency, FINDINGS entry captures the mechanism. The two-step pattern (operator-cut → polish) is itself worth recording — it's faster than gating every post-merge fix on a fresh substrate-iteration chat session, and the operator's first cut is what proves the fix shape correct before the polish refines it.

**Pattern note.** Items 4 and 5 establish a precedent: post-merge smoke surfaces a bug, operator authors a hotfix commit on the same section branch, implementing agent reviews and refines (or accepts as-is) plus adds the FINDINGS entry leading with the mechanism. The branch stays open for this collaboration; merge to main happens after the polish lands. The s013 convention extends naturally to this pattern — "override-during-implementation" generalises to "deviation from brief or initial implementation, captured at section close" — and Section C should expect a similar arc.

## Test transcript

Captured at `briefs/s014-code-migration-agent/test-code-migration.transcript`. Headline: **37/37 PASS**. Regression suites s011 (15/15) and s013 (26/26) confirmed green during the same session.

## Smoke runbook

`briefs/s014-code-migration-agent/smoke-runbook.md`. Operator runs this post-merge — phase 1 covers the new three-phase onboarding end-to-end with real claude against the synthetic fixture; phase 2 covers the F50 four-role dance deferred from s013. The operator's notes from the actual run go in a follow-up document, not this section report.

## Residual hazards

1. **Two-phase onboarder interactive UX is novel.** The operator now experiences two distinct claude sessions (phase 1 and phase 3) bracketing an autonomous dispatch. The phase-1/phase-3 prompts make the boundary explicit, and the architect's first-attach detection key (`handover.md` file presence + absence of SHARED-STATE.md) is unchanged — but operators familiar with the s012 single-session flow will notice the split. Worth mentioning prominently in any operator-facing announcement.

2. **claude-state-shared staleness (F48) applies to the new role.** The code-migration agent reads OAuth credentials from `claude-state-shared`, populated from the architect's volume by setup / verify. If the architect's OAuth has rotated since setup last ran, the agent will commission against stale creds and fail. The B.10 docs note this; operators should run `./verify.sh` before invoking an onboarding if it's been a few hours since the last refresh.

3. **The python-extras YAML edit invalidates cached image hashes globally for any role that uses python-extras.** Documented in B.4's commit and harmless beyond a one-time cache miss (the rebuild is byte-equivalent for non-code-migration roles), but worth a note for the operator's expectations the first time they re-run setup or compose-image after merging s014.

4. **Phase-1 / phase-3 conversation state is not preserved across containers.** The operator's elicitation responses from phase 1 must end up in committed artifacts (the migration brief, the draft handover) for phase 3 to see them — claude-state-shared carries auth, not session history. Phase 1's draft handover serves as the carrier; phase 3's prompt directs it to read the draft as starting truth. The risk class is "operator says something to phase-1 claude that doesn't make it into the brief or draft handover, then phase-3 claude can't recover it." Mitigations: the onboarder-guide tells phase-1 claude to capture operator context in the draft handover's relevant sections (5/7/8/9); phase 3's prompt directs claude to re-confirm with the operator only as a light pass, not a full re-elicitation.

## Open questions for the next chat-Claude instance

1. **Section C scoping.** When Section C (history migration agent) lands, it will follow the same sub-agent pattern: a fourth phase between phase 1 and phase 3 (or alongside the code-migration phase 2 if they can dispatch in parallel — they survey orthogonal materials). Worth deciding before designing C whether the dispatches are sequential or parallel; current substrate has no harness for parallel dispatch, but it's mechanically additive (different compose project namespaces).

2. **Real-project onboarding smoke timing.** The synthetic smoke fixture covers plumbing; the first real-project run waits for Section C per the brief's out-of-scope language. Once C ships, the operator's first real run should be a deliberately-migrated project (the hello-turtle migration target may be a candidate; depends on its state).

3. **Other platform YAMLs growing code-migration role blocks.** Only `python-extras.yaml` was extended in this section. The other ship-with platforms (node-extras, rust, go, c-cpp, platformio-esp32) can grow code-migration blocks lazily as their first onboarding consumer surfaces — but a more proactive substrate-iteration pass (one section, mechanical edits across the registry) might be worth doing before any real polyglot brownfield project lands.

## Operator post-merge smoke session

Operator will exercise:

- Phase 1 of the runbook: `./onboard-project.sh infra/scripts/tests/fixtures/code-migration-smoke/` against a fresh substrate. Confirms the three-phase orchestration works with real claude, the migration report surfaces both deliberate findings, and the handover's section 3 names them by location.
- Phase 2 of the runbook: F50 four-role dance against a platform-declaring section brief. Confirms the s013 mechanism (deferred from s013's section) still works end-to-end now that B has shipped consumers that exercise it.

The operator's notes from those runs go in a follow-up document (suggested path: `briefs/s014-code-migration-agent/smoke-operator-notes.md`). Do not amend this section report — it's frozen at section-merge time.

## Findings surfaced during section work

Eight in total: three fixed during s014's post-merge stabilisation work, five recorded as deferred / informational pointers for future work.

**Fixed in s014 (amendment + hotfix):**

- **F59** — `depends_on: git-server` short-circuits the external `agent-net` reference. Raised by the post-merge smoke; fixed in the amendment (B.11 + B.12). See "Amendment" section below.
- **F60** — `dispatch-code-migration.sh` repo_root resolution off by one level (B.5 typo: `/..` should be `/../..`). Raised by the post-merge smoke after F59 was patched; fixed in the hotfix.
- **F61** — architect's /work clone is stale between phase-1 push and phase-2 dispatch. Raised by the post-merge smoke after F60 was patched; fixed in the hotfix (polished from operator's first cut).

**Deferred / informational (no s014 fix; documented for future implementers):**

- **F62** — B.8 plumbing test bypasses `./onboard-project.sh`'s multi-phase orchestrator. Test coverage gap; explains why F59/F60/F61 all surfaced in the post-merge smoke. Fix shape: extend `test-code-migration.sh` or add a separate `test-onboard-project.sh`. Consider scoping before Section C lands so its orchestrator changes don't inherit the same gap.
- **F63** — code migration agent dispatched host-side, not from inside the onboarder container (B.6 design call). Informational; documents the privilege-elevation rationale so Section C inherits the same pattern without re-litigation.
- **F64** — `git -C /work …` patterns absent from onboarder / code-migration tool surfaces and role guides. Both roles tripped on this in the smoke; fix shape is doc updates in onboarder-guide + code-migration-agent-guide (plain `git` is canonical for in-/work roles, parallel to F51's `git -C` guidance for read-only-mount roles).
- **F65** — heading numbering inconsistent between `code-migration-brief-template.md` (unnumbered) and `code-migration-report-template.md` (numbered). Flagged by the code migration agent in its own report's operational notes. Trivial alignment edit.
- **F66** — operator-side documentation gap. Smoke runbook has no framing-guidance for elicitation; no `methodology/operator-guide.md` exists at all. Wrong framing fails silently (mechanical success, nonsensical handover). Fix shape: per-section operator-notes for the immediate term + future operator-guide once patterns accumulate.

Next available F-number is now **F67**.

---

# Amendment — onboarder orchestration (s014-amendment-onboarder-orchestration.md)

The post-merge phase-1 smoke surfaced F59: the onboarder service's `depends_on: git-server` was forcing compose to instantiate a fresh git-server in the onboarder's compose project namespace, with fresh ephemeral bare-repo volumes — the architect (reading from the long-lived main.git) would never see the onboarder's artifacts. The 37/37 hermetic test passed because everything ran in one compose project; the first operational scenario with a separately-running long-lived substrate is what exposed it.

Amendment tasks B.11 and B.12 close F59. Total commits on the amendment: 3 (B.11, B.12, the F59/section-report update commit).

## B.11 — onboarder compose project shares the long-lived git-server

Single-line fix in `docker-compose.yml`: removed `depends_on: - git-server` from the onboarder service definition. Replaced with a block comment that documents the **mechanism**: `depends_on` here short-circuits the external `agent-net` reference. Compose instantiates the named service locally in the project namespace regardless of whether an external alias exists, taking precedence over the network's DNS resolution. Future edits tempted to add `depends_on: git-server` back "for clarity" will hit the regression-proof in B.12; the comment explains why before they get there.

Other ephemeral roles (planner, coder-daemon, auditor, code-migration) already lacked `depends_on: git-server` and worked correctly cross-project. The onboarder was the outlier inherited from s012, where the test scaffolded everything in one project so the bug never manifested. Operator-side `is_running agent-git-server` enforcement in `./onboard-project.sh` (lines 134-145) keeps the long-lived git-server up before invocation; no new mechanism needed.

Commit: `3ee137f`.

### Override-during-implementation: option (a) over option (b)

The amendment offered two suggested shapes: (a) external network reference, (b) run onboarder in long-lived project namespace with `--profile onboard`. Picked option (a) — which turned out to be a single-line fix once I noticed:

- `agent-net` is **already** declared `external: true` with a fixed name in `docker-compose.yml`. Every ephemeral service joins it. The cross-project DNS plumbing has been in place since s009; the onboarder just had to stop short-circuiting it.
- Commission-pair.sh / audit.sh / dispatch-code-migration.sh all work cross-project via this exact mechanism. The onboarder's `depends_on` was the anomaly.
- Option (b) would have required changes to `attach-architect.sh`, the cleanup logic in `onboard-project.sh`, and the compose-project-namespace convention — for no concrete win.

Option (c) would have been a third shape; in practice option (a) reduced to "delete two lines," so there was nothing to invent. Recorded here per the s013 override-during-implementation convention.

## B.12 — test phase 11: cross-project orchestration

Extended `infra/scripts/tests/test-code-migration.sh` with a new Phase 11 (5 assertions, regression-proof for F59):

- **Static contract check.** Awk-parses `docker-compose.yml`, extracts the onboarder service block (terminated at the next dedented service), greps its `depends_on:` list for `- git-server`, fails with a clear diagnostic if found. This is the literal regression-proof — the behavioural checks below cannot detect a re-introduction on their own (the test compose file is generated, necessarily matches the fixed shape).
- **Behavioural check.** Runs the onboarder service in a separate compose project namespace (`${project}-onboard`) from the scratch substrate. Stub claude writes `briefs/onboarding/orchestration-test-sentinel.md`, commits, pushes. Asserts the sentinel exists on the long-lived bare repo (`${vol_main_bare}`), and that no ephemeral volumes / containers were created in the new namespace.

Verified both directions: 42/42 PASS with B.11 applied; with B.11 reverted, Phase 11 fails at the static contract assertion with the regression diagnostic.

Cleanup extended to handle the new namespace's volumes (defensive: only relevant if F59 regresses, but cheap).

Commit: `9eec21b`.

## Test transcript (post-amendment)

42/42 PASS. Transcript at `briefs/s014-code-migration-agent/test-code-migration.transcript` updated.

## Reading the bug correctly

The amendment doc named a temptation worth recording: reading F59 as a `container_name:` collision would have led to "fix" by parameterising container names — making the failure silent without addressing the cause. The onboarder would still have written to an ephemeral bare repo; the architect still wouldn't have seen the artifacts. The container_name collision was the loud symptom, not the bug. The bug is the depends_on short-circuit; the fix is at that layer.

The broader `container_name:` parameterisation work is real but separate. Out of scope for this amendment; its own future substrate-iteration section if anyone wants to take it on.

## Post-amendment smoke

The operator re-runs phase 1 of the smoke runbook (`briefs/s014-code-migration-agent/smoke-runbook.md`) against the same source fixture. Expected outcome: the onboarder no longer collides on `agent-git-server`; the migration brief and draft handover land in the long-lived main.git; phase 2 dispatch succeeds; phase 3 produces the final handover; architect first-attach detection fires. Operator's notes from the actual run go in a follow-up document.

---

# Hotfix — F60 + F61 (dispatch path + architect /work staleness)

The post-amendment smoke surfaced two further bugs in sequence, both exposed only by running `./onboard-project.sh` end-to-end against an actually long-lived substrate. The B.8 hermetic test missed both because it drove the code-migration container directly (`ce run --rm code-migration`) without going through `./onboard-project.sh`'s multi-phase orchestrator — so the orchestrator-side staleness window (F61) and the dispatch helper's behavioural code path (F60) were never exercised.

## F60 — dispatch helper repo_root typo

B.5 shipped `repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"` — one `..` jump instead of two. Since the script lives at `infra/scripts/dispatch-code-migration.sh`, this resolved repo_root to `infra/`, making every subsequent `${repo_root}/infra/...` reference resolve to `infra/infra/...` (nonexistent). The `set -uo pipefail` shape (no `-e`) made the `source <nonexistent>` error non-fatal — the script kept going and failed mysteriously downstream.

Why Phase 10 of the B.8 test didn't catch it: all its assertions exercised arg-parse error paths (`--help`, `--bogus`, missing source-path) that exit BEFORE reaching any `${repo_root}/...` reference. The behavioural dispatch path (which sources `check-brief.sh`, invokes `compose-image.sh`, etc.) wasn't exercised end-to-end.

Fix: change `/..` to `/../..`. Single character per slash; path now resolves correctly.

Lesson for future substrate-iteration sections: scripts under `infra/scripts/` (or deeper) need `/../..` (or deeper) in their `dirname`-relative repo_root computation. Existing scripts in the tree (`compose-image.sh`, `resolve-platforms.sh`, `render-dockerfile.sh`, `validate-tool-surface.sh`) already do this correctly; my B.5 script was the outlier.

## F61 — architect's /work stale between phase 1 push and phase 2 dispatch

After F60 was patched, the next failure: `dispatch-code-migration.sh` couldn't find the migration brief at `/work/briefs/onboarding/code-migration.brief.md` even though phase-1 verification reported it present on origin/main.

The split: phase-1 verification used `git cat-file -e origin/main:<path>` (inspects refs). `dispatch-code-migration.sh`'s `check_brief_exists` uses `docker exec ${arch} test -f /work/<path>` (inspects working tree). The architect's /work is pulled only on architect *restart* (F55, s012), which happens at the END of `./onboard-project.sh`, after phase 3 — there was no pull between phase 1 push and phase 2 dispatch.

Operator's first-cut fix added a `git fetch + git pull` block right before the phase-2 banner. Refined in this hotfix to:
- Move the pull into the phase-1 verification block (logical home: "verification" should fully sync /work, not just refs).
- Replace `fetch + cat-file -e` with `pull --ff-only -q` (single command, syncs working tree and refs together).
- Use `${arch_container}` not the hardcoded `agent-architect` (consistency with rest of script; keeps the s012 test's `ARCHITECT_CONTAINER` env override working).
- Fail loud if the pull fails (clear error vs. downstream "brief not found").
- `--ff-only` carries F55's "surfaces real anomalies" safety.

### Override-from-operator-cut

The operator's hotfix worked but had three small issues I refined: hardcoded container name (breaks test-fixture overrides), redundant fetch (phase-1 verification just did one), and silent pull failure (`&&` short-circuits on fetch failure but not on pull failure). Refinement keeps the behaviour identical for the working path; adds clarity on the error path and aligns with the script's variable conventions.

## Test suite

The B.8 plumbing test still passes (42/42); F60 + F61 didn't manifest there because the test bypasses `./onboard-project.sh`. Strengthening the test to exercise the orchestrator end-to-end would have caught both — possible follow-up section, but out of scope here (the operator's smoke is the definitive check, and they re-run it after this commit lands).

## Why these are F-numbers, not bug fixes inside the amendment

F59, F60, and F61 are three distinct mechanisms (depends_on short-circuit; path typo; ref-vs-working-tree split). Conflating them into one finding would lose the lessons. The s013 pattern: each surfaced mechanism gets its own entry.

Hotfix commit: `2bd7652` (operator-authored, F60 fix + first-cut F61). Polish + FINDINGS entries: this commit.
