# turtle-core update brief — Section A: onboarder shell

## How to read this brief (read first)

**This is a substrate-iteration brief, not a project-methodology
brief.** Section A modifies the substrate itself: it adds a new
top-level role (onboarder), its container and entrypoint, an
operator-side intake script, the handover-brief template the
onboarder produces, and the architect's attach-with-handover
path. It is implemented the same way s001–s011 were implemented:
a single agent on the host, working directly on a section branch,
committing files, pushing, writing a section report, and
discharging. There is no architect, planner, coder, or auditor
involved in implementing Section A.

The brief mentions "architect", "planner", "auditor" and
"onboarder" extensively because those are the names of the
**substrate roles whose entrypoints, scripts, and guides this
section adds to or modifies**. References to "operator running
`./onboard-project.sh`" describe the **runtime behaviour after this
section lands**, not the workflow used to build it.

So: do not commission a planner. Do not invoke
`commission-pair.sh`. Read this brief on the section branch,
implement the tasks directly in the working tree, commit each task
as a separate commit (or as task branches merged into the section
branch — either pattern is fine for substrate-iteration), write
the section report to `briefs/s012-onboarder-shell/section.report.md`,
push the section branch to origin. The human handles the
section→main merge.

**Section number.** Placeholder `s012` throughout. At dispatch
time, fill in based on whether s012 (resource-name
parameterisation) has shipped: this becomes `s013` if so, `s012`
if s012 is deferred past this section. The brief otherwise does
not depend on s012's status — they touch different surfaces.

## What this is

The first of four sections that build the migration-onboarding
machinery (A → F50 → B → C, per the s001-merged-onboarding-design
handover). This section produces the **shell**: the onboarder role
itself, its container infrastructure, the operator-side intake
script, the handover-brief template, and the architect attach path
that consumes the handover. It deliberately does **not** include
the two sub-agents (code migration agent → Section B,
history migration agent → Section C). The shell must be functional
end-to-end for a trivial no-op case before either sub-agent lands.

### Why the shell ships first

The shell defines the contract: what the onboarder consumes
(operator input + source materials), what it produces (the
handover brief), and how its output flows into the rest of the
substrate (architect attach). Sub-agents B and C plug into a shell
that already exists, against a brief template that already names
the slots their findings populate. Building the shell first means
B and C can be specified against a stable interface rather than
co-evolving with it.

### Why this doesn't depend on F50

F50 is the platform-composition mechanism — the substrate
auto-couples a section's platform needs to agent container images.
That matters for the **code migration agent** (Section B), which
needs target-language toolchains to do its structural review. The
onboarder itself does not run target-language tooling; it
synthesises text. A vanilla claude-code container is sufficient.
F50 lands between A and B precisely so that B can be platform-aware
from day one without retrofitting A.

---

## Recommendations baked in (override before dispatch)

Eight design calls. Each flagged below; edit before dispatch to
override.

1. **Onboarder is project-scoped and single-shot, dispatched via a
   substrate-level script (`./onboard-project.sh`), parallel to
   `setup-linux.sh` and `verify.sh`.**

   Considered alternative: bake onboarding into `setup-linux.sh`
   as a flag (`./setup-linux.sh --onboard-project <path>`). Rejected
   because setup-linux.sh creates the substrate infrastructure
   (containers, volumes, keys); onboarding is project-level work
   that runs *after* infrastructure exists. The substrate has
   already established the pattern of one script per discrete
   operator-facing action.
   **Override:** specify integration into `setup-linux.sh` if you
   want a single entry point.

2. **`./onboard-project.sh` accepts the source-project path as a
   required argument and a project-type hint as an optional flag.**

   ```
   ./onboard-project.sh <source-path> [--type 1|2|3|4]
   ```

   - `<source-path>` is a directory on the host containing the
     brownfield project's code and any docs/history materials.
     Mounted read-only into the onboarder container at
     `/source`.
   - `--type` is a hint for the onboarder, not a hard constraint:
     it indicates the project shape per the four-type taxonomy
     (code only / +human notes / +agent history / +informal
     methodology). If omitted, the onboarder infers from the
     contents of `/source` and elicits clarification from the
     operator during synthesis.

   Considered alternative: pass project-type as required, refuse
   to dispatch without it. Rejected because type identification is
   itself an onboarder activity for genuinely ambiguous cases.
   **Override:** make `--type` required, or add other flags
   (priorities, project name, etc.) as required arguments.

