# turtle-core update brief — Section B: code migration agent

## How to read this brief (read first)

**This is a substrate-iteration brief, not a project-methodology
brief.** Section B adds a sub-agent role to the substrate (the
**code migration agent**, dispatched by the onboarder during
project onboarding), its container and entrypoint, the operator-side
plumbing for declaring or inferring target-language platforms, the
dispatch helper, the migration brief and report templates, and the
onboarder integration that wires the new agent into the existing
onboarding flow. It is implemented the same way s001–s013 were:
a single agent on the host, working directly on a section branch,
committing files, pushing, writing a section report, and
discharging. **There is no architect, planner, coder, or auditor
involved in implementing Section B.**

The brief mentions "onboarder", "architect", "planner", "coder",
"auditor", and the new "code migration agent" extensively because
those are the names of the **substrate roles whose containers,
entrypoints, guides, and integration paths this section adds to
or modifies**. References to "the onboarder dispatches the code
migration agent" describe the **runtime behaviour after this
section lands**, not the workflow used to build it.

So: do not commission a planner. Do not invoke
`commission-pair.sh`. Do not invoke `./onboard-project.sh` from
inside this section's work. Read this brief on the section branch,
read `CLAUDE.md` and `FINDINGS.md` if you haven't already, read
the s013 section report at
`briefs/s013-platform-composition/section.report.md` for the F50
mechanism you'll be consuming, implement the tasks directly in
the working tree, commit each task as a separate commit (or as
task branches merged into the section branch — either pattern is
fine for substrate-iteration), write the section report to
`briefs/sNNN-code-migration-agent/section.report.md`, push the
section branch to origin. The human handles the section→main
merge.

**Section number.** Placeholder `sNNN` throughout. At dispatch,
fill in based on the current main tip. Likely `s014` if nothing
has shipped between s013 and this section. The brief otherwise
does not depend on section numbering.

---

## What this is

The third of four sections that build the migration-onboarding
machinery (A → F50 → B → C, per the s001-merged-onboarding-design
handover). Section A shipped as s012 (onboarder shell); F50
shipped as s013 (platform composition); this section is B; Section
C (history migration agent) ships afterward.

**What Section B adds.** A new sub-agent role — the **code
migration agent** — dispatched by the onboarder once during each
onboarding. The agent does **structural review** of the source
project (lint, syntax, dependency resolution, import-graph
completeness, orphan-file / stale-directory detection — not
build, not behavioural test). Its output is a descriptive,
severity-graded findings report that the onboarder synthesises
into the handover brief's already-existing migration-findings
slots (shipped empty in s012 for type-1 verification).

**What Section B does not add.** No history migration agent (that
is Section C). No migration audit machinery (deferred — see
constraints). No real-project migration runs (those wait for
Section C; the smoke uses a synthetic in-repo fixture).

### Why this ships now

The prerequisite primitives are in place. The onboarder's
handover-brief template anticipates migration-findings slots; the
F50 mechanism provides per-role image composition with target-
language toolchains; s011's tool-surface parser handles the
allowed-tools plumbing; s008's `BOOTSTRAP_PROMPT` pattern handles
deterministic non-interactive commissioning. Section B threads
these together for a new role rather than building any of them
fresh.

### Naming convention (worth restating)

Top-level methodology roles use **profession names** (architect,
planner, coder, auditor, onboarder). Sub-agents within onboarding
use the **"X migration agent"** form (code migration agent;
history migration agent ships in C). The asymmetry signals scope
distinction — these sub-agents exist only relative to the
onboarder, not as standalone methodology roles. **Don't rename.**
If a reading of this brief makes you want to call it
"reviewer" or "surveyor" or anything else, that's the convention
asserting itself — keep the name.

---

## Recommendations baked in (override before dispatch)

These are calls I've made for you. Each is the position I'd
defend if asked. Each has an **override clause** — explicit
guidance for what to change if you, on reading, see a cleaner
path. Surface the override at dispatch time rather than mid-
implementation; mid-implementation amendments are expensive.
(Note: as s013 showed, override latitude can also be exercised
**during** implementation when you find a strictly cleaner move —
e.g. hashing YAML bytes vs adding a schema field. Use that
latitude where it applies and document the deviation in the
section report.)

### 1. Onboarder infers platforms from source signals; surfaces the inferred set to the operator during elicitation; operator confirms or corrects

