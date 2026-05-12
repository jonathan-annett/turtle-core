# Onboarder Handover Brief — Template Specification

The onboarder produces one file: `briefs/onboarding/handover.md` in the project's main repo. This document specifies what that file must contain. It is **not a fillable form** — the four project types (see `onboarder-guide.md` §4) produce qualitatively different content, and a single fillable form either forces vacuous "N/A" filler or branches into four parallel templates. A documented "must contain" specification handles type variation naturally.

The handover is the architect's bootstrap context. On the architect's first attach to an onboarded project, its entrypoint detects this file and seeds the architect's first claude session against it. The architect reads it as starting truth, adopts the candidate `SHARED-STATE.md` and `TOP-LEVEL-PLAN.md` as drafts to refine, and begins the project methodology from this point.

## Structure

Nine sections, in this order, each with a `## ` heading using exactly the wording specified below. The architect's entrypoint does a simple presence check on the headings; using different wording breaks that check.

1. `## 1. Project identity`
2. `## 2. Source materials inventory`
3. `## 3. Code structural review`
4. `## 4. History review`
5. `## 5. SHARED-STATE.md candidate`
6. `## 6. TOP-LEVEL-PLAN.md candidate`
7. `## 7. Known unknowns`
8. `## 8. Operator's stated priorities`
9. `## 9. Carry-over hazards`

A short preamble before section 1 is fine — typically two or three lines stating the project name, the onboarding date, the project type, and a one-line summary of "what this is". Do not bury content in the preamble that belongs in a numbered section.

---

## Section 1 — Project identity

**Purpose.** Pin the project to a concrete identity the architect can verify against in one read.

**Must contain.**
- Project name (as the operator referred to it during elicitation; if the operator did not name it, use the source directory's basename and flag for confirmation).
- Source location (the host path that was mounted at `/source` during onboarding — recorded for future cross-reference, not because it is still mounted after you discharge).
- Primary language(s) and stack. Be specific: "Go 1.21 with sqlx + chi", not "Go".
- Observed methodology state: one of `none` / `informal` / `formalised`. For type 1 and most type 2 projects this will be `none`. Type 4 should be `informal` or `formalised` depending on how much structure was already in place.
- Type classification (1/2/3/4) with a one-sentence rationale.

**Length guide.** Tight — five to ten lines total. This is the architect's "is this the project I think it is" check, not a narrative.

**Good content.** Specific, verifiable, one fact per bullet.
**Bad content.** Marketing summaries of what the project *does*; that belongs (briefly) in the preamble or in section 6.

---

## Section 2 — Source materials inventory

**Purpose.** Give the architect a sense of what raw material existed at onboarding time without forcing them to walk `/source` themselves.

**Must contain.**
- Directory structure summary — one or two paragraphs naming the top-level directories and what each holds. Not a `tree` dump; a *summary*.
- File counts by relevant type. For type 1: source files by language. For types 2–4: also docs (markdown, .txt), and any preserved transcripts or methodology artifacts.
- Presence/absence of: a README at the source root; a CHANGELOG or similar history file; license file; build/CI config; tests directory; docs directory; agent transcripts (type 3/4); informal planning artifacts (type 4).
- Anything genuinely surprising in the inventory ("there is a `legacy/` directory that contains a fork of an older language version of the same project"). Surprises here often surface as carry-over hazards in section 9.

**Length guide.** Half a page to a page. Detailed enough to substitute for `ls -R /source` in the architect's head; not so detailed that it duplicates the source tree.

**Good content.** Concrete counts and names. "tests/ contains 47 .py files; coverage looks broad but no integration tests beyond unit level."
**Bad content.** Vague aggregates. "The project has tests" is useless. Either count them, or say "tests/ is absent."

---

## Section 3 — Code structural review

**Purpose.** Hold the **code migration agent**'s findings. The code migration agent performs structural review against the target platform's toolchain — entry points, module boundaries, dependency surface, declared-dependency resolution, suspected complexity hot spots — and produces a survey report at `briefs/onboarding/code-migration.report.md`. Phase 3 of the onboarder reads that report and integrates its findings into this section.

**Phase-1 draft state.** Section 3 of `handover.draft.md` is a single placeholder line (`_TODO: code migration agent dispatching — phase 3 fills this in from the migration report._`). Do not draft content into it during phase 1; phase 3 reads the placeholder and replaces it. The placeholder also lets a reader of the draft see that phase 3 is pending and the draft is not the final handover.

**Phase-3 fill-in.** In phase 3, replace the placeholder with a summary of the migration report:
- **Per-component intent.** One bullet per top-level subtree the agent inspected: inferred purpose, language(s), apparent state. Lift these from the report's §2.
- **Structural completeness.** Headline outcome of the agent's probes (import graph closure, dependency resolution, orphans, dangling references, stale directories) from the report's §3. Short — the report has detail.
- **Findings.** The agent's severity-graded findings (HIGH / LOW / INFO; framed for-architect's-attention, not gate-shaped) from the report's §4. Carry each one across with its location, evidence pointer, and suggested next-step framing.
- **Reference.** A trailing pointer to `briefs/onboarding/code-migration.report.md` for deeper reads. The report is preserved on disk indefinitely; do not duplicate it wholesale.