3. **The onboarder writes its handover brief directly into the
   main repo at `briefs/onboarding/handover.md`.** The main repo
   is initialised by `./onboard-project.sh` before the onboarder
   spawns — empty main and auditor bare repos on the substrate's
   git-server, with an initial commit on `main` that imports the
   brownfield source tree (or marks it for later import, see call 4).

   The handover brief is therefore the **first methodology
   artifact** committed to the project — same canonical path
   pattern as section briefs (`briefs/<slug>/<artifact>.md`).
   The architect, on attach, reads it from the standard place.

   Considered alternative: onboarder writes to a staging area
   outside the repo (e.g. `/state/onboarding/`), and the architect
   imports it after attach. Rejected because it creates a separate
   location for a methodology artifact, breaking the "everything
   under `/briefs/`" pattern, and forces the architect's first job
   to be plumbing rather than synthesis.
   **Override:** specify a staging path if you want the onboarder's
   output kept out of the project's permanent history.

4. **Brownfield source import: copy the source tree as an initial
   commit on `main` titled "onboarding import".** This is the
   pre-architect equivalent of a clean checkout. The onboarder's
   handover brief commit lands on top of it.

   Rationale: the migration exists to ease cognitive load for
   the **architect** — the only role that carries persistent
   context across a project. Planners, coders, and auditors each
   start their work with a clean window: they get the codebase
   as it exists in `main` plus their brief, nothing else. From
   their perspective there's no distinction between a project
   that has used the methodology since day one and a project
   migrated in mid-flight, and there cannot be — they have no
   inherited context to ease. Importing on onboard means `main`
   always presents itself the way the methodology expects from
   section 1 onward, which is the shape every downstream role is
   built for.

   Considered alternative: keep `/source` mounted read-only and
   never import it; the onboarder describes-but-does-not-copy,
   and the first real section (a planner-driven one) imports the
   code then. Rejected because it makes the first section of
   every migration project a load-bearing import section,
   bifurcates "Section 1" semantics between greenfield and
   migrated projects, and forces the onboarder to reference
   code at a path outside the repo throughout the handover.
   **Override:** specify the read-only-source pattern if you'd
   rather keep code out of `main` until a planner imports it.

5. **Architect attach-with-handover via the existing
   `BOOTSTRAP_PROMPT` env-var pattern (s008).** When the operator
   runs the architect-attach step after onboarding, the architect's
   entrypoint detects the handover at `/work/briefs/onboarding/handover.md`
   and, if `SHARED-STATE.md` doesn't yet exist (i.e. this is the
   first attach for the project), invokes claude non-interactively
   with a bootstrap prompt pointing at the handover.

   Considered alternative: print operator-paste instructions and
   let the human seed the architect's first chat manually. Works,
   but loses determinism — the same property s008 went out of its
   way to establish for planner/auditor commissioning. The
   architect's first interaction with the project should be as
   deterministic as the first planner's.
   **Override:** specify operator-paste if you want the
   architect's first attach to remain interactive.

6. **Migration audit deferred.** The methodology spec implies
   audit symmetry: every architect-produced brief gets audited
   before downstream use. The handover brief is architect-adjacent
   (it commissions the architect), so symmetry suggests it should
   be audited. **But:** the onboarder's work is heavily
   human-in-loop during elicitation — the operator sees and shapes
   the synthesis as it happens. The marginal value of an
   independent audit may be low.

   Rather than build audit machinery for the onboarder in Section
   A and risk overbuilding, defer the call. After the first real
   migration project runs (post-Section C), the operator can
   judge whether an audit step would have caught anything the
   onboarder + human in-loop missed. If yes, audit machinery
   becomes a small dedicated section.

   Considered alternative: include audit machinery now,
   defaulting to off (audit only if `--audit` flag is passed).
   Rejected because half-built audit infrastructure is its own
   maintenance load and the right shape can't be designed without
   real-migration data.
   **Override:** specify "include audit machinery" if you want it
   built defensively now.

7. **Handover-brief template lives in the methodology directory
   as a documented template, not as a fillable form.** Path:
   `methodology/onboarder-handover-template.md`. The
   onboarder reads it as guidance for what its output must
   contain, then writes a freshly-composed handover at the
   canonical path.

   Considered alternative: a literal fill-in-the-blanks template
   the onboarder copies and completes. Rejected because the four
   project types produce qualitatively different handover content
   (type 1 has empty history sections; type 4 has rich
   methodology-state sections), and a single fillable form either
   forces vacuous "N/A" sections or branches into four templates.
   A documented "must contain" specification handles type variation
   naturally.
   **Override:** specify the fillable-form approach if you want
   structural uniformity across all four types' handover briefs.

