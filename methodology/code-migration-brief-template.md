# Code Migration Brief — Template Specification

The onboarder produces one file per onboarding: `briefs/onboarding/code-migration.brief.md` in the project's main repo. This document specifies what that file must contain. It is **not a fillable form** — project shape (single-language vs polyglot; vendored upstreams vs greenfield; trivial dependency surface vs registry-heavy) produces qualitatively different content. A documented "must contain" specification handles that variation naturally, same shape as the onboarder-handover-template.

The migration brief is the code migration agent's commissioning artifact. The agent reads it once at startup, performs the survey, and writes the migration report. The dispatch helper parses two fields from this brief — `Required platforms` and `Required tool surface` — to compose the agent's image and set its `--allowed-tools`. Errors or omissions in those two fields will fail commission cleanly before the claude session starts; author them precisely.

## Structure

The brief uses the same section-brief shape that planners and auditors consume (spec §7.2, §7.6), so a section-aware reader sees the same contract structure for any commissioning event. Six sections, in this order, each with a `## ` heading using exactly the wording specified below:

1. `## Objective`
2. `## Available context`
3. `## Required platforms`
4. `## Required tool surface`
5. `## Output destination`
6. `## Reporting requirements`

A short preamble before section 1 is fine — typically one or two lines naming the project (so the agent's brief-echo has something to anchor against), and a one-line statement that this is a code-migration commissioning brief authored by the onboarder.

The brief must also include the **brief echo expectation** — a sentence in the preamble or under Objective directing the agent to restate the section's objective in its own words at the top of its report. The s011 / s012 / s013 contract for briefs applies uniformly here.

---

## Section 1 — Objective

**Purpose.** State what the agent is being commissioned to produce, in one paragraph.

**Must contain.**
- A single-paragraph statement: "Perform a structural review of the source materials at `/source` and produce a migration report at `/work/briefs/onboarding/code-migration.report.md`."
- The activity-profile qualifier: "Structural review only — no behavioural test execution, no build verification beyond what the tool surface explicitly grants for survey purposes."
- The brief-echo directive: "Restate this objective in your own words at the top of your report under the **Brief echo** heading."

**Length guide.** Three to five lines. The objective does not need to enumerate what the report contains (that lives in Reporting requirements / the report template).

---

## Section 2 — Available context

**Purpose.** Point the agent at the relevant context without forcing it to discover the environment by trial.

**Must contain.**
- Pointer to `/source` (read-only mount of the brownfield materials).
- Pointer to `/methodology/code-migration-agent-guide.md` (the role guide, symlinked as `/work/CLAUDE.md`).
- Pointer to `/methodology/code-migration-report-template.md` (the report shape).
- The project-type hint (`1`, `2`, `3`, `4`, or `unknown`) per the four-type taxonomy.
- The onboarder's preliminary observations from its own read-through, if any are worth preserving for the agent — "operator confirmed Python and Node coexist; `tools/legacy/` is reportedly a vendored older version of the project, do not flag as orphan", etc. This is the onboarder's chance to head off known-uninteresting findings.

**Length guide.** Half a page. Pointers, hints, and any onboarder-side context the agent should not have to rediscover.

---

## Section 3 — Required platforms

**Purpose.** Declare the target-language toolchains the agent's composed image must carry. The dispatch helper parses this field and feeds it to `infra/scripts/compose-image.sh` to produce a hash-tagged image.

**Must contain.**
- A fenced code block in the same grammar used for section briefs (§7.2 of the spec): YAML simple list or JSON array of platform names. Platform names must match files at `methodology/platforms/<name>.yaml` (e.g. `python-extras`, `node-extras`, `rust`, `go`, `platformio-esp32`, `c-cpp`).
- Empty list (`[]`) is valid and means "no extra platforms beyond the base image" — produces the static template build via `compose-image.sh`'s default-platform no-op semantics (s013).

**Subset semantics — important asymmetry vs section briefs.** Section briefs declare platforms as a subset of the project superset in `TOP-LEVEL-PLAN.md`'s `## Platforms` section. The migration brief is authored **before** `TOP-LEVEL-PLAN.md` exists (the architect drafts that on first attach), so there is no project superset to validate against yet. The dispatch helper accepts the migration brief's platform set as authoritative — the onboarder either inferred it from `/source` signals or received it from the operator via `./onboard-project.sh --platforms=<csv>`.

**Override mechanism.** If the operator wants to extend the inferred set without the onboarder re-asking, the `--platforms=<csv>` flag on `./onboard-project.sh` bypasses inference entirely and the supplied list becomes authoritative. Inference + elicitation is the default path; the flag is the power-user fast path.

**Length guide.** Five to fifteen lines including the fenced block. A bullet introducing the field plus the fence is sufficient.

---

## Section 4 — Required tool surface

**Purpose.** Declare the Claude Code tools and Bash patterns the agent is permitted to use during the survey. Parsed by the shared `parse-tool-surface.sh` into `--allowed-tools` at commission time.

**Must contain.**
- A fenced code block in the same grammar used for section / audit briefs (§7.3, §7.6 of the spec): YAML simple list or JSON array of tool names and Bash-anchored patterns.
- Coverage of survey-grade probes appropriate to the platforms declared in §3. The agent guide enumerates typical staples (`pip install --dry-run`, `npm install --dry-run`, `cargo check`, `go vet`, lint and type-check tools, file/module discovery). Match the surface to the platforms — granting `cargo check` without `rust` in §3 will fail tool-surface validation (F52 closure, s013).
- The `Read`, `Edit`, and `Write` tools (Edit and Write scoped against the report path; the agent does not need write access elsewhere).
- `Bash(git add:*)`, `Bash(git commit:*)`, `Bash(git push:*)` for the report-commit step.

**Length guide.** Half a page to a page, depending on platform breadth. Be specific — colons-as-separators in `Bash(...)` patterns extract the binary name for validation; `Bash(git -C /work log:*)` extracts `git` correctly.

---

## Section 5 — Output destination

**Purpose.** Pin the report path so the agent and the onboarder agree on where the artifact lands.

**Must contain.**
- The single line: "Commit and push the migration report to `briefs/onboarding/code-migration.report.md` on `main`."
- The git-server's update-hook constraint: "Your role identity allows pushes to `refs/heads/main` only when the changed paths are exactly that one file."
- The commit-message convention: "Commit with the message `onboarding: code-migration report` exactly. The onboarder's findings-synthesis pass uses this string to locate your commit."

**Length guide.** Three to five lines. The path is the contract; do not editorialise.

---

## Section 6 — Reporting requirements

**Purpose.** Direct the agent at the report template and reinforce the section-headings contract.

**Must contain.**
- Pointer to `/methodology/code-migration-report-template.md` as the authoritative shape spec.
- The six required `## ` headings (Brief echo / Per-component intent / Structural completeness / Findings / Operational notes / Open questions) listed in order so the agent's heading-checker can refer to a single authority.
- The severity legend (HIGH / LOW / INFO) and the framing constraint: findings are "for the architect's attention", not "must-fix".
- The confidence-calibration directive (Confirmed / Inferred / Speculative — same as the onboarder-handover-template).

**Length guide.** Half a page. The template carries the long-form spec; this section is a pointer plus the contract surface the onboarder's synthesis pass relies on.

---

## File ownership and lifecycle

- **Author:** the onboarder. It composes the brief during its elicitation pass, after platforms are inferred / confirmed (or supplied via `--platforms`) but before dispatching the code migration agent.
- **Reader:** the code migration agent (single-shot, at startup).
- **Lifecycle:** the brief is committed by the onboarder to `main` immediately before dispatch. It is preserved on disk indefinitely as a historical artifact, alongside the migration report it commissioned. The architect may reference it from `SHARED-STATE.md` when historical context is useful; it is not rewritten.

## Commit message

When the onboarder commits the migration brief, use the message `onboarding: code-migration brief` exactly. The dispatch helper and any tooling that locates the brief rely on this string.
