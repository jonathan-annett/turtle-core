# Hierarchical Ephemeral Agent Orchestration

A generic, project-agnostic methodology for executing software projects with AI agents. One human and one persistent overseer agent share full context; everything else is an ephemeral specialist commissioned for one job.

**Version 2.4.** Per-section platform composition. The top-level plan declares a project-wide platform superset under `## Platforms`; section and audit briefs may declare an optional `Required platforms` subset. The substrate composes a hash-tagged role image carrying those platforms at commission time, and validates that every Bash-anchored binary in the brief's tool surface is present on the composed image's PATH. Sections inherit the project superset when silent; the subset is enforced (section ⊆ project). Migration from v2.3 is graceful: substrates that lack `## Platforms` fall back to the `.substrate-state/platforms.txt` record from setup. See §7.1, §7.2, §7.6, §9.

**Version 2.3.** Onboarder role added for brownfield-project migration. A new pre-architect, single-shot, project-scoped role ingests existing source materials, elicits operator priorities interactively, and produces a handover brief at `/briefs/onboarding/handover.md` that the architect adopts on its first attach (see §4 "Onboarder" and §8 step 0). Greenfield projects skip the onboarder. This version also makes explicit the foundational principle that **the architect is the only role with persistent context across a project** — planners, coders, and auditors begin each assignment with a clean window (see §4 "Architect"); the onboarder exists specifically to ease the only role onboarding can ease.

**Version 2.2.** Tool-surface mechanism extended symmetrically up the role hierarchy: section briefs (architect → planner) and audit briefs (architect → auditor) now carry a "Required tool surface" field with the same shape and semantics as the task-brief field already specified in §7.3. The substrate translates each brief's field into the receiving role's `--allowedTools` at commission time; absent or unparseable → fail clean. See §7.2, §7.6, §9.

**Version 2.1.** Substrate model revised: when all agents run on a shared host (typical for VPS, local-server, or laptop deployments), the methodology uses a single git substrate with role-isolated boundaries, and the Drive layer is dropped. Three deployment variants (Docker, linux users, cloud-Drive legacy) are described in §3.4–§3.6, satisfying the per-role access table in §3.3.

---

## 1. Purpose

To deliver projects of arbitrary scale while keeping context bounded, work auditable, and human oversight meaningful. The pattern enforces three things:

- **Context discipline.** No agent sees more than its job requires.
- **Token economy.** Heavy work happens at the leaves; supervision stays light.
- **Auditability.** Every step has a paper trail; nothing reaches `main` unaudited.

---

## 2. Core principles

1. **Single source of truth.** Only the human and the *architect* hold the full picture.
2. **Ephemerality.** Planners, coders, and auditors are spun up for one assignment, return a report, and discharge. They are not reused.
3. **Brief in, report out.** The only inter-agent channel is a structured brief downward and a structured report upward.
4. **Audit gate.** No section reaches `main` until an independent auditor signs off and the human approves.
5. **Recursion.** The brief/report contract is identical at every level. Depth is set by project size, not by the framework.
6. **Human veto, always.** Any ephemeral agent can be killed by the human at any time. Runaway token use or unproductive looping is grounds for termination and re-commissioning.
7. **Boundaries enforced at the OS, not the prompt.** Where multiple agents share a host, role boundaries are enforced by user separation and access controls, not by trusting agents to honor discipline. Discipline is necessary but not sufficient.

---

## 3. Substrate

The substrate is **the main project repository plus a private auditor repository**, both standard git. Coordination artifacts (briefs and reports) live in the main repo alongside the code they describe; there is no separate coordination layer.

The methodology requires *boundaries*, not specific tools to implement them. §3.1 and §3.2 define the substrate's logical shape; §3.3 defines the per-role access table that any deployment must enforce; §3.4 through §3.7 describe three deployment variants that satisfy those boundaries with progressively weaker guarantees.

### 3.1 Main repository — work-product and coordination

A single repository holds:
- All source code.
- All briefs and reports (section and task), under `/briefs/`.
- The top-level plan and the shared-state document at the repo root.
- Migration artifacts (when applicable) at the repo root.

This is the durable, diff-able trail. Briefs sit next to the code that fulfilled them, forever. Section reports are reference material that any agent (with appropriate access) can read.

### 3.2 Auditor repository — adversarial private layer

- Private to the auditor and the human.
- Contains test tooling, fuzzing harnesses, stress scripts, and exploratory probes the auditor builds.
- **Never merges into the main repo.** The audit is adversarial; the red team gets privacy.
- The auditor has **read-only** access to the main repo at section-branch tips.
- The auditor's audit report is produced into the auditor repo first, then ferried into the main repo by the architect (see §3.8).