8. **F51 doc-fix rides along: the architect's audit-brief
   tool-surface template grows guidance on `cd` and `git -C`
   patterns.** This is the second-real-audit recurrence of F51
   noted in the s001-merged-onboarding-design handover. The fix
   lives in whatever methodology document holds the architect's
   audit-brief tool-surface guidance — the implementing agent
   identifies the exact file. Scope: add a short paragraph and an
   example showing the recommended cwd + git-C pattern. No
   structural changes to the template.

   Considered alternative: ride F51 with B or C instead. Rejected
   because A is the earliest of the three and shipping F51 now
   means it benefits every audit run from the next one onward.
   **Override:** specify B or C as the carrier section.

---

## Top-level plan

**Goal.** Add the onboarder role to the substrate end-to-end:
role guide, container, compose service, operator entry script,
handover-brief template, architect attach path, and a trivial
no-op verification that proves the loop closes. Ride F51 doc-fix.

**Scope.** One section. No parallelism. No sub-agents (B and C
ship later).

**Sequencing.** Execute after the current main tip. Does not
depend on s012 or F50. Hard prereq for Section B (code migration
agent) and Section C (history migration agent).

**Branch.** `section/s012-onboarder-shell` off `main`.

---

## Section s012 — onboarder-shell

### Section ID and slug

`s012-onboarder-shell` (number filled at dispatch).

### Objective

Add a new top-level role to the substrate: the **onboarder**. The
role is project-scoped, single-shot, and pre-architect. It is
commissioned by the operator via `./onboard-project.sh <source>
[--type N]`. It produces a handover brief at
`briefs/onboarding/handover.md` in the project's main repo. The
architect, on its first attach for the project, reads the handover
brief as bootstrap context and begins the project methodology from
the synthesis the onboarder produced.

This section ships the **shell**: the role guide, container,
compose service, operator entry script, handover-brief template,
architect attach changes, and an end-to-end verification that a
trivial no-op onboarding produces a valid stub handover that the
architect can attach to. The two sub-agents (code migration agent,
history migration agent) are explicitly **out of scope** and ship
in Sections B and C respectively.

### Available context

The substrate currently supports four roles: architect, planner,
coder (via daemon), auditor. Their containers, entrypoints,
compose services, and methodology guides are the structural
template the onboarder follows. Reuse patterns; don't invent new
shapes where existing ones fit. Specifically:

- **`commission-pair.sh`** is the pattern reference for
  `onboard-project.sh` — random port/token generation, env file
  written to `.pairs/`, foreground run with trap-on-exit
  `docker compose down -v` for ephemeral pair teardown. The
  onboarder is single-shot per project rather than per section,
  but its ephemeral container lifecycle is the same shape.
- **`infra/scripts/generate-keys.sh`** is where the onboarder
  keypair generation plugs in — extend the existing key-generation
  flow rather than adding a parallel one.
- **`claude-state-shared`** is the volume ephemeral roles
  (planner, coder-daemon, auditor) read their claude-code
  credentials from. The onboarder is ephemeral and follows the
  same convention. `verify.sh` already doubles as the refresh
  helper that propagates the architect's `.credentials.json` into
  this volume; no changes needed there.
- **`infra/architect/entrypoint.sh`** is where Option α of A.6
  lands. **`attach-architect.sh`** at the repo root (currently a
  thin `docker compose attach` wrapper) is where Option β would
  land.

The s008 `BOOTSTRAP_PROMPT` env-var pattern is the deterministic
commissioning mechanism. The onboarder honours it (its entrypoint
checks for `BOOTSTRAP_PROMPT` and invokes claude non-interactively
when set). The architect entrypoint gains analogous handling for
the first-attach-with-handover case.

The four project-type taxonomy from the s001-merged design
conversation:
1. Code only, minimal docs, no agent history.
2. Code + human notes / human Q&A.
3. Code + agent chat history + agent-produced documents.
4. Code + informal planner/coder methodology in use.

All four feed the same onboarding flow; the differences are in what
raw material exists at `/source`. The onboarder reads what's there
and synthesises accordingly. The `--type` flag is an optional hint;
the onboarder can infer in obvious cases.

The onboarder's activity profile is **synthesis + elicitation**.
In Section A — with no sub-agents available — synthesis is
operator-mediated: the onboarder reads, asks the operator,
integrates. From Section B onward, structural code findings come
from the code migration sub-agent; from Section C onward, history
findings come from the history migration sub-agent. The Section A
handover brief template anticipates these slots (they exist as
empty sections in the type-1 handover the verification produces)
but does not require sub-agent dispatch infrastructure to be
present.

F51 (audit-brief tool-surface template missing `cd` and `git -C`
guidance) has now manifested in two consecutive real audits with
two different auditor-invented workarounds. Doc-fix is overdue and
rides along here.

