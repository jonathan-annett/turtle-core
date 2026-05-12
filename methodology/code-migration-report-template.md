# Code Migration Report — Template Specification

The code migration agent produces one file per onboarding: `briefs/onboarding/code-migration.report.md` in the project's main repo. This document specifies what that file must contain. It is **not a fillable form** — project shape varies enough that a single fillable form either forces vacuous "N/A" filler or branches into parallel templates per project type. A documented "must contain" specification handles the variation naturally, same shape as the onboarder-handover-template.

The migration report is **survey feedstock**, not work-completed. The onboarder reads it during its synthesis pass and integrates the findings into section 3 of the handover brief (the code structural review slot). The architect later reads it on first attach as additional bootstrap context — pointers to the structural-review slot in the handover, with the full migration report available for deeper reads when a question warrants going back to the agent's primary observations.

This shape is deliberately different from the section-report shape in spec §7.5. Section reports describe work completed against a brief; the architect and auditor read them to verify intent vs delivery. Migration reports describe a survey performed on materials the project did not yet own; the onboarder and architect read them to **understand what's there**. Different consumer-side use, different shape.

## Structure

Six sections, in this order, each with a `## ` heading using exactly the wording specified below. The onboarder's findings-synthesis pass does a presence check on the headings; using different wording breaks that check.

1. `## 1. Brief echo`
2. `## 2. Per-component intent`
3. `## 3. Structural completeness`
4. `## 4. Findings`
5. `## 5. Operational notes`
6. `## 6. Open questions`

A short preamble before section 1 is fine — typically one or two lines stating the project name (as you read it from `/source`), the onboarding-time project type, and a one-line statement of what was surveyed. Do not bury content in the preamble that belongs in a numbered section.

---

## Section 1 — Brief echo

**Purpose.** Restate what you understood the commissioning brief to ask for. Catches misinterpretation at the top of the report, where downstream readers see it first.

**Must contain.**
- One paragraph: your reading of the migration brief's Objective and the scope you operated within. Mention the platforms you composed against and the activity profile ("structural review only").
- Any clarification you applied — for example: "Interpreted 'structural review' to include lint and type-check probes but not test-suite execution, per the boundaries in the agent guide."

**Length guide.** A short paragraph — three to six lines. Long enough to surface a misreading; short enough that the reader gets past it quickly.

**Good content.** Direct restatement plus any in-scope clarifications you made.
**Bad content.** A retelling of the project. The brief echo is about *your understanding of the task*, not about what you discovered.

---

## Section 2 — Per-component intent

**Purpose.** Give the architect a structural map of `/source`. The architect uses this section to bootstrap their understanding of the project's component layout — the equivalent of a hand-drawn "here are the parts" diagram, in prose.

**Must contain.**
- For each top-level subtree / module you inspected, a bullet entry containing:
  - Path (relative to `/source`).
  - Inferred purpose, one sentence. Examples: "HTTP API surface (Flask)", "command-line entry points", "shared domain models", "build tooling (Makefile + scripts)".
  - Language(s) used in the subtree.
  - Apparent state: `active` / `archive` / `stale` / `unclear`. Use **confidence calibration** (Confirmed / Inferred / Speculative) on the state classification when not obvious.
- A trailing paragraph naming any subtrees you intentionally did not inspect (vendored upstreams, generated code, binary blobs) with a one-line reason.

**Length guide.** Scales with project size. A handful of components fit in half a page; a polyglot monorepo may run a full page.

**Good content.** "`src/api/` — HTTP API surface (Flask + flask-restx). Python 3.11. **Active** (Confirmed: recent commits in `git log`, broadly imported from `tests/api/`)."
**Bad content.** A `tree`-dump of every file. Summarise at the component level; do not duplicate the source tree.

---

## Section 3 — Structural completeness

**Purpose.** Document what the structural probes revealed about the source tree's internal consistency.

**Must contain.**
- **Import graph.** Does the import graph close? Are there modules that import from missing locations, or from locations that don't exist? Run language-appropriate checks (Python: `ruff`'s undefined-name diagnostic, `mypy --follow-imports=silent`, or a custom AST walk; Node: `tsc --noEmit`; Rust: `cargo check`; Go: `go vet`). Report counts: "Closed; 1242 imports resolved across 87 files, 0 unresolved."
- **Dependency resolution.** Are the declared dependencies satisfiable? Use the dry-run forms granted in your tool surface (`pip install --dry-run -r requirements.txt`, `npm install --dry-run`, `cargo check`, `go mod download -x`). Report the outcome and any specific declarations that failed.
- **Orphans.** Files present in the tree with no importers, no tests, no `__main__`-style entry point. List the paths and confidence ("Confirmed orphan: no importers in `git grep` of the module name across `/source`.").
- **Dangling references.** References to paths, modules, or symbols that do not exist. Different from import-graph holes — these are typically string-literal paths (`config_file = "config/prod.yaml"`) or build-system references.
- **Stale directories.** Directories that look like they were intended to be removed (`old/`, `legacy/`, `_archived/`) but are still in the tree. Cross-reference with operational notes (§5) if there's an explanation worth recording.