### 3.3 Per-role access table — the contract every deployment must enforce

| Role | Read access | Write access |
|---|---|---|
| `architect` | main repo (all paths); auditor repo (read-only, for fetching audit reports) | main repo: `/briefs/**`, root coordination files (`SHARED-STATE.md`, `TOP-LEVEL-PLAN.md`, etc.) only. May push to `main` directly for these paths; the human reviews via watching the log. |
| `planner` | main repo (all paths) | main repo: `section/*` and `task/*` branches only. May not push to `main`. |
| `coder` | main repo (all paths within their assigned section branch) | main repo: their assigned `task/*` branch only. |
| `auditor` | main repo (read-only at section branch tips); auditor repo (full) | auditor repo only. Cannot push to main repo at all. |
| `onboarder` | main repo (all paths); brownfield source materials at `/source` (read-only mount, not the main repo) | main repo: `refs/heads/main` only (any path under it, by hook). Policy is single-shot per project: the operator-side entry script enforces this by inspecting `main.git`'s state before any push. No access to the auditor repo. |
| `human` | everything | everything; merges section branches into `main`. |

Any deployment satisfies the methodology if and only if it enforces this table by mechanism, not by trust. An agent that errs (or is misled by content in its inputs) must be unable to write to a path or repo it has no permission on.

### 3.4 Deployment variant A: Docker (recommended)

Docker is the recommended deployment because it gives the strongest boundaries with the least operational overhead and runs identically on Linux, macOS (via Docker Desktop or Colima), and Windows (via Docker Desktop with WSL2). It also templates trivially: a single `docker-compose.yml` per project defines the substrate, and a new project starts with one file copy.

The shape:

- **A `git-server` container** holding bare repos for the main project and the auditor work. Acts as the canonical git origin for all role containers.
- **An `architect` container** (long-lived; restartable) with a working clone of the main repo. Bind-permissioned via SSH key or token to push only to `/briefs/**` and root coordination paths.
- **A `planner` container** spun up per section, started with `docker compose run --rm`. Disposed on discharge. Has push permission scoped to `section/*` and `task/*` branches.
- **A `coder` container** spun up per task, also `--rm`. Push permission scoped to its assigned task branch.
- **An `auditor` container** spun up per audit. Read-only checkout of the main repo's section branch; read/write working clone of the auditor repo. No route to main repo write at all.
- **A `human` host shell** (or a dedicated container) with full access. The human runs commissioning commands and merges from here.

Why this is strongest: containers without a volume mount cannot see paths outside their mount; containers on isolated networks cannot reach the main repo's bare repository at all. The "auditor cannot push to main" guarantee becomes "the auditor container has no network route to the main repo's git remote" — categorically harder to violate than a permission check.

Practical details (Dockerfiles, the compose file, volume conventions, auth flow for Claude Code per role) live in a companion document, `deployment-docker.md`. The spec deliberately stays out of those details so future deployment options (Kubernetes, Nix, sandboxed VMs) can have their own companions without bloating the spec.

Cross-platform notes for the recommended variant:
- **Linux:** native Docker. Lowest overhead. Bind mounts and named volumes both performant.
- **macOS:** Docker Desktop or Colima both wrap a Linux VM. I/O across the host↔VM boundary is slow for large file trees; keep working clones in named volumes rather than bind-mounted from the host filesystem. Allocate enough VM memory (8GB minimum is sane for three or four concurrent containers).
- **Windows:** Docker Desktop with the WSL2 backend. Same VM model as macOS. Avoid bind-mounting Windows-side paths; use named volumes. Documentation for human-driven shell commands should accommodate PowerShell as well as bash.

### 3.5 Deployment variant B: Linux users on bare metal (fallback)

When Docker is not available — bare-metal deployments without containerization, or environments where the operator prefers OS-level rather than container-level isolation — the methodology can be satisfied with linux user accounts:

- One linux user per role: `architect`, `planner`, `auditor`, `coder`. (One shared `coder` user is acceptable; coders are ephemeral and operate on disjoint task branches.)
- A separate `human` (or admin) user with full access.
- A bare git repo for the main project on the same host (filesystem path or `git://localhost`); a similar bare repo for the auditor's private work.
- Server-side hooks (or a tool like gitolite) on the bare main repo enforce the per-role write rules from §3.3.
- Filesystem permissions on per-user working clones prevent agents from reading or writing into other agents' working copies.

This satisfies the access table but with weaker isolation than containers: a misconfigured ACL or stray group membership can leak access in ways volume mounts cannot. Treat it as the fallback for environments that cannot run Docker.