### Tasks (informal decomposition)

The agent may decompose differently, but this is the suggested
ordering. A.1 sets the shape of everything else, so do it first.

**A.1 — Onboarder role guide.**

Create `methodology/onboarder-guide.md`. Parallel in shape to
`methodology/architect-guide.md` and the other role guides. Must
contain:

- **Your role.** Project-scoped, single-shot, pre-architect.
  Ingest source materials, synthesise project understanding,
  elicit operator priorities and unknowns, produce the handover
  brief, discharge.
- **Your boundaries.** Don't dispatch sub-agents (none exist in
  Section A — note them as "future capability via Sections B and
  C"). Don't write to the main repo outside `briefs/onboarding/`.
  Don't attempt to build, run, or test the source project — that
  is the code migration agent's job (future) and the architect's
  decision (immediate). Don't speculate beyond the materials and
  the operator's stated priorities; document unknowns as unknowns
  rather than guessing.
- **What you produce.** The handover brief at
  `briefs/onboarding/handover.md`, conforming to
  `methodology/onboarder-handover-template.md`.
- **How you work.** Read `/source` exhaustively. Build an
  internal picture of project identity, scope, stack, and state.
  Then enter the elicitation loop with the operator (interactive
  claude session — the operator is conversing with you
  throughout):
  - Present your current synthesis and 2–3 specific questions at
    a time (not 1, not 20). Lead with the most consequential
    unknown. Mark each question with what answer would change in
    the synthesis.
  - Integrate the operator's answers into the synthesis before
    asking the next round.
  - Iterate until your unknowns are stable — no significant new
    uncertainty surfaces as you refine — and the operator is
    satisfied with the synthesis.
  - Draft the handover, present it to the operator for final
    review, integrate any last corrections, commit, push,
    discharge.

  The operator may interrupt with priorities, constraints, or
  corrections at any point — fold these into the synthesis and
  into section 8 of the handover ("Operator's stated priorities").
- **Lifecycle from your seat.** Receive commissioning prompt →
  read source → draft synthesis skeleton → elicitation loop with
  operator → draft handover → operator review → commit + push →
  discharge.
- **Sub-agent naming convention (for when B and C ship).** Future
  sub-agents you'll dispatch use the **"X migration agent"**
  descriptive form (code migration agent, history migration
  agent) — distinct from the **profession-name** form used for
  top-level methodology roles (architect, planner, coder,
  auditor, onboarder). The asymmetry is deliberate: profession
  names signal top-level methodology roles with persistent
  presence in the substrate; descriptive names signal sub-agents
  whose scope lives inside a single parent role's run. Preserve
  this convention.

The guide should be lean (architect-guide.md is the size
reference). Internal mechanics of sub-agent dispatch are
deliberately omitted because no sub-agents exist yet — when B and
C land, those sections will add the relevant lifecycle and
boundary text.

**A.2 — Handover-brief template.**

Create `methodology/onboarder-handover-template.md`.
Document — not a fillable form — describing what the handover
brief must contain. Sections (in order):

1. **Project identity.** Name, source location, primary language(s)
   and stack, observed methodology state (none / informal /
   formalised), type classification (1/2/3/4) with a one-sentence
   rationale.
2. **Source materials inventory.** What existed at `/source` at
   onboarding time — directory structure summary, file counts by
   type, presence/absence of docs, transcripts, methodology
   artifacts.
3. **Code structural review.** Slot for code-migration-agent
   findings (Section B). For Section A type-1 verification, this
   section is operator-acknowledged "no automated review run" and
   contains only what the onboarder noticed during read-through.
4. **History review.** Slot for history-migration-agent findings
   (Section C). For Section A, type-1 has no history materials so
   this section reads "N/A (type 1)".
5. **SHARED-STATE.md candidate.** Proposed initial draft for the
   architect to refine and adopt. Decisions inferred from the
   code, interfaces observed, invariants visible. Marked clearly
   as a candidate — the architect owns the final version.
6. **TOP-LEVEL-PLAN.md candidate.** Project goal as understood,
   suggested first 2–3 sections in dependency order, with
   one-paragraph rationale per section. Marked as a candidate —
   the architect and human ratify.
7. **Known unknowns.** Explicit questions the onboarder could not
   resolve from the materials or the elicitation pass. These
   become the architect's first agenda items with the human.
8. **Operator's stated priorities.** What the human told the
   onboarder during the elicitation pass — goals, constraints,
   non-goals, anything they want the architect to know on day one.