**Length guide.** Half a page to a page. Empty subsections ("Import graph: closed cleanly.") are fine; do not pad.

**Good content.** Specific counts, paths, and probe outputs. "Dependency resolution: `pip install --dry-run -r requirements.txt` fails on line 14 (`requestz==2.31.0`); appears to be a typo for `requests`."
**Bad content.** Process narrative ("I ran `pip install --dry-run` and it took a while"). Report findings, not process.

---

## Section 4 — Findings

**Purpose.** Severity-graded structural findings the architect should be aware of when shaping the project's first sections.

**Must contain.**
- Each finding as its own subsection with a `### ` heading: `### [SEVERITY] <short title>`.
- For each finding:
  - **Location.** File path(s), line number(s) where applicable.
  - **Evidence.** What you ran, what it produced, or what you read. Probe output, dependency-resolver error message, the relevant code snippet (short — point at the file, do not inline twenty lines).
  - **Suggested next-step framing.** What the architect might do with this. Keep it as a framing, not a demand: "Architect may want to schedule a dependency-cleanup task in the first section if `requests` is the intended name." Not: "Must fix `requirements.txt` line 14."

**Severity legend.** Same as `FINDINGS.md` in spirit, framed for survey-not-gating:

- **HIGH** — structural issue likely to block or significantly degrade the first sections (broken dependency declarations, missing critical files, contradictions between manifests and source).
- **LOW** — narrow or cosmetic structural issue (dead code, unused imports, minor lint patterns, narrowly-scoped orphans).
- **INFO** — observation worth recording without action (notable layout choices, vendored upstreams worth flagging, generated code committed deliberately).

**Length guide.** Open-ended. Most surveys will surface two to five HIGH-or-LOW findings plus a handful of INFO entries. If you have none, write "No findings warranting an entry." — do not pad with cosmetics.

**Good content.** Concrete, located, evidenced, framed for the architect's attention.
**Bad content.** Code-review opinions ("this function is too long"). The agent does not review code style; it surveys structure.

---

## Section 5 — Operational notes

**Purpose.** Things that would surprise an architect bootstrapping the project from scratch — context that doesn't fit "finding" framing but the architect should know on day one.

**Must contain.**
- Each note as its own bullet. Describe what it is, where you saw it, and why it might matter.
- Typical categories: unusual layouts (a `src/` directory that doesn't follow language convention), vendored upstreams (a copy of an external project committed in-tree), generated code (build artifacts committed deliberately), build-artifact directories under version control, large files, deliberately preserved historical directories.
- Cross-references to §3 (Structural completeness) and §4 (Findings) when a note explains a phenomenon you flagged elsewhere.

**Length guide.** Open-ended. "None observed." is a fine entry if there genuinely are none.

**Good content.** "The `vendor/upstream-fork/` directory contains a hand-modified fork of `requests` 2.28; the modifications appear in commit history with the message 'patch CRLF handling 2024-08'. Architect may want to record this as a deliberate decision in `SHARED-STATE.md` rather than treating it as orphan code."
**Bad content.** Findings dressed up as notes. If it has a severity, it goes in §4.

---

## Section 6 — Open questions

**Purpose.** Things you could not resolve from structural review alone, addressed to the architect (or, when it ships, the history migration agent).

**Must contain.**
- A bulleted list of unresolved questions, each phrased so the reader knows what answer would change which downstream decision.
- For each: where you looked, what you tried, why it remained unresolved (operator did not provide history; requires deeper analysis than survey scope; requires running the project which is out of scope).
- A confidence qualifier where relevant — "speculative inference suggests X but I would not act on it".

**Length guide.** As long as the unknowns are real. Three honest unknowns beat ten cosmetic ones.

**Good content.** "Is `tools/legacy/` actually a build-time dependency, or is it dead code that survived a refactor? **Where I looked:** grep for imports of `legacy.*` across `/source` yielded no hits, but a `Makefile` rule at line 47 references it. **Why unresolved:** the Makefile rule is conditional on an environment variable I could not run to verify. **Decision impact:** whether s001 should consider removing it, or whether it is load-bearing for a build path I have not exercised."
**Bad content.** Performative humility. If you actually know something with reasonable confidence, write it in §3 or §4 with the appropriate confidence marker.

---

## Confidence calibration

Across all six sections, mark observations explicitly when confidence is partial:

- **Confirmed** — you read it in the source or ran a probe that returned a definitive result.
- **Inferred** — you derived it from multiple structural signals; reasonable to act on but not certain.
- **Speculative** — you saw one signal and extrapolated; the architect should re-check before acting.

This calibration is more important than thoroughness. The onboarder will fold your report into the handover; the architect will read the handover as ground truth on first attach. The calibration markers tell downstream readers where to push back.

## Commit message

When you commit the migration report, use the message `onboarding: code-migration report` exactly. The onboarder's findings-synthesis pass and any tooling that scans for the commit relies on this string.

## File ownership and lifecycle

You write this file once and never edit it again. The onboarder reads it and folds findings into section 3 of the handover brief. The architect references it from `SHARED-STATE.md` later when historical context is useful; it is preserved on disk indefinitely as a historical artifact alongside the migration brief that commissioned it.