### 3.6 Deployment variant C: Cloud architect with Drive (legacy)

If the architect runs in a cloud chat interface (without native git access), the substrate splits across Drive and the main repo, as in v1 of this spec:

- Drive: all coordination artifacts (briefs and reports). Architect's working surface.
- Main repo: code plus mirrored copies of briefs and reports.
- The mirror burden falls on the planner.

This variant is documented for compatibility. It is the weakest of the three on boundary enforcement: the cloud architect's writes go through Drive, which has no per-path access controls equivalent to git hooks or volume mounts. The methodology's discipline (architect doesn't touch source code) is enforced by prompt rather than by mechanism.

Use this variant only when the architect cannot run locally. Once a local architect is viable, migrate to variant A or B.

### 3.7 Selection guidance

| Situation | Choose |
|---|---|
| New project, any platform, agents run locally | Variant A (Docker). Cross-platform portability and strongest boundaries. |
| Existing Linux-only deployment, no Docker available | Variant B (linux users). |
| Architect must run in cloud chat; only some agents run locally | Variant C (Drive), or hybrid: cloud architect with Drive, local planners/coders/auditors via variant A or B. |
| Distributing the methodology to other engineers on mixed Mac/Windows/Linux | Variant A (Docker). |

### 3.8 Audit report flow

Because the auditor cannot write to the main repo:

1. Auditor produces the audit report inside the auditor repo (at an agreed path, e.g. `/reports/sNNN-slug.audit.report.md`) and discharges.
2. Architect reads the audit report from the auditor repo (architect has read access; see §3.3).
3. Architect commits a copy to the main repo at `/briefs/sNNN-slug/audit.report.md`.
4. Architect and human decide pass / conditional pass / rework.

The auditor repo is the durable source of the audit; the main repo carries the canonical copy that the project's history references.

### 3.9 Why one substrate (regardless of deployment variant)

- Single source of truth. No "is the Drive copy current?" failure mode (variants A and B; variant C still has this).
- Diff-able coordination. `git log /briefs/` shows how a brief evolved.
- Reproducible setup. The whole substrate can be templated — a `docker-compose.yml` for variant A, a setup script for variant B — so a new project starts with one command.
- No mirroring overhead in the lifecycle (variants A and B).

---

## 4. Roles

### Architect (persistent, paired with human)
- Co-develops the top-level plan with the human.
- Holds full project context across all sections.
- Commits section briefs and audit-brief copies to the main repo at `/briefs/sNNN-slug/`.
- Reads section reports from the main repo. Reads audit reports from the auditor repo.
- Maintains a living shared-state document (decisions, interfaces, invariants) at the main repo root.
- May write only to `/briefs/**` and root coordination files. Cannot touch source code.
- Is the only agent the human routinely interacts with.

**The architect is the only role with persistent context across a project.** Planners, coders, and auditors each begin every section (or task, or audit) with a clean context window and only the inputs in their brief — they have no inherited project memory by design. The architect, by contrast, carries `SHARED-STATE.md` and `TOP-LEVEL-PLAN.md` across the whole project and is rehydratable from those two documents if its session is ever lost. This asymmetry is foundational to the methodology's role economy: context lives where coordination needs it; ephemeral roles stay cheap and stateless. It also explains why migration onboarding (see "Onboarder" below) exists at all — to ease the only role onboarding *can* ease.

### Planner (ephemeral, terminal-based, one per section)
- Started by the human with a pointer to a brief filepath in the main repo.
- Reads the section brief, then operates in the main repo on the section branch.
- Creates the section branch.
- Decomposes the section into task briefs, committing each to the section branch under `/briefs/sNNN-slug/`.
- Commissions a fresh coder per task by handing it the section branch name and the task brief path.
- Receives task reports via PR; merges PRs into the section branch.
- Writes the section report to `/briefs/sNNN-slug/section.report.md` on the section branch.
- Discharges.
- May commission a sub-planner for large or compound tasks. Recursion is permitted.

### Coder (ephemeral, terminal-based, one per task)
- Given a section branch name and a task brief path by the planner.
- Pulls the section branch, creates its task branch, reads its brief.
- Performs the heavy work: reading, writing, testing, diagnosing, iterating.
- Commits code and a task report (`/briefs/sNNN-slug/tNNN-slug.report.md`) to its task branch.
- Opens a PR back to the section branch.
- Discharges. Never reused.

### Auditor (ephemeral, one per section, independent)
- Receives the audit brief via a path in the main repo (handed by the human, who has read access).
- Has read access to the main repo at the section branch tip.
- Has read/write access to the auditor repo.
- May write code (test harnesses, stress scripts, probes) in the auditor repo only.
- Produces the audit report in the auditor repo. May recommend or include suggested patches as diffs in the report — but **cannot mutate the main codebase or commit to the main repo.**
- Discharges.

### Onboarder (ephemeral, one per project, single-shot, pre-architect)
- Exists only for brownfield projects being migrated into the methodology. Greenfield projects skip this role entirely; the architect attaches directly to an empty `main` and produces `SHARED-STATE.md` and `TOP-LEVEL-PLAN.md` from scratch with the human.
- Started by the human via the operator-side onboarding script (the deployment variant supplies its name; for variant A it is `./onboard-project.sh <source-path> [--type 1|2|3|4]`).
- Receives the brownfield source materials via a read-only mount (not committed yet at the time the onboarder starts; the onboarding script imports them as the first commit on `main` immediately before the onboarder is launched, so the working copy reflects the migrated state from the onboarder's first read).
- Reads the source materials, builds a synthesis of project identity, scope, stack, and observed methodology state, classifies the project by the four-type taxonomy (1: code only / 2: +human notes / 3: +agent history / 4: +informal methodology), and enters an **interactive elicitation loop with the operator** — questions in batches of two or three at a time, refining the synthesis between rounds, until the unknowns are stable.
- Produces exactly one artifact: the handover brief at `/briefs/onboarding/handover.md` in the main repo. The brief contains nine sections (project identity; source materials inventory; code structural review; history review; SHARED-STATE.md candidate; TOP-LEVEL-PLAN.md candidate; known unknowns; operator's stated priorities; carry-over hazards) per the canonical template.
- May commission **sub-agents** — the *code migration agent* (structural code review against the target platform) and the *history migration agent* (reconstruction from preserved transcripts and artifacts, for types 3 and 4). These sub-agents are descriptive-name sub-roles whose scope lives inside the onboarder's run, distinct in name from the profession-name top-level roles. The shell version of the onboarder ships **without** these sub-agents; they are added in follow-on sections of the substrate work. Until then, sections 3 and 4 of the handover brief are filled by the onboarder itself with operator-acknowledged "no automated review run" notes plus pointer-level observations from a single read-through.
- May write only to `/briefs/onboarding/handover.md` on `main` (plus the upstream source-tree import commit performed by the operator-side entry script under the same identity). Cannot touch source code paths after the import; cannot touch the auditor repo at all.
- Single-shot per project — there is no re-onboarding pattern. If a project genuinely needs to be re-onboarded, the operator tears the substrate down and creates a new one. This constraint is enforced by the operator-side entry script, which inspects `main.git`'s state before any commit and refuses to run if the project is past the initial empty commit.
- Discharges. Its container is removed. Its output (the handover brief) is consumed by the architect on first attach; see §8.

### Human
- Sets and owns the goals.
- Ratifies the top-level plan.
- Starts each ephemeral agent by handing off the appropriate brief filepath.
- Approves or rejects at every section boundary; performs the section→main merge.
- Vetoes any agent showing runaway behaviour, looping, or unproductive output.

---

## 5. Repository structure

In the main repo:

```
/briefs/
  s001-authentication/
    section.brief.md
    section.report.md
    audit.brief.md
    audit.report.md
    t001-data-model.brief.md
    t001-data-model.report.md
    t002-login-screen.brief.md
    t002-login-screen.report.md
    ...
  s002-...
SHARED-STATE.md
TOP-LEVEL-PLAN.md
README.md
<source tree>
```

Conventions:
- Sections numbered `sNNN`, tasks numbered `tNNN`. Zero-padded so files sort correctly indefinitely.
- Slug after the number for human readability.
- Suffixes `.brief.md` and `.report.md` make grep/glob trivial (`**/*.report.md` retrieves every report ever).
- Brief and report are sibling files, never a single document.
- Audit brief and audit report sit alongside the section brief and section report.
- Every brief is committed before the receiver begins; every report is committed by the receiver before discharge.

In the auditor repo: layout is at the auditor's discretion. The architect may suggest conventions, but the auditor's working directory is its own concern. The audit report is produced in a known location agreed at project setup (e.g. `/reports/sNNN-slug.audit.report.md`) so the architect can find it.

---

## 6. Branch strategy

In the main repo:

- `main` is protected against pushes from non-`human` users for all paths *except* the architect's allowed coordination paths. Only audited, approved section branches merge in.
- **Section branch:** `section/NNN-slug`, branched off `main` at section start. This is the audit boundary — the auditor evaluates exactly its tip.
- **Task branch:** `task/NNN.MMM-slug`, branched off the section branch. Coder works here.
- Coder opens a PR from task branch into section branch.
- **Planner merges task PRs**, not the coder. The planner has section context; the coder is already discharging.
- Section branch merges to `main` only after audit pass + human approval. The **human** performs this merge.
- **Audit fail:** the section branch is *not* reset. Architect writes a remediation brief that includes the audit findings and a fresh planning scope. A new planner is started, creates fresh task branches off the same section branch, and patches forward.

The architect's coordination-only commits to `/briefs/**` go to `main` directly (or to a dedicated `coordination/*` branch that the human merges, depending on operator taste). They do not gate on audit because they are not work product.

---

## 7. Artifacts

Every artifact is a structured markdown document. The templates below are minimums; expand as needed but do not omit.

### 7.1 Top-level plan
Owned by architect + human. Lives at the main repo root: `TOP-LEVEL-PLAN.md`.
- Project goal and scope.
- Section list, in dependency order.
- Section-level success criteria.
- Repo URLs (main + auditor).
- **Platforms (project superset).** An optional `## Platforms` section declaring the full set of target-language platforms the project may need across all sections. Same fenced grammar as the tool-surface field (YAML simple list or JSON array, platform names from `methodology/platforms/<name>.yaml`). This is the **superset** that all section-level "Required platforms" declarations must be a subset of. If absent, the substrate falls back to the substrate's setup-time platform selection (recorded at `.substrate-state/platforms.txt` per `methodology/deployment-docker.md` §10), so projects predating v2.4 continue to work unchanged.

### 7.2 Section brief (architect → planner)
Path: `/briefs/sNNN-slug/section.brief.md`. Architect commits.
- **Section ID and slug.**
- **Objective.** What the section must achieve.
- **Available context.** What exists in the project the planner can rely on, with pointers (branches, files, prior section reports).
- **Constraints.** Security posture, performance budgets, conventions, technologies, scope boundaries.
- **Definition of done.** Concrete, checkable criteria.
- **Out of scope.** Explicit non-goals.
- **Repo coordinates.** Base branch (`main`), section branch name to create.
- **Required tool surface.** An explicit list of Claude Code tools and tool-scoped patterns the planner is permitted to use during this section — typically `Read`, `Edit`, and `Write` for authoring task briefs and the section report, plus `Bash` with patterns for the git operations the planner needs (`Bash(git checkout:*)`, `Bash(git branch:*)`, `Bash(git commit:*)`, `Bash(git push:*)`, `Bash(git merge:*)`), plus any commission-loop commands the planner uses (e.g. `Bash(curl:*)` for daemon HTTP calls). Same shape and semantics as the task-brief field in §7.3. The substrate translates this list into the planner's `--allowedTools` at commission time; if the field is absent or unparseable, the planner entrypoint fails clean with an actionable error rather than silently denying or defaulting permissive.
- **Required platforms (optional override).** An optional list of target-language platforms the section needs in dispatched-agent images. Same fenced grammar as the tool-surface field, with platform names from `methodology/platforms/<name>.yaml` (e.g. `node-extras`, `python-extras`). If present, the section's set must be a **subset** of the project superset declared in TOP-LEVEL-PLAN.md's `## Platforms` section (§7.1); declaring a platform outside the superset fails commission with a clear error. If absent, the section inherits the full project superset. The substrate composes a hash-tagged role image carrying the resolved set at commission time, and validates every Bash-anchored binary in the tool surface is present on the composed image's PATH. See `methodology/architect-guide.md` for the decomposition discipline (TDD-with-mocks default; multi-platform sections as explicit exception).
- **Reporting requirements.** What the section report must contain.

### 7.3 Task brief (planner → coder)
Path: `/briefs/sNNN-slug/tNNN-slug.brief.md`. Planner commits to section branch.
- **Task ID and slug.**
- **Section context.** One paragraph: what the section is doing, where this task fits.
- **Objective.** Single specific task.
- **Required context.** Files, interfaces, prior decisions, links to relevant section state. Be exhaustive — assume the coder knows nothing project-specific.
- **Touch surface.** Which files/modules may be modified; which must not be.
- **Required tool surface.** An explicit list of Claude Code tools and tool-scoped patterns the coder is permitted to use for this task — e.g. `Read`, `Edit`, `Write` scoped to the touch surface, `Bash` with an allowlist of command patterns (`git *`, project test/build commands). The substrate translates this list into the coder's `--allowedTools` at commission time. (The same field shape is required at the section-brief and audit-brief level for the planner and auditor; see §7.2 and §7.6.)
- **Constraints.** Inherited from section brief plus task-specific ones.
- **Verification.** Tests to write or run; checks to perform.
- **Branch coordinates.** Section branch to base from; task branch name to create.
- **Reporting requirements.** What the task report must contain.

### 7.4 Task report (coder → planner)
Path: `/briefs/sNNN-slug/tNNN-slug.report.md`. Coder commits to task branch.
- **Brief echo.** One paragraph: what the coder understood the task to be. (Catches misinterpretation early.)
- **What was done.** Concrete actions, file by file.
- **Verification results.** Test output, manual checks, evidence.
- **Discoveries.** Things found during the work that the brief did not anticipate.
- **Assumptions made.** Decisions taken without explicit guidance.
- **Deferred or punted.** Anything the coder did not do, with reasoning.
- **Open questions.** Unresolved issues for the planner.

### 7.5 Section report (planner → architect)
Path: `/briefs/sNNN-slug/section.report.md`. Planner commits to section branch.
- **Brief echo.** Restatement of section objective.
- **Summary of work.** What was built across all tasks.
- **Aggregate surface area.** Files touched, interfaces introduced or changed.
- **Verification status.** What is tested, what is not.
- **Risks and open issues.**
- **Suggested next steps and dependencies for downstream sections.**
- **Pointers to all task reports** (do not inline; reference paths).

### 7.6 Audit brief (architect → auditor)
Path: `/briefs/sNNN-slug/audit.brief.md`. Architect commits to `main` (coordination commit).
- **What was specified.** Reference to (or copy of) the section brief.
- **What was reportedly built.** Reference to the section report and to the section branch tip.
- **Specific concerns to investigate.** Adversarial prompts: "look for X", "verify Y cannot happen". The architect should be aggressive here.
- **Sign-off criteria.** Explicit, binary pass/fail conditions.
- **Required tool surface.** An explicit list of Claude Code tools and tool-scoped patterns the auditor is permitted to use during the audit — typically `Read` over the section-branch checkout and methodology docs, `Edit` and `Write` scoped to the auditor repo for the audit report and any private tooling, `Bash` with patterns for read-only inspection of `/work` (e.g. `Bash(git log:*)`, `Bash(git diff:*)`) and for the verification commands the audit requires (test runners, build commands, static analysers, HIL access via `Bash(ssh <remote-host>:*)` where the project has registered remote hosts). Audit briefs may legitimately need different surfaces from section briefs. Same shape and semantics as the task-brief field in §7.3. The substrate translates this list into the auditor's `--allowedTools` at commission time; if the field is absent or unparseable, the auditor entrypoint fails clean with an actionable error.
- **Required platforms (optional override).** Same field as in the section brief (§7.2); optional, subset of TOP-LEVEL-PLAN.md's project superset (§7.1). Audit briefs may legitimately need a different platform set from the section brief — e.g. an audit that only inspects firmware artifacts on a Node-server-plus-ESP32 project may declare just `platformio-esp32` to avoid pulling node tooling into the auditor image. The substrate composes the auditor image with the resolved set and validates the audit brief's tool surface against it.
- **Auditor repo coordinates.** Where the audit report should land in the auditor repo.

### 7.7 Audit report (auditor → architect + human)
Produced by auditor at agreed path in auditor repo. Architect copies to `/briefs/sNNN-slug/audit.report.md` in main repo.
- **Per-criterion verdict.** Pass / fail / inconclusive, each with evidence.
- **Issues found.** Severity, location, suggested remediation.
- **Recommendation.** Sign off / sign off with conditions / send back for rework.
- **Optional patches.** Suggested code changes, included as diffs in the report. Auditor does not commit them.
- **Sign-off statement.** A single explicit line.

### 7.8 Shared-state document
Path: `SHARED-STATE.md` at main repo root. Architect maintains.
- New interfaces introduced or changed.
- Design decisions and the reasoning behind them.
- Invariants the project must maintain.
- Deferred items and known tradeoffs.
- Caveats from conditional audit passes.

This is the architect's durable working memory. A fresh architect, given only this file plus the top-level plan, must be able to resume the project.

---

## 8. Lifecycle

0. **(Brownfield projects only) Onboard.** Before the architect attaches for the first time, the human runs the operator-side onboarding script. The onboarder imports the brownfield source tree as the initial commit on `main`, synthesises and elicits with the operator, and produces the handover brief at `/briefs/onboarding/handover.md`. On the architect's first attach, the substrate's architect entrypoint detects the handover (and the absence of `SHARED-STATE.md` — first-attach signal) and seeds the architect's first claude session against it, so step 1 below begins from the synthesis the onboarder produced rather than from a blank slate. Greenfield projects skip step 0 entirely.
1. **Plan.** Human and architect produce `TOP-LEVEL-PLAN.md` at the main repo root.
2. **For each section** (default serial; parallel only when the architect declares two sections to be in fully unrelated areas, with the human's agreement):
   1. Architect writes the section brief and commits to `main` at `/briefs/sNNN-slug/section.brief.md`.
   2. Human starts a fresh planner agent in the planner role (per the deployment variant in use — a Docker container, a linux-user shell, etc.), handing it the brief filepath.
   3. Planner creates the section branch in the main repo.
   4. Planner decomposes the section. For each task:
      - Planner writes the task brief and commits it to the section branch.
      - Planner names the task branch and commissions a fresh coder.
      - Coder pulls the section branch, creates its task branch, reads the brief, executes, commits code and report, opens PR.
      - Planner reviews PR, merges into section branch.
   5. Planner commits the section report to the section branch and discharges.
   6. Architect reads the section report from the section branch, writes the audit brief, commits to `main` at `/briefs/sNNN-slug/audit.brief.md`.
   7. Human starts a fresh auditor agent in the auditor role, handing it the audit brief filepath.
   8. Auditor reads the brief, accesses the main repo (read-only) at the section branch tip, builds tooling in the auditor repo as needed, writes the audit report into the auditor repo, and discharges.
   9. Architect reads the audit report from the auditor repo and commits a copy to `/briefs/sNNN-slug/audit.report.md` in the main repo.
   10. Architect and human review the audit report.
       - **Pass:** human merges the section branch into `main`. Architect updates `SHARED-STATE.md`. Proceed to next section.
       - **Fail:** architect writes a remediation brief (audit findings + scope), commits to the section's `/briefs/sNNN-slug/` directory on `main`. Re-enter at step ii with a new planner. The same section branch is reused; new task branches address the issues.
3. **Repeat until the plan is complete.**

---

## 9. Commission mechanics

Every commissioning event has the same shape:

> "Here is a filepath. Read it. Do what it says. Discharge when done."

- **Planner commissioning:** human starts a terminal-based agent in the planner role (per the deployment variant — a fresh Docker container via `docker compose run --rm planner`, a shell as the `planner` linux user, etc.) and supplies the filepath of the section brief in the main repo working tree. The brief itself contains all repo coordinates, branch names, and reporting destinations. The substrate parses the brief's "Required tool surface" field (§7.2) and translates it into the planner's `--allowedTools` at startup; a missing or unparseable field fails the commission cleanly.
- **Coder commissioning:** the planner points a fresh agent in the coder role at the section branch and the task brief path. The task brief contains all coordinates. The substrate parses the brief's "Required tool surface" field (§7.3) and translates it into the coder's `--allowedTools`; a missing or unparseable field fails the commission cleanly.
- **Auditor commissioning:** human starts a fresh terminal agent in the auditor role and supplies the filepath of the audit brief. The brief contains coordinates for the main repo (read), the auditor repo (write), and the report destination. The substrate parses the brief's "Required tool surface" field (§7.6) and translates it into the auditor's `--allowedTools`; a missing or unparseable field fails the commission cleanly.

Briefs are **self-bootstrapping**: receiving the filepath should be enough for the agent to read its instructions and proceed without further conversational setup. The tool-surface translation is uniform across all three role-pair handoffs (architect→planner, planner→coder, architect→auditor) — the field shape is identical, the parser is shared, and the failure mode is the same.

**Platform composition (v2.4).** Before each dispatched-agent commissioning event (planner, coder-daemon, auditor, onboarder), the substrate resolves the agent image's target platforms from the brief's optional "Required platforms" field, the TOP-LEVEL-PLAN.md `## Platforms` project superset, and (as a v2.3-compat fallback) the substrate-setup platform record. It composes a hash-tagged image carrying those platforms, reuses the image across commissions when the declaration is unchanged, and rebuilds only when the declaration or the underlying platform registry changes. After composition and before the agent starts, the substrate also validates that every Bash-anchored binary in the brief's tool surface is present on the composed image's PATH; a missing binary fails commission cleanly with an error naming the missing binaries and the platform set used. Onboarders commission with an empty platform set by design — their work is brief synthesis, not building. The composition does not promise byte-level image reproducibility (upstream apt/pip/npm versions vary between rebuilds); the platform registry entry is the deterministic input, not the rendered image's content bytes.

---

## 10. Veto and failure handling

The human watches all running agents. Any of these conditions warrant termination:

- Token consumption climbing without proportional output.
- Repetitive looping or thrashing on the same problem.
- Drift from the brief.
- Hallucinated context (claiming files or facts that do not exist).
- Attempts to write outside the agent's permitted paths (the OS will already block these; repeated attempts indicate a confused agent).

When an agent is killed:

- **Coder killed mid-task.** Planner abandons the task branch (delete or archive), revises the task brief if needed, commissions a fresh coder. The dead branch may be retained as a learning artifact.
- **Planner killed mid-section.** Section branch is left intact with whatever partial work landed. Architect writes a resumption brief noting the current branch state; human starts a new planner with that brief.
- **Auditor killed mid-audit.** Audit work in the auditor repo is left as-is. Human starts a fresh auditor with a possibly revised audit brief.

The architect itself is persistent and not subject to commissioning. If it shows degradation, the remedy is for the human to start a new architect session and rehydrate it from the top-level plan and shared-state document.

---

## 11. Boundaries and rules

- **No agent reads outside its brief's stated context.** If the brief is incomplete, the receiver flags it and stops rather than guessing.
- **Reports go up, briefs go down. No lateral chatter.** Coders do not talk to other coders. Planners do not talk to other planners.
- **Briefs assume the receiver is blind.** Project-specific knowledge must be supplied or pointed to.
- **Reports must surface what was not done.** Silence is a bug.
- **The auditor evaluates artifacts, not process.** It does not see task reports unless explicitly handed them as evidence.
- **Only the architect mutates the shared-state document.** Planners and coders may recommend; only the architect commits.
- **The auditor never commits to the main repo.** Recommendations only. Enforced by the OS.
- **`main` never contains unaudited code.** Coordination commits to `/briefs/**` are not code and do not gate on audit.

---

## 12. Failure modes and mitigations

| Failure mode | What it looks like | Mitigation |
|---|---|---|
| Telephone game | Detail erodes as information climbs the hierarchy. | Structured templates; architect spot-checks raw artifacts (diffs, logs) directly when possible. |
| Brief drift | Planner re-interprets the section and ships the wrong thing. | Planner must echo the brief at the top of its report. Architect compares echo to original. |
| Coder hallucination | Coder claims work it did not do. | Reports must include verifiable evidence (diffs, test output). PR diffs are checked against report claims at merge. |
| Audit theater | Auditor rubber-stamps. | Audit brief specifies adversarial criteria; auditor is denied access to flattering process narratives. |
| Cross-section coupling | Section N depends on undocumented state from section N−1. | Architect maintains an explicit shared-state document; section reports must propose updates to it. |
| Context starvation | Coder brief is too thin; coder invents context. | Coders refuse and return a "brief insufficient" report rather than guess. |
| Scope creep | Planner expands section; ephemeral agents do extra work. | Planner reports must declare any deviation from the section brief and flag it for architect review. |
| Test-gaming by coder | Coder tunes implementation to known tests rather than spec. | Auditor's adversarial tooling lives in a private repo the coder cannot read. |
| Architect context bloat | The persistent agent slows down or hallucinates as project grows. | Strict reliance on shared-state document and section reports; architect is rehydratable from these alone. |
| Permission drift | An agent writes outside its lane through a bug or misconfiguration. | Boundary enforcement in the deployment (§3.3 access table; mechanism per variant). The agent is denied at the volume, filesystem, or git layer; discipline is a backup, not the primary defense. |

---

## 13. Recursion

The brief/report contract is uniform. A planner facing a section that is itself large enough to warrant decomposition may:

- Treat its section as a mini-project.
- Write sub-section briefs.
- Commission sub-planners (each ephemeral).
- Receive sub-section reports.
- Aggregate into its own section report.

The depth of the hierarchy is a function of project size and complexity, not a fixed property of the framework. The architect may declare in the top-level plan how much recursion is sanctioned; the human approves.

---

## 14. Project-agnostic notes

- The pattern does not specify the language, framework, or domain. Anything that fits the brief/report contract works.
- The substrate (one main repo + one auditor repo, with role-isolated access per §3.3) is the recommended deployment. Docker (§3.4) is the recommended mechanism; linux users on bare metal (§3.5) is a supported fallback; the cloud-architect-with-Drive variant (§3.6) is supported but weaker on boundary enforcement.
- Ephemerality is a feature, not a constraint. It forces explicit handoffs, prevents context contamination, and makes every step independently re-runnable.
- The bottleneck is brief quality. Time spent writing a precise brief is repaid many times over in agent productivity and audit cleanliness.
- The substrate is templatable. A new project can be initialized by a script that creates the two bare repos, configures hooks, adds the four user accounts, and seeds the main repo with the standard root files (`TOP-LEVEL-PLAN.md`, `SHARED-STATE.md`, `README.md`, `/briefs/`).