9. **Carry-over hazards.** Anything the onboarder noticed that
   doesn't fit elsewhere but the architect should know about.

The template document describes each section's purpose, expected
length, and what good vs bad content looks like for that section.
Like the role guide, lean.

**A.3 — Onboarder container.**

Create `infra/onboarder/`:

- `Dockerfile` — base image and tooling parallel to the planner's
  container (claude-code installed, agent user, standard layout).
  The onboarder does not need target-language toolchains (that's
  the code migration agent's concern, post-F50). A vanilla
  claude-code-capable image is sufficient.
- `entrypoint.sh` — parallel in shape to `infra/planner/entrypoint.sh`.
  SSH key setup (if the onboarder writes to git-server; see A.4
  on whether it does), git clone of the project main repo into
  `/work`, identity setup, symlink `methodology/onboarder-guide.md`
  as `/work/CLAUDE.md`, banner, then `BOOTSTRAP_PROMPT` handling
  (per s008) before `exec bash -l`.

The onboarder's commissioning prompt (set by
`./onboard-project.sh`) follows the s008 self-bootstrapping
pattern. Suggested deterministic prompt:

```
Read /methodology/onboarder-guide.md (symlinked as /work/CLAUDE.md).
The brownfield source materials are at /source (read-only). Your
project type hint is: <type-or-unknown>. Operator-supplied initial
context (if any) is at /onboarding-intake.md. Synthesise the project,
elicit priorities and unknowns from the operator interactively, and
produce the handover brief at /work/briefs/onboarding/handover.md
following /methodology/onboarder-handover-template.md.
Commit and push when complete. Discharge.
```

The `/onboarding-intake.md` file is optional: if the operator
runs `./onboard-project.sh` with an `--intake-file <path>` flag
(see A.5), the script mounts that file at `/onboarding-intake.md`;
otherwise the path doesn't exist and the onboarder elicits from
scratch.

**A.4 — Compose service.**

Add `onboarder` service to `docker-compose.yml`, in the
`["ephemeral"]` profile (matches planner/auditor — single-shot,
dispatched per invocation, not part of the always-on substrate).
Service definition parallel to the planner: build from
`infra/onboarder`, mount the methodology directory read-only at
`/methodology` (the convention the README documents and all
other role containers use — match it exactly; do not invent a
new mount path), mount onboarder SSH keys, network `agent-net`,
depends on `git-server`. Add two onboarder-specific mounts:

- `${SOURCE_PATH}:/source:ro` — the brownfield project tree.
- `${INTAKE_FILE:-/dev/null}:/onboarding-intake.md:ro` — optional
  operator intake file.

The `SOURCE_PATH` and `INTAKE_FILE` env vars are set by
`./onboard-project.sh` before invoking compose.

Generate an SSH keypair for the onboarder under `infra/keys/onboarder/`
during setup. **Note:** this means `setup-linux.sh` and
`setup-mac.sh` need a small update to generate the new keypair —
include this update in A.4.

**A.5 — `./onboard-project.sh` operator script.**

Create the entry script at the repo root, parallel to
`setup-linux.sh`, `verify.sh`, `commission-pair.sh`, `audit.sh`.

Arguments:

```
./onboard-project.sh <source-path> [--type 1|2|3|4] [--intake-file <path>]
```

Behaviour:

1. Validate `<source-path>` exists and is a directory.
2. Validate that the substrate is up (`docker compose ps` shows
   git-server and architect running).
3. **Single-shot check (before any mutation):** inspect the
   project's main repo on the substrate's git-server. If it
   contains anything beyond the bare-empty state established by
   `setup-linux.sh`, fail fast and exit non-zero. This is the
   single-shot enforcement; nothing below this step runs if the
   check fails.
4. Initialise main and auditor bare repos on git-server if not
   already present (typically they exist as empty bare repos from
   `setup-linux.sh`; if step 3 passed, they're either absent or
   empty, so this step is a no-op or a fresh init).
5. Import the brownfield source tree (per design call 4): clone
   main into a temporary dir, copy `/source` contents into the
   working tree, commit "onboarding: import source materials"
   with the onboarder identity, push to main. (Question whether
   this should be done from the onboarder container itself — see
   constraints.)
6. Build the `BOOTSTRAP_PROMPT` per A.3's template, filling in
   the type hint.
7. `docker compose run --rm onboarder` with the env vars set:
   `BOOTSTRAP_PROMPT`, `SOURCE_PATH`, `INTAKE_FILE`.