If the migration report's operational notes (§5) or open questions (§6) cross-reference into other handover sections (e.g. a vendored upstream → §9 carry-over hazards, an inferred decision → §5 SHARED-STATE.md candidate), integrate those during phase-3 cross-integration.

**Length guide.** Half a page to a page, depending on what the migration report surfaced. Long enough that the architect gets the structural picture from the handover alone; short enough that the report (not this section) carries the full detail.

**Good content.** "The agent surveyed five top-level subtrees and surfaced one HIGH finding (typo'd dependency `requestz` at `requirements.txt:14`, likely `requests`) and two LOW findings (orphan files in `tools/legacy/` — operator confirmed deliberate, see §9). Full report at `briefs/onboarding/code-migration.report.md`."
**Bad content.** A code review. The agent surveys structure; section 3 summarises that survey. Pointers + headline findings only.

---

## Section 4 — History review

**Purpose.** Hold the slot for the **history migration agent**'s findings (Section C). The history migration agent will reconstruct project history from preserved transcripts and agent-produced artifacts (types 3 and 4) so the architect inherits not just the code but the prior decisions, abandoned approaches, and live constraints.

**In the current substrate (Section A only):** the history migration agent does not exist. Fill this section based on type:

- **Type 1:** `N/A (type 1 — code only, no history materials).`
- **Type 2:** A bulleted summary of any human notes / Q&A transcripts found at `/source`, with file paths. No deep reconstruction — pointers only.
- **Type 3 / 4:** An operator-acknowledged note: "No automated history reconstruction run; sub-agent ships in Section C." Plus a pointer-level summary of the transcripts and artifacts found (paths, rough date range if visible, headline topics if scannable in a single pass).

**Length guide.** Type 1: one line. Type 3/4: a paragraph or two, pointer-style.

**Good content.** "/source/agent-transcripts/ contains 23 conversation logs dating 2025-03–2025-09; topics span auth design, the db migration to Postgres, and an abandoned worker-pool refactor."
**Bad content.** A retelling of the project's history. You did not reconstruct it; you observed that materials exist for the future history migration agent to reconstruct from.

---

## Section 5 — SHARED-STATE.md candidate

**Purpose.** Propose an initial draft of the architect's working memory document. The architect owns `SHARED-STATE.md`; you are giving them a starting point so their first session is not spent staring at a blank file.

**Must contain.**
- Decisions you inferred from the code or were told by the operator during elicitation.
- Interfaces visible at the source level — public API endpoints, library boundaries, data shapes.
- Invariants that are clearly load-bearing — "the `User.id` is a UUID v4, used as the primary key everywhere", "config is read from `${PROJECT_HOME}/config.yaml` and nowhere else".
- Deferred items and known tradeoffs the operator mentioned.

**Mark the whole section clearly as a candidate.** Suggested opening line: *"This is a candidate `SHARED-STATE.md` for the architect to refine and adopt. The architect owns the final version; treat every entry below as a hypothesis the architect should validate against the code in their first session."*

**Length guide.** A page to two pages. Dense, structured, scannable. Mirror the eventual shape of `SHARED-STATE.md` — short headings, bulleted entries.

**Good content.** Specific, observable facts that the architect can verify with `grep` or a single file read. Tradeoffs named, not euphemised.
**Bad content.** Aspirations ("the system should…"), or speculation about decisions the operator never mentioned and the code does not display.

---

## Section 6 — TOP-LEVEL-PLAN.md candidate

**Purpose.** Propose an initial draft of the project's top-level plan. As with section 5, the architect (with the human) ratifies; you are giving them a starting point.