The onboarder reads canonical platform signals at `/source`
(`package.json` → node; `requirements.txt` / `pyproject.toml` →
python; `Cargo.toml` → rust; `go.mod` → go; `platformio.ini` →
platformio; etc.), produces an inferred set, and asks the
operator to confirm or correct during its existing elicitation
phase ("I see Python and Node source here — compose the code
migration agent with `python` and `node-extras` platforms? Y/n,
add/remove?"). The confirmed set is written into the migration
brief as the "Required platforms" field; the F50 mechanism
(`compose-image.sh`) consumes it from there.

Considered alternative: pure inference (no operator confirmation).
Rejected because inference can be wrong on ambiguous trees
(`tools/` subdirs with their own `package.json`; test fixtures in
a different language; vendored upstreams) and silently composing
the wrong platforms wastes a build cycle. The elicitation cost is
one question in an interactive interview the onboarder already
runs.

**Override:** specify "inference-only, no confirmation" if you
want the inference path to be silent.

### 2. `--platforms=<list>` on `./onboard-project.sh` as a power-user override

A new flag on `./onboard-project.sh` accepts a comma-separated
platform list (same syntax as F50's `--add-platform=<name>`).
When provided, the onboarder skips its inference + elicitation
step and uses exactly the supplied list. The migration brief
records the platforms as before; the source of the declaration is
the operator, not inference.

Considered alternative: no flag (operator must always go through
elicitation). Rejected because power users with unusual stacks or
scripted onboarding deserve a fast path.

**Override:** specify "no flag" if you want all platform
declarations to go through the elicitation path.

### 3. Code migration agent commits its own report

Symmetric to coder and auditor. The agent's keypair is generated
in `setup-linux.sh` / `setup-mac.sh` alongside the others
(idempotent, same pattern). The git-server gets a
`code-migration` role clause in its roles list and an update-hook
path-restriction allowing pushes only to
`refs/heads/main` for paths matching exactly
`briefs/onboarding/code-migration.report.md`. The agent commits
its report, the onboarder reads the committed report, the
onboarder folds findings into the handover.

Considered alternative: agent writes to a scratch mount, onboarder
reads from the mount and commits on the agent's behalf. Rejected
because it couples the two agents tightly (onboarder needs to
parse, validate, possibly reformat), loses the signed audit trail,
and breaks symmetry with how coder and auditor commit. The
incremental cost is one keypair, one hook clause, one role-list
entry — all mechanical.

**Override:** specify "scratch-mount + onboarder-commits" if you
want to collapse the agent's git surface.

### 4. Migration brief structurally parallel to §7.2; migration report shaped differently from §7.5

The migration brief reuses the section-brief shape — it's a
commission, and a planner reading a section brief and a code
migration agent reading a migration brief should see the same
contract structure. Fields: brief echo expectation, objective,
available context, **required platforms**, **required tool
surface**, output destination, reporting requirements.

The migration report is shaped differently because its output is
**survey feedstock**, not work-completed:

- **Brief echo.** One paragraph: what the agent understood the
  task to be.
- **Per-component intent.** For each top-level subtree / module
  the agent inspected: inferred purpose, language(s), apparent
  state (active / archive / stale / unclear). The architect later
  reads this to bootstrap its understanding.
- **Structural completeness.** Does the import graph close? Are
  there orphans, dangling references, dead-letter directories?
  Dependency declarations satisfiable per `--dry-run` checks?
- **Findings.** Severity-graded (HIGH / LOW / INFO — same legend
  as `FINDINGS.md`), but **not gate-shaped**. Each finding has
  location, evidence, and a suggested next-step framing for the
  architect (not a "must-fix" demand).
- **Operational notes.** Things that would surprise an architect
  bootstrapping the project — unusual layouts, vendored upstreams,
  generated code, build-artifact commits, etc.
- **Open questions.** Things the agent couldn't resolve from
  structure alone and that the architect (or later the history
  migration agent) should address.

Considered alternative: report uses section-report shape
(symmetry over fit). Rejected because section reports are
work-completed and the architect/auditor reads them to verify
intent vs delivery; migration reports are survey-feedstock and
the architect reads them to **understand what's there**.
Different shape, different consumer-side use.

**Override:** specify "use §7.5 section-report shape for the
migration report" if you'd rather force structural uniformity
across all report types.

### 5. Migration agent runs non-interactive (`-p` mode)

The agent's entrypoint invokes claude as
`claude -p "${BOOTSTRAP_PROMPT}" --permission-mode dontAsk
--allowed-tools "${ALLOWED_TOOLS}"` — same shape as planner and
auditor. No operator-in-loop. This is a survey activity; the
agent reads, runs tooling, writes the report, and discharges.
F56 (which records the onboarder's contrasting interactive
invocation) does not generalise here: the onboarder elicits from
the operator, the code migration agent does not.

Considered alternative: interactive mode (parallel to onboarder),
allowing the agent to ask the operator clarifying questions during
the survey. Rejected because clarifying questions belong in the
report's "open questions" section, addressed to the architect
during synthesis, not to the operator mid-survey.

**Override:** specify "interactive mode" if you want operator-
in-loop during the survey.

### 6. Smoke fixture: synthetic, in-repo, deterministic; F50 four-role-dance folds in as the second phase

Two-phase smoke, both phases operator-driven post-merge:

**Phase 1 — code migration agent end-to-end** (the B-specific
verification). A synthetic Python fixture in `infra/scripts/tests/
fixtures/code-migration-smoke/` (3-5 files, including one
deliberate structural issue: an orphan file or a dependency
typo). Operator runs `./onboard-project.sh
infra/scripts/tests/fixtures/code-migration-smoke/`, the onboarder
dispatches the code migration agent, the agent commits the
report, the onboarder integrates findings, the operator attaches
the architect and confirms the handover contains the populated
migration-findings slots.

**Phase 2 — F50 four-role-dance** (the deferred F50 smoke from
s013). Operator commissions a planner-pair against a section
brief that declares non-default platforms in its "Required
platforms" field, runs the section to audit-pass, verifies that
planner/coder-daemon/auditor all received platform-composed
images. Synthetic-source if hello-turtle hasn't grown a real
platform-declaring section by then.

Considered alternative for the fixture: use a real small project
of the operator's instead of a synthetic one. Rejected for the
in-section smoke because synthetic is deterministic, repeatable,
in-repo, and the first real-project run waits for Section C
anyway per the staged migration-onboarding rollout.

Considered alternative for F50 phase: standalone F50 smoke
session before B dispatches. Rejected per s013-handover Q1
recommendation (b): economical, B is natural consumer of F50,
s013 infrastructure tests already cover the platform-composition
mechanism exhaustively in isolation.

**Override:** specify "real-project fixture" for phase 1, or
"standalone F50 smoke before B" to invert the sequencing.

### 7. Migration brief template lives in `methodology/` as a documented "must contain" specification, not a fillable form

Path: `methodology/code-migration-brief-template.md`. The
onboarder reads it as guidance for what its output (the
per-onboarding migration brief) must contain, then composes a
fresh brief at `briefs/onboarding/code-migration.brief.md`. Same
shape as the s012 onboarder-handover-template decision.

Considered alternative: literal fill-in-the-blanks template. Same
rejection as s012's: project-type variation makes a single
fillable form awkward.

**Override:** specify "fillable form" if you prefer structural
uniformity.

---

## Top-level plan

**Goal.** Add the code migration agent as a sub-agent of the
onboarder, end-to-end: role guide, migration brief/report
templates, container, compose service, keypair, git-server
clauses, dispatch helper, onboarder integration (inference +
elicitation + dispatch + synthesis), spec updates, synthetic-
fixture infrastructure test, and methodology-run smoke
infrastructure (runbook + fixture; operator runs the smoke
post-merge).

**Scope.** One section. No parallelism. No history migration
agent (Section C).

**Sequencing.** Execute after the current main tip (post-s013
merge). Depends on s012 (onboarder shell) and s013 (F50 platform
composition) — both shipped. Hard prereq for Section C.

**Branch.** `section/sNNN-code-migration-agent` off `main`.

---

## Section sNNN — code-migration-agent

### Section ID and slug

`sNNN-code-migration-agent` (number filled at dispatch).

### Objective

Add a sub-agent role to the substrate: the **code migration
agent**, dispatched by the onboarder during each project
onboarding. The agent receives a brief at
`briefs/onboarding/code-migration.brief.md` declaring required
platforms and tool surface, performs structural review of the
source materials at `/source`, and commits a survey report at
`briefs/onboarding/code-migration.report.md` on `main`. The
onboarder reads the committed report and integrates findings into
the handover brief's existing migration-findings slots before
discharging. The agent's image is composed via F50's mechanism
with the platforms declared in the migration brief.

### Available context

Pre-existing primitives Section B builds on (do not redesign;
extend or compose):

- **`methodology/onboarder-guide.md`** (s012) — the onboarder
  role guide. The Section B work adds platform-inference,
  elicitation-of-platforms, dispatch-of-code-migration, and
  findings-synthesis to the onboarder's responsibilities. Update
  in place; don't fork.
- **`methodology/onboarder-handover-template.md`** (s012) —
  has migration-findings slots that this section's onboarder
  integration populates. Confirm the slot names match what the
  agent's report produces; adjust either side for symmetry.
- **`infra/onboarder/{Dockerfile,entrypoint.sh}`** (s012) — the
  onboarder container. Section B extends its entrypoint with the
  inference + elicitation + dispatch logic.
- **`./onboard-project.sh`** (s012) — operator entry. Section B
  adds the `--platforms` flag.
- **`infra/scripts/compose-image.sh`** (s013) — JIT image
  composition. Section B consumes this for the code-migration
  agent's image with platforms from the migration brief.
- **`infra/scripts/render-dockerfile.sh`** (s013) — used by
  `compose-image.sh`. The code-migration Dockerfile needs the
  `# PLATFORM_INSERT_HERE` sentinel s013 introduced.
- **`infra/scripts/lib/parse-tool-surface.sh`** (s011) — parses
  "Required tool surface" from a brief into `--allowed-tools`
  arguments. The code-migration entrypoint reuses this against
  the migration brief.
- **`infra/scripts/validate-tool-surface.sh`** (s013) — F52
  closure validator. Should be invoked against the composed
  code-migration image at dispatch time, same pattern as
  planner/auditor.
- **`infra/scripts/generate-keys.sh`** (extended through s012) —
  keypair generation. Extend to include the code-migration role.
- **`infra/git-server/`** — roles list and update hook. Extend
  with code-migration's role clause and path restriction.
- **`infra/scripts/audit.sh`** — closest existing parallel for
  `dispatch-code-migration.sh`. Read for shape; do not copy
  blindly (the audit context is different: a section branch under
  an active project, not an onboarding-time single shot).
- **`agent-orchestration-spec.md`** — currently at v2.4. Section
  B bumps to v2.5: new row in the role/access table (in §3.3 or
  wherever the v2.4 spec locates it; identify the exact section
  from the live file), new role description in §4 (as a sub-agent
  of onboarder; cross-reference §4.onboarder), new artifact
  entries in §7.x for migration brief and migration report. The
  spec is canonical; role guides are derivative — regenerate the
  onboarder-guide after the spec lands if structural changes
  affect it.
- **`FINDINGS.md`** — current F-number ceiling is F58; next
  available is F59. Add new findings if you surface any during
  the work.
- **`CLAUDE.md`** — substrate-iteration orientation. Confirms
  the work-mode you're in.
- **The s001-merged onboarding-design handover** (in operator
  output paths if not committed) — the substantive design
  thinking on what the code migration agent is and what it
  produces. Reread if the role's purpose feels under-specified
  from this brief alone; the design content there is preserved
  in writing and remains authoritative for the role's character.
- **The s013 section report** at
  `briefs/s013-platform-composition/section.report.md` — the
  three implementation improvements on the F50 brief (hash-by-
  file-bytes, `--stdout` mode on `render-dockerfile.sh`, default-
  platform no-op for onboarder) are worth reading both for the
  mechanism details and as evidence of the latitude the override-
  during-implementation pattern affords.

### Tasks (informal decomposition)

The agent may decompose differently, but this is the suggested
ordering. B.1 and B.2 set the shape of the role and its
artifacts; do those first.

**B.1 — Code migration agent role guide.**

Create `methodology/code-migration-agent-guide.md`. Parallel in
shape to other role guides but adapted for the sub-agent scope.
Must contain:

- **Your role.** Sub-agent of the onboarder, dispatched once per
  project onboarding. Single-shot, ephemeral. Activity profile:
  structural review of source materials. Read, run survey tools,
  write the report, discharge.
- **Your boundaries.** Don't build the project; don't run its
  tests; don't dispatch further sub-agents (probes that need
  language toolchain go in your tool surface, same shape as the
  auditor running `pio run` directly). Don't write outside
  `briefs/onboarding/code-migration.report.md`. Don't speculate
  beyond what the source materials show; document unknowns as
  open questions for the architect.
- **What you produce.** The migration report, structured per the
  template at
  `methodology/code-migration-report-template.md`. Severity-
  graded findings, **not gate-shaped** (use HIGH/LOW/INFO as in
  `FINDINGS.md`, but framed as "for architect's attention" not
  "must fix").
- **Tool surface staples.** `pip install --dry-run`,
  `npm install --dry-run`, `cargo check`, `go vet`, `mypy`,
  `ruff`, language-specific linters and type checkers. Exact set
  per migration brief.
- **Your inputs.** `/source` (read-only) — the source project.
  `briefs/onboarding/code-migration.brief.md` on `main` — your
  brief. `methodology/` (read-only) — the report template and
  this guide.
- **Discharge.** Commit the report. The onboarder reads it from
  there; your job is done at commit.

**B.2 — Migration brief & report templates.**

Create:

- `methodology/code-migration-brief-template.md` — documents what
  a per-onboarding migration brief must contain. Fields: brief
  echo expectation, objective, available context (pointer to
  `/source` and `--type` value), **Required platforms** (with
  override-via-`--add-platform` note), **Required tool surface**
  (s011 syntax), output destination
  (`briefs/onboarding/code-migration.report.md`), reporting
  requirements (pointer to the report template).
- `methodology/code-migration-report-template.md` — documents the
  survey-feedstock shape: brief echo, per-component intent,
  structural completeness, findings (severity-graded, HIGH/LOW/
  INFO, framed for architect's attention), operational notes,
  open questions.

Both are "must contain" specifications, not fillable forms (per
design call 7).

**B.3 — Container.**

Create `infra/code-migration/{Dockerfile,entrypoint.sh}`. The
Dockerfile parallels other ephemeral-role Dockerfiles
(`infra/auditor/Dockerfile`, `infra/planner/Dockerfile`) in
structure. Must include the `# PLATFORM_INSERT_HERE` sentinel
(s013 convention) so `compose-image.sh` can inject platform
snippets. Entrypoint:

- Honours `BOOTSTRAP_PROMPT` (s008 pattern).
- Pulls the migration brief from `/work/briefs/onboarding/
  code-migration.brief.md`.
- Parses the brief's "Required tool surface" via
  `parse-tool-surface.sh` (s011).
- Invokes claude in `-p` mode (non-interactive, design call 5)
  with the parsed allowed-tools and `--permission-mode dontAsk`.
- Pulls and commits via the agent's own keypair.

**B.4 — Compose service, keypair, git-server clauses.**

- `docker-compose.yml`: add a `code-migration` service in the
  ephemeral profile. Image tag follows the F50 convention
  (`agent-code-migration-platforms:<hash12>` set via
  env-overridable variable, populated by `dispatch-code-
  migration.sh` after composition).
- `setup-linux.sh` / `setup-mac.sh`: extend keypair generation
  (via `infra/scripts/generate-keys.sh`) to include the
  `code-migration` role. Idempotent (don't regenerate on re-run).
- `infra/git-server/`: add `code-migration` to the roles list.
  Update hook gets a path restriction: `code-migration` may push
  to `refs/heads/main` only when the only file changed is
  `briefs/onboarding/code-migration.report.md`. Pattern parallels
  the onboarder's restriction (F57 informational entry — same
  rationale, single-shot enforcement at script level, hook as
  defence in depth).
- Onboarder's claude-state-shared volume convention applies
  here too (F48 — ephemeral creds staleness; documented
  workaround is `./verify.sh`, no new mechanism needed).

**B.5 — Dispatch helper.**

Create `infra/scripts/dispatch-code-migration.sh`. Inputs from
the onboarder: source path (host-side, for read-only mount into
the agent's container), platforms (the confirmed-or-flag-supplied
list), brief path (the migration brief on `main`). Behaviour:

1. Compose the agent's image via `compose-image.sh` with the
   declared platforms. Reuses s013's hash-tagged cache; identical
   platform sets hit cache.
2. Validate the composed image against the brief's tool surface
   via `validate-tool-surface.sh`. Fail fast on mismatch (F52
   closure pattern from s013).
3. Run the container with appropriate mounts:
   - `/source` ← source path, read-only
   - `/work` ← the project's main repo clone, with the
     code-migration role's keypair mounted for git operations
   - `/methodology` ← the methodology directory, read-only
4. Block until the container exits. Surface exit code to the
   onboarder.

Shape: parallel to `infra/scripts/audit.sh` but adapted for the
onboarding-time single-shot context. Read `audit.sh` for the
mount-and-keypair pattern; don't copy blindly.

**B.6 — Onboarder integration.**

Update the onboarder's role guide, container entrypoint, and
elicitation flow to dispatch the code migration agent:

- **`methodology/onboarder-guide.md`:** the onboarder's section
  on its sub-agents (currently noting them as "future capability
  via Sections B and C") becomes active for B. Document the
  inference + elicitation + dispatch + synthesis flow.
- **`infra/onboarder/entrypoint.sh`:** add the inference step
  (probably a helper at `infra/scripts/infer-platforms.sh
  /source` returning the inferred set on stdout; agent decides
  exact shape), the elicitation question, the brief-write +
  commit, the dispatch call, the report-read after dispatch
  returns, and the findings-integration into the handover.
- **`./onboard-project.sh`:** add `--platforms=<csv>` flag.
  Documented in `--help`. When supplied, the onboarder skips
  elicitation for platforms and uses exactly the supplied set.
  `--type` and `--platforms` are independent axes (type = source-
  material taxonomy 1-4; platforms = target-language toolchain).
- **`methodology/onboarder-handover-template.md`:** confirm the
  migration-findings slots match the report template's section
  names; adjust either side for symmetry. The slots stop being
  "anticipated for future"; they get populated for every
  onboarding now.

**B.7 — Spec updates.**

Update `agent-orchestration-spec.md` (v2.4 → v2.5):

- **Role/access table** (currently §3.3 in v2.4; verify against
  the live file): new row for `code-migration` with read access
  to `/source` (host bind, read-only) and
  `methodology/` (read-only), and write access scoped to
  `briefs/onboarding/code-migration.report.md` on `main`.
- **§4 Roles:** new subsection for the code migration agent.
  Note it explicitly as a sub-agent of the onboarder, not a
  standalone methodology role. Cross-reference §4.onboarder.
  Document the structural-review activity profile, the non-gate-
  shaped output, the single-shot ephemeral lifecycle, and the
  no-further-dispatch boundary.
- **§7.x artifacts:** two new entries. **Migration brief** (the
  onboarder authors it; the code migration agent reads it).
  **Migration report** (the code migration agent authors it; the
  onboarder reads it and integrates findings into the handover).
  Both are project-scoped (under `briefs/onboarding/`), not
  section-scoped.
- **§8 Lifecycle:** the onboarding phase (§8 step 0 from s012)
  grows a sub-step: platform inference + elicitation → migration
  brief write → code migration agent dispatch → report read →
  findings integration → handover write. Insert at the right
  point; the existing onboarder-discharge step moves down.

Spec is canonical; role guides are derivative. After spec edits
land, scan the role guides for derivative content that needs
regeneration; if `architect-guide.md` or `auditor-guide.md`
mentions the onboarder phase in a way that's now stale, update
in place.

**B.8 — Synthetic-fixture infrastructure test.**

Create `infra/scripts/tests/test-code-migration.sh`. Pattern
parallels s012's `test-onboarder-shell.sh`. Uses the
`infra/scripts/tests/fixtures/code-migration-smoke/` fixture
(B.9.fixture below). Hermetic, stub-claude pattern (F56's
generalisation note applies: the stub may need to handle `-p`
mode invocation).

Assertions:

- Dispatch helper composes the right image (correct platform
  hash given the fixture's `requirements.txt`).
- Validator passes against the composed image for the brief's
  tool surface.
- Agent commits a report at the expected path.
- Report contains the expected section headers (per-component
  intent, structural completeness, findings, operational notes,
  open questions).
- Update-hook rejects pushes from `code-migration` to other
  paths (path-restriction working).

The agent itself is stubbed in this test; we're verifying the
plumbing, not the claude-side survey quality. Survey quality is
verified by the operator-driven smoke (B.9).

**B.9 — Methodology-run smoke runbook + fixture.**

Two artifacts, operator-driven post-merge:

- **Fixture:** `infra/scripts/tests/fixtures/code-migration-smoke/`.
  3-5 file Python project. Includes:
  - `pyproject.toml` or `requirements.txt` (declares one
    legitimate dependency).
  - One Python module importing a sibling.
  - One Python module that is an obvious orphan (no importers,
    no tests, no `__main__`).
  - Optional: one obvious typo in a dependency declaration
    (`requestz` for `requests`).
  - A short `README.md` explaining the fixture's purpose to a
    future maintainer.

- **Runbook:** in the section report or under
  `briefs/sNNN-code-migration-agent/smoke-runbook.md`. Two-phase
  structure per design call 6:
  - **Phase 1** (code migration end-to-end): operator runs
    `./onboard-project.sh
    infra/scripts/tests/fixtures/code-migration-smoke/`,
    confirms platforms, observes dispatch, attaches architect,
    inspects handover for populated migration-findings slots.
  - **Phase 2** (F50 four-role-dance): operator commissions a
    planner-pair against a section brief declaring non-default
    platforms, runs to audit pass, confirms each role's image
    had the platforms composed in. Synthetic source acceptable
    if hello-turtle hasn't grown a platform-declaring section
    by then.
  
  Use `${UUID}` placeholder style in any runbook variables, not
  `<placeholder>` syntax (F53 — bash interprets the latter as
  redirection).

Document explicitly that B.9 is **operator-driven, post-merge**.
You ship the infrastructure (runbook + fixture); the operator
executes it. Mark the smoke run in the section report as
"deferred to operator session" with the runbook path; the
operator's notes from the actual run go into a follow-up
document, not the section report.

**B.10 — Documentation updates.**

Update:

- **`methodology/deployment-docker.md`:** add a code-migration
  section paralleling the existing per-role sections. Cover the
  container, the compose service, the dispatch helper, the
  onboarder-driven invocation, and the report path.
- **`README.md`:** update the brownfield-migration quickstart
  (added in s012) to mention the platform inference / `--platforms`
  flag.

### Constraints

- **Sub-agent scope.** The code migration agent is a sub-agent of
  the onboarder, not a standalone methodology role. Reflect this
  in the spec §4 entry (cross-reference §4.onboarder; don't
  promote to a parallel role).
- **No migration audit machinery.** Preserves s012's design call
  6 deferral. The migration brief and report are pre-architect,
  pre-section, pre-audit. Audit machinery for the migration
  phase, if ever added, is its own section with its own brief.
- **Durable repo history.** The migration report stays in the
  project's main repo at `briefs/onboarding/code-migration.report.md`
  after onboarding. Future architects cite it from shared-state
  when relevant. Not consumed-and-discarded.
- **No further sub-agent dispatch.** Builds, probes, and language-
  toolchain runs go in the agent's own tool surface (same shape
  as the auditor running `pio run` directly). Depth stops at the
  code migration agent's container.
- **Tool surface is brief-parsed.** Unlike the onboarder (F58 —
  embedded allow-list, justified by absence of a brief), the code
  migration agent has a real brief with a "Required tool surface"
  field. Parse it the s011 way; do not embed.
- **No section number assumptions.** The brief uses `sNNN` and
  the implementing agent resolves at dispatch. Other substrate-
  iteration work may land between s013 and this section.
- **Spec is canonical; guides are derivative.** Edit the spec
  first; regenerate role-guide content from it where derivative
  content goes stale.
- **`--type` and `--platforms` are independent.** Type is source-
  material taxonomy (1-4); platforms is target-language
  toolchain. State this explicitly in the onboarder guide and in
  `./onboard-project.sh --help` to head off operator confusion.
- **F58 staleness applies.** The code migration agent reads
  claude-state credentials from the shared volume; the same
  rotation-staleness concern applies. Documented workaround
  (`./verify.sh`) carries forward — no new mechanism.
- **Single-shot per onboarding.** The code migration agent runs
  once per project onboarding, same single-shot envelope as the
  onboarder. Re-onboarding is out of scope (s012 carry-forward).

### Definition of done

- `methodology/code-migration-agent-guide.md` exists,
  structurally parallel to other role guides, with the role,
  boundaries, output template pointer, and tool-surface staples
  documented.
- `methodology/code-migration-brief-template.md` and
  `methodology/code-migration-report-template.md` exist; both
  are "must contain" specifications.
- `infra/code-migration/{Dockerfile,entrypoint.sh}` exist; the
  container builds cleanly; the Dockerfile has the
  `# PLATFORM_INSERT_HERE` sentinel; the entrypoint honours
  `BOOTSTRAP_PROMPT`, parses tool surface via
  `parse-tool-surface.sh`, invokes claude in `-p` mode.
- `docker-compose.yml` has a `code-migration` service in the
  ephemeral profile with env-overridable image tag.
- `setup-linux.sh` and `setup-mac.sh` generate the code-migration
  keypair idempotently via the extended `generate-keys.sh`.
- `infra/git-server/` includes `code-migration` in the roles list
  with the path-restricted update-hook clause.
- `infra/scripts/dispatch-code-migration.sh` exists, executable,
  composes + validates + runs + blocks as specified in B.5.
- `infra/scripts/infer-platforms.sh` (or whatever shape the
  implementing agent chooses for inference) exists and detects
  at least python, node, rust, go, platformio from canonical
  signals.
- `./onboard-project.sh` accepts `--platforms=<csv>`; `--help`
  documents it.
- The onboarder's entrypoint runs inference + elicitation +
  dispatch + synthesis as specified in B.6.
- `agent-orchestration-spec.md` is at v2.5 with the new
  role/access row, the new §4 sub-agent entry, the two new §7.x
  artifact entries, and the §8 onboarding-phase sub-step.
- `infra/scripts/tests/test-code-migration.sh` exists and passes
  using the stub-claude pattern.
- `infra/scripts/tests/fixtures/code-migration-smoke/` exists
  with the 3-5 file Python fixture as specified.
- Methodology-run smoke runbook exists (in the section report or
  as a sibling document), with both phases documented per design
  call 6.
- `methodology/deployment-docker.md` and `README.md` updated per
  B.10.
- Section report at `briefs/sNNN-code-migration-agent/
  section.report.md` including: brief echo, per-task summary,
  the canonical code-migration bootstrap prompt in full (becomes
  reference like s008's planner/auditor prompts and s012's
  onboarder prompt), test transcript from B.8, any residual
  hazards, smoke runbook (or pointer to it), explicit note on
  which open questions remain for the operator's post-merge
  smoke session.

### Out of scope

- **History migration agent.** Section C.
- **Real-project migration runs.** Wait for Section C; in-
  section smoke uses synthetic fixture only.
- **Migration audit machinery.** Deferred per s012 design call 6.
- **Cross-substrate / cross-host migration.** History agent
  Section C territory.
- **Re-onboarding.** Single-shot per project (s012 carry-forward).
- **Promoting the code migration agent to a top-level role.**
  Sub-agent by design; if a future need warrants promotion that's
  a separate section with its own brief.
- **Auto-fixing the findings the agent surfaces.** The agent
  surveys; the architect decides. No automated remediation.
- **Building or running the source project.** Structural review
  only. Build chains may appear in the tool surface only when
  they're the cleanest probe for a specific class of issue (e.g.
  C/C++ where the compiler is effectively the import resolver),
  not as a goal.
- **Operator-side smoke execution.** Ship the runbook + fixture;
  the operator runs the smoke.
- **F58 generalisation to a brief-parsable onboarder tool
  surface.** Stays informational. Onboarder's tool surface is
  invariant across onboardings; embedded list remains correct.

### Repo coordinates

- Base branch: `main` (post-s013 merge).
- Section branch: `section/sNNN-code-migration-agent`.
- Task commits or task branches off the section branch are both
  fine — same pattern as s001–s013. Inline commits on the section
  branch are likely cleanest given task sizes; B.6 (onboarder
  integration) is the largest individual task and benefits from
  its own commit for review.

### Reporting requirements

Section report at
`briefs/sNNN-code-migration-agent/section.report.md` on the
section branch. Must include:

- Brief echo (restate Section B's objective in your own words).
- Per-task summary (B.1 through B.10).
- The canonical code-migration bootstrap prompt in full (the
  deterministic prompt set by `dispatch-code-migration.sh`) —
  becomes the methodology's reference for code-migration
  commissioning, same status as the planner/auditor prompts
  (s008) and the onboarder prompt (s012).
- The dispatch-helper shape (inputs, outputs, exit-code
  semantics) — becomes the reference for future similar helpers.
- The inference-helper shape — what signals get detected, what
  it returns.
- The migration brief and report template section headings in
  full (so the report serves as a quick reference for what the
  agent must produce).
- The spec diff: which sections moved (v2.4 → v2.5), what the
  new content is at the role/access table, §4, §7.x, and §8.
- Test transcript from B.8.
- Smoke runbook (or pointer to a sibling file containing it).
- Override-during-implementation deviations from the brief's
  recommendations, with rationale (s013 pattern — these are not
  failures of the brief but evidence of latitude well-used).
- Residual hazards, open questions for the next chat-Claude
  instance, and explicit note on what the operator's post-merge
  smoke session will exercise.

---

## Execution

Read this brief. Read `CLAUDE.md` and `FINDINGS.md` if you
haven't already. Read the s013 section report for the F50
mechanism you're consuming. If anything in the brief contradicts
what you find in the live spec or guides, the live files win and
this brief gets amended; surface the contradiction rather than
proceeding on stale guidance.

Then implement on the section branch, commit cleanly, push, and
write the section report. The operator handles the section→main
merge.