8. After the onboarder discharges, the script drops the human into
   a shell in the onboarder container for inspection (parallel to
   s008's `commission-pair.sh` dual-mode tail).
9. Print a clear "next step" line: "Onboarding complete. Run
   `./attach-architect.sh` to attach the architect with the
   handover brief as bootstrap context."

**A.6 — Architect attach-with-handover.**

Two options (the agent picks based on minimal disruption to the
existing architect-attach pattern; document the choice in the
section report):

Two options. Both modify existing files — `attach-architect.sh`
already exists at the repo root as a thin
`docker compose attach` wrapper, so neither option introduces a
new operator-facing script. The agent picks based on minimal
disruption to the existing architect-attach pattern and documents
the choice in the section report:

- **Option α — entrypoint detects.** Modify
  `infra/architect/entrypoint.sh` to check for
  `/work/briefs/onboarding/handover.md` on startup. If present AND
  `/work/SHARED-STATE.md` is absent (i.e. this is the first attach
  for an onboarded project), construct an internal
  `BOOTSTRAP_PROMPT` pointing the architect at the handover and
  invoke claude non-interactively before dropping to the
  interactive session. The bootstrap prompt: `"Read
  /work/briefs/onboarding/handover.md, which is the project's
  onboarding handover. Adopt its SHARED-STATE.md and
  TOP-LEVEL-PLAN.md candidates as starting drafts, refine them
  with the operator, and begin the project's methodology from
  this point."`
- **Option β — wrapper detects.** Extend the existing
  `attach-architect.sh` to detect the handover and set
  `BOOTSTRAP_PROMPT` in the architect container's environment
  before attaching, restarting the architect first if needed to
  pick up the new env. This keeps onboarding-aware logic out of
  the architect entrypoint.

Option α is closer to the existing pattern (entrypoint
self-bootstraps; matches s008's planner/auditor handling) and
keeps `attach-architect.sh` thin, which is its current shape.
Option β requires the architect to restart on the operator's
first post-onboarding attach, which is a behaviour change in the
wrapper script. Lean α absent a reason to prefer β.
**Override:** specify β if you'd rather keep the architect
entrypoint free of onboarding-aware logic.

**A.7 — End-to-end no-op verification.**

Add a test under `infra/scripts/tests/test-onboarder-shell.sh`
(name parallel to existing s007/s008 test naming). The test:

1. Creates a synthetic minimal type-1 source tree in a tempdir:
   `README.md`, a single source file, nothing else.
2. Tears down any existing substrate state (or creates an
   isolated test substrate).
3. Runs `./setup-linux.sh` (or the mac equivalent depending on
   test host) to bring the substrate up.
4. Runs `./onboard-project.sh <synthetic-tempdir> --type 1`.
5. Verifies:
   - Main repo has an "onboarding: import source materials" commit
     followed by a handover commit at `briefs/onboarding/handover.md`.
   - The handover file exists and is non-empty.
   - The handover contains the nine sections specified by the
     template (presence-check by header grep; content quality is
     not verified here — that's the integration-with-real-project
     concern).
6. Runs the architect attach (per A.6's chosen option) and
   verifies the architect's first claude invocation completed
   without error.

To make the test deterministic and avoid burning real claude API
calls on synthetic onboarding, use the same stub-claude pattern
s007/s008 established: a stub `claude` binary on PATH that
honours `-p` by echoing a fixed response and writing a fixed
output file. The test wires the stub to produce a minimal valid
handover from the synthetic source, then verifies the resulting
git state.

**A.8 — F51 doc-fix ride-along.**

Per the s011 handover, F51's fix is a two-file documentation
update sitting on top of the tool-surface symmetry mechanism s011
introduced:

- **`methodology/architect-guide.md`** — in the audit-brief
  authoring guidance (the section that teaches the architect how
  to populate the "Required tool surface" field for an audit
  brief): add a short paragraph and example prompting the
  architect to think about `cd` and `git -C` patterns when
  authoring the field.
- **`methodology/auditor-guide.md`** — in the auditor's
  operational guidance: add the corresponding receiving-side note
  so the auditor knows which pattern to reach for given the tool
  surface it receives.

Content of the guidance (both files share the substance; phrasing
differs by audience):

- Auditor's starting cwd is `/work` (read-only main repo clone)
  or `/auditor` (read-write auditor repo clone). Choose explicitly
  per probe.
- For git operations against the main repo clone, use absolute
  paths with `git -C /work <subcmd>` — do not `cd /work` then
  `git`, because some claude-code tool surfaces deny `cd` into
  mounted read-only roots. The "Required tool surface" should
  grant the `git -C` form explicitly.
- For git operations against the auditor repo, `cd /auditor`
  followed by `git` is fine because the auditor clone is writable.
- Provide a one-line example for each pattern.

Scope: pure documentation. No changes to the tool-surface parser
(`infra/scripts/lib/parse-tool-surface.sh`), no changes to brief
structure or the `Required tool surface` field shape — s011
already delivered those. Just the two guide updates so the next
architect-authored audit brief prompts the right thinking and the
next auditor knows which pattern matches the surface it received.

If the methodology spec (`agent-orchestration-spec.md`) also
needs a touch to stay symmetric with the guides — given the
spec-is-canonical, guides-are-derivative note at the top of
`architect-guide.md` — update the spec first and regenerate the
guide views from it. The agent will discover whether this is
necessary by reading the current state of the three files.

**A.9 — Documentation update.**

Update:

- `methodology/deployment-docker.md` — add an onboarder section
  covering the new container, compose service, and `./onboard-project.sh`
  workflow.
- `agent-orchestration-spec.md` §4 (Roles) and §3 (Substrate) —
  add the onboarder. **Spec is normative; this is a real change
  to the methodology, not just an implementation detail.** §4
  gets a new "Onboarder" subsection parallel to the others.
  Note the single-shot, pre-architect lifecycle.
- **Persistent-context principle ride-along.** Land the principle
  that "**the architect is the only role with persistent context
  across a project**" durably in methodology docs — either in
  `methodology/architect-guide.md`'s "Your role" section or in
  `agent-orchestration-spec.md` §4's architect entry (the spec is
  preferred since the guide is derivative). One short paragraph:
  planners, coders, and auditors begin every section with a clean
  context window and only the inputs in their brief; the architect
  carries `SHARED-STATE.md` and `TOP-LEVEL-PLAN.md` across the
  whole project. This is foundational to the methodology's role
  economy, and it explains why migration onboarding exists at all
  — to ease the only role onboarding can ease. The principle
  pre-dates this section (it's been implicit since the methodology
  was first drafted), but Section A is the natural place to make
  it explicit, since the onboarder's entire reason for existence
  follows from it.
- `README.md` quickstart — add the onboarding step for
  brownfield-migration projects (greenfield projects skip
  onboarding and go straight to architect-attach). Also bump the
  spec version reference if the README is still pointing at v2.1
  while the spec itself has moved to v2.2 (per the s001-merged
  handover).
- Section report at A.7 should reference the spec change.

### Constraints

- **No sub-agents.** Section A produces shell only. Code migration
  agent (Section B) and history migration agent (Section C) are
  out of scope. The handover template anticipates their output
  slots but does not require their machinery to exist.
- **Onboarder is depth-1 from operator.** No further dispatch in
  A. Depth-2 arrives with B and C.
- **No F50 dependency.** Section A's onboarder container does not
  need target-language toolchains. F50 lands between A and B.
- **Architect entrypoint changes are minimal.** Only the
  first-attach-with-handover path is added. All existing
  attach behaviour for greenfield (no `/briefs/onboarding/handover.md`)
  is unchanged.
- **Single-shot enforcement.** `./onboard-project.sh` refuses to
  run a second time for the same project. The check happens at
  script entry, **before any new commits are added**: if the
  project's main repo on the substrate's git-server contains
  anything beyond the bare-empty state established by
  `setup-linux.sh`, the script refuses and exits non-zero. (Once
  the script proceeds and imports source materials and the
  onboarder writes the handover, the repo is no longer empty —
  but at that point the script is already past the check.)
- **Idempotent setup.** The keypair generation in A.4 must be
  idempotent — re-running `setup-linux.sh` after this section
  lands on an existing substrate must not regenerate keys (same
  property the other roles already have).
- **No changes to planner, coder, auditor entrypoints.** Their
  containers are untouched.
- **F51 fix is documentation-only.** No code, no template
  structure changes.

### Definition of done

- `methodology/onboarder-guide.md` exists and is structurally
  parallel to other role guides.
- `methodology/onboarder-handover-template.md` exists
  and documents the nine-section handover structure.
- `infra/onboarder/{Dockerfile,entrypoint.sh}` exist; the
  container builds cleanly; the entrypoint honours
  `BOOTSTRAP_PROMPT`.
- `docker-compose.yml` has an `onboarder` service in the
  ephemeral profile.
- `setup-linux.sh` and `setup-mac.sh` generate the onboarder
  keypair idempotently.
- `./onboard-project.sh` exists at the repo root, executable,
  with `<source-path>` and optional `--type` and `--intake-file`
  arguments per A.5.
- Architect entrypoint (or extended `attach-architect.sh`, per
  A.6's chosen option) detects the handover and bootstraps the
  architect's first attach.
- `infra/scripts/tests/test-onboarder-shell.sh` exists and passes
  using the stub-claude pattern.
- F51 doc-fix is in place in `methodology/architect-guide.md`
  (audit-brief authoring) and `methodology/auditor-guide.md`
  (audit operating), with spec touch-up if symmetry requires.
- `methodology/deployment-docker.md`, `agent-orchestration-spec.md`,
  and `README.md` are updated per A.9.
- Section report at `briefs/s012-onboarder-shell/section.report.md`
  including: brief echo, per-task summary, the canonical onboarder
  bootstrap prompt in full (becomes reference like s008's
  planner/auditor prompts), Option α vs β choice for A.6 with
  rationale, test transcript, any residual hazards.

### Out of scope

- **Code migration sub-agent.** Section B.
- **History migration sub-agent.** Section C.
- **F50 platform composition.** Its own section between A and B.
- **Migration audit machinery.** Deferred per design call 6.
- **Real-project migration runs.** The first real brownfield
  migration happens after C ships. Section A's verification is
  synthetic-source only.
- **Greenfield project onboarding.** Onboarding is a brownfield
  concern. Greenfield projects skip onboarding and go straight to
  architect attach with empty SHARED-STATE.md and a
  human-and-architect-authored TOP-LEVEL-PLAN.md.
- **Cross-substrate / cross-host migration plumbing.** From the
  s001-merged design conversation: when the source project is
  still being worked on in another agent substrate (the "live"
  mode of history migration), v1 is **explicitly human-mediated**
  — the history migration agent drafts questions for the
  upstream agent, the operator carries them across by hand and
  returns the answers, and the migration agent integrates. No
  cross-substrate API, no shared message bus, no plumbing
  between substrates. The operator is the bridge. This decision
  predates Section C's brief and must be preserved when C is
  drafted: the simpler-bridge call is deliberate, and reaching
  for cross-substrate machinery is a v2 concern at earliest.
- **IDE-driven onboarding UX.** Per the s001-merged handover, the
  IDE pivot is deferred. CLI/markdown is the operational surface
  for the onboarder, same as other roles.
- **Re-onboarding.** Single-shot per project. If a project
  genuinely needs re-onboarding, that's a future "rebase" feature
  and not in scope here.

### Repo coordinates

- Base branch: `main` (current tip; does not depend on s012).
- Section branch: `section/s012-onboarder-shell`.
- Task commits or task branches off the section branch are both
  fine — same pattern as s001–s011. Inline commits on the section
  branch are likely cleanest given task sizes; A.3 and A.5 are
  the heaviest individual tasks and benefit from being their own
  commits for review.

### Reporting requirements

Section report at `briefs/s012-onboarder-shell/section.report.md`
on the section branch. Must include:

- Brief echo (restate Section A's objective in the agent's own
  words).
- Per-task summary (A.1 through A.9).
- The canonical onboarder bootstrap prompt in full (the
  deterministic prompt set by `./onboard-project.sh`) — this
  becomes the methodology's reference for onboarder commissioning,
  same status as the planner and auditor prompts canonicalised
  in s008's report.
- The architect attach-with-handover bootstrap prompt in full
  (whether Option α or β).
- Option α vs β choice for A.6 with rationale.
- Test transcript from A.7.
- F51 doc-fix excerpts (the new paragraphs added to
  `architect-guide.md` and `auditor-guide.md`, plus any spec
  touch-up).
- The handover-brief template's section headings in full (so the
  report serves as a reference for what the onboarder must
  produce).
- Any residual hazards or open questions for future sections,
  especially anything affecting B or C.

---

## Execution

Single agent on the host (Chromebook clone of turtle-core), same
pattern as s001–s011. **Do not commission any other agents — this
is substrate-iteration work.** Work through A.1–A.9 in roughly
that order, committing per task (or per task branch if the agent
prefers — review review-flow same as prior sections).

The agent may pause for human input at:

- **A.1 / A.2 review checkpoint.** Once the onboarder-guide and
  the handover template are drafted, surface them for human review
  before A.3+ builds against them. These two artifacts set the
  shape that everything downstream depends on. A second-pass
  refinement after A.7's verification is also fine.
- **A.6 Option α vs β.** If the agent forms a strong preference
  against the brief's α recommendation while implementing, raise
  it before proceeding.
- **A.7 test design.** If the stub-claude pattern's wiring is
  unclear from s007/s008 precedent, surface the question rather
  than reinventing.

If the agent finds genuine ambiguity that this brief doesn't
resolve, the right move is to ask the human for a brief amendment
or, if that's not available, to discharge with "brief insufficient"
and document the gap in a partial section report. Same discipline
as before.