**Must contain.**
- The project goal as you understood it from the elicitation pass. State it as a single specific objective.
- Suggested first 2–3 sections in dependency order, each named with a slug (`s001-<slug>`), with a one-paragraph rationale per section.
- For each suggested section: what its definition-of-done looks like at a high level (not a section brief — just enough that the architect can see where you were aiming).

**Mark the section clearly as a candidate.** Suggested opening line: *"This is a candidate `TOP-LEVEL-PLAN.md`. The architect and human ratify the final version; the section breakdown below is a proposal grounded in the source materials and the operator's stated priorities (§8)."*

**Length guide.** Half a page to a page. Three suggested sections, well-justified, beats six suggested sections in passing.

**Good content.** Sections that are scoped to plausibly-deliverable units. Dependencies stated explicitly. Rationale that traces back to either the source materials (§2) or the operator's priorities (§8).
**Bad content.** A roadmap. You are proposing the first move or two, not the whole game.

---

## Section 7 — Known unknowns

**Purpose.** Explicit questions you could not resolve from the materials or the elicitation pass. These become the architect's first agenda items with the human.

**Must contain.**
- A bulleted list of unresolved questions, each phrased so the architect knows what answer would change which downstream decision.
- For each: where you looked, what you tried to elicit, why it remained unresolved (operator did not know / not in materials / requires deeper analysis than onboarding scope).
- Anything you discovered too late in the session to fully integrate — flag it here rather than dropping it.

**Length guide.** As long as the unknowns are real. Three honest unknowns beats ten cosmetic ones.

**Good content.** "Is the `legacy/` directory actually used at runtime, or is it dead code? Operator was unsure; no obvious importer in `cmd/` but a build-tag search would resolve it. **Decision impact:** whether s001 should rip it out or leave it."
**Bad content.** Performative humility. If you actually know something, write it down in section 5 or 6 instead of pretending uncertainty.

---

## Section 8 — Operator's stated priorities

**Purpose.** Preserve what the human told you during elicitation — goals, constraints, non-goals, hard requirements, soft preferences, anything they want the architect to know on day one.

**Must contain.**
- Goals: what the operator wants the project to become. Quote the operator's framing where useful.
- Hard constraints: things that must not change, things that must hold. "Must remain compatible with Python 3.10." "Must not introduce new external service dependencies."
- Soft preferences: things the operator would prefer, framed honestly as preference rather than constraint.
- Non-goals: things explicitly out of scope ("we are not modernising the frontend in this rewrite").
- Stakeholder context if the operator volunteered it ("this is a side project, no users yet" vs. "this is in production for ~500 daily-active users").

**Length guide.** Half a page. Direct, attributed, no editorialising.

**Good content.** Operator's own words where possible, with light cleanup for clarity.
**Bad content.** Your inferences about what the operator probably wants. Inferences belong in section 5 or 6, with the source of inference named.

---

## Section 9 — Carry-over hazards

**Purpose.** Anything you noticed during onboarding that doesn't fit elsewhere but the architect should know about — landmines, surprising couplings, things that look like they will bite future planners or coders.

**Must contain.**
- Each hazard as its own bullet. Describe what it is, where you saw it, and why it might matter.
- If a hazard is speculative (you saw a pattern that *suggests* a problem but did not confirm), say so honestly.
- Anything from the source materials that contradicts itself — README claims X, code does Y.

**Length guide.** Open-ended. Most onboardings will surface two to five real hazards. If you have none, write "None observed." rather than padding.

**Good content.** "The auth module appears to read a shared secret from `os.Getenv("AUTH_SECRET")` in three different files without any wrapper. Refactoring this is likely to be a recurring pain in any auth-touching section."
**Bad content.** Wish lists ("the test coverage could be better"). Hazards are concrete, not aspirational.

---

## Confidence calibration

Across all nine sections, mark observations explicitly when confidence is partial:
- **"Confirmed"** — you read it in the source or the operator stated it.
- **"Inferred"** — you derived it from multiple signals; reasonable to act on but not certain.
- **"Speculative"** — you saw one signal and extrapolated; the architect should re-check before acting.

This calibration is more important than thoroughness. The architect will treat your handover as ground truth on first read; the calibration markers tell them where to push back.

## Commit message

When you commit the handover, use the message `onboarding: handover brief` exactly. The architect's entrypoint and any tooling that scans for the onboarding commit relies on this string.

## File ownership

You write this file once and never edit it again. The architect may refine it later by *referencing* it from `SHARED-STATE.md`, but the historical onboarding handover is itself preserved as an artifact. Future re-onboarding (a hypothetical v2 feature, not in scope today) would produce a new handover, not overwrite this one.
