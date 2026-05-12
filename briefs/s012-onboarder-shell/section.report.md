# Section report — s012 onboarder shell

Branch: `section/s012-onboarder-shell` off `main`.
Base: `5b498fe` (s011 merge).
Tip:  `b7db107`.

## Brief echo

s012 ships the **first of four** sections that build the migration-onboarding machinery (A → F50 → B → C, per the s001-merged-onboarding-design handover). This section produces the **shell**: a new top-level **onboarder** role with its container, compose service, operator-side intake script (`./onboard-project.sh`), the handover-brief template, the architect's attach-with-handover path, and an end-to-end no-op verification that proves the loop closes against a synthetic source tree.

The shell explicitly does **not** include the two sub-agents (code migration agent → Section B, history migration agent → Section C). Sections 3 and 4 of the handover template are documented as slots those sub-agents will populate when they ship; in the meantime the onboarder fills them with operator-acknowledged "no automated review run" notes plus pointer-level observations from its own read-through. The shell ships first so B and C can be specified against a stable interface.

Shipping plan honoured: substrate-iteration, single agent on host, no planner commission, brief committed onto the section branch, per-task commits, section report written here, branch ready to push. F51 doc-fix rides along (architect-guide + auditor-guide); spec bumped 2.2 → 2.3 to cover the new role and the now-explicit persistent-context principle.

## Section-number resolution

Brief shipped with `sNNN` placeholders to be filled at dispatch based on whether s012 (resource-name parameterisation) had shipped. `git log --all | grep -iE 's012|resource-name'` returned nothing; s012 has not shipped. Per the brief's instruction this section therefore becomes **s012-onboarder-shell**.

## Per-task summary with commit hashes

| Task | Commit | Summary |
|------|--------|---------|
| brief | `879a85f` | Section brief committed at `briefs/s012-onboarder-shell/section.brief.md` (with `sNNN` → `s012` substitutions applied). |
| A.1 | `95e0eae` | `methodology/onboarder-guide.md` — operational guide for the onboarder role (~108 lines, parallel in shape to architect-guide / planner-guide / auditor-guide). Covers Your role / Your environment / Your boundaries / What you produce / How you work / Four project types / Sub-agent naming convention / Lifecycle / Discipline. |
| A.2 | `aa7d32f` | `methodology/onboarder-handover-template.md` — 9-section "must contain" specification (not a fillable form, per design call 7). Each section documents purpose, must-contain content, length guide, good vs bad content. Plus confidence-calibration guidance and the canonical commit message contract. |
| A.3 | `3b69950` | `infra/onboarder/Dockerfile` + `infra/onboarder/entrypoint.sh`. Built on `agent-base`; no target-language toolchains (no F50 dependency). Entrypoint mirrors planner/auditor shape — SSH key tighten-into-rw, `.claude.json` symlink, clone `main.git` into `/work`, set git identity, `mkdir briefs/onboarding`, `CLAUDE.md` symlink to `/methodology/onboarder-guide.md`, banner, BOOTSTRAP_PROMPT handling. Critical divergence from planner/auditor: claude is invoked **interactively** (`claude "$BOOTSTRAP_PROMPT"`, no `-p`) because the onboarder is human-in-the-loop during elicitation. `--permission-mode dontAsk` and a curated `--allowed-tools` list are embedded in the entrypoint (not parsed from a brief — the onboarder has no section brief). |
| A.4 | `9fcc53f` | `docker-compose.yml` — added `onboarder` service to the `ephemeral` profile with `SOURCE_PATH`/`INTAKE_FILE` env-driven mounts. `infra/scripts/generate-keys.sh` — added `onboarder` to roles array (idempotent keypair generation). `setup-common.sh` — `infra/keys/onboarder` mkdir. `infra/git-server/entrypoint.sh` — added `onboarder` to authorized-keys role list. `infra/git-server/hooks/update` — added `onboarder` case (refs/heads/main only; single-shot is enforced at script level, see below). `setup-mac.sh` did not need a touch — it just sources setup-common.sh. |
| A.5 | `284cfd0` | `onboard-project.sh` at the repo root, executable. Argparse for `<source-path>` plus optional `--type`/`--intake-file`, full helptext, env-override surface (`ARCHITECT_CONTAINER`, `GIT_SERVER_CONTAINER`, `ONBOARD_COMPOSE_PROJECT` for the test fixture). Substrate-up check; single-shot check via `git --git-dir=/srv/git/main.git rev-list --count main` inside the git-server container (refuses when count > 1). Source-tree import via a one-shot debian:bookworm-slim helper on agent-net using the onboarder SSH key. Builds the canonical BOOTSTRAP_PROMPT, runs `docker compose -p ${project} --profile ephemeral run --rm onboarder` with SOURCE_PATH/INTAKE_FILE/ONBOARDING_TYPE_HINT env-forwarded. Tear-down trap. Next-step pointer to `./attach-architect.sh`. |
| A.6 | `3209ccf` | `infra/architect/entrypoint.sh` — first-attach detection block (Option α). Triggers when `/work/briefs/onboarding/handover.md` exists AND `/work/SHARED-STATE.md` is absent; runs `claude "$bootstrap_prompt"` (interactive seed) before `exec bash -l`. Greenfield path (no handover) unchanged. `attach-architect.sh` not modified (the existing thin `docker compose attach` wrapper keeps its shape). |
| A.6 fix | `092d2ee` | Cross-cutting fix discovered during test design: the architect's `/work` is a persistent volume cloned at setup time; without a refresh on entrypoint re-run, a handover pushed to main while the architect was running would never become visible in `/work` and the bootstrap block would never fire. Added `git -C /work pull --ff-only` to the entrypoint and a `docker restart ${arch_container}` step in `onboard-project.sh` after the onboarder discharges, so the architect picks up the handover before the operator's next `./attach-architect.sh`. |
| A.7 | `b7db107` | `infra/scripts/tests/test-onboarder-shell.sh` — 11-phase end-to-end test scaffolding its own scratch substrate (s007-pattern). Stub-claude pattern from s007/s008 extended to the onboarder's interactive invocation. 35 assertions, all pass. Transcript captured at `briefs/s012-onboarder-shell/test-onboarder-shell.transcript`. |
| A.8 | `da75011` | F51 doc-fix — added "cd vs git -C: pattern asymmetry across mounts" subsection to `methodology/architect-guide.md` (audit-brief authoring side) and a symmetric "cd vs git -C: which pattern matches which mount" subsection to `methodology/auditor-guide.md` (receiving side). One-line examples for each pattern. Pure documentation; spec untouched (the cd/git -C choice is operational implementation detail, not contract). |
| A.9 | `0d6cdfe` | `methodology/agent-orchestration-spec.md` — version 2.2 → 2.3, added onboarder row to §3.3 access table, added §4 Onboarder subsection, added persistent-context principle to §4 Architect, added §8 step 0 (brownfield onboarding). `methodology/deployment-docker.md` — five-container model → six-container model; new §6.4 "Onboarding a brownfield project" workflow (existing §6.4 became §6.5). All four role guides bumped to v2.3 reference. `README.md` — spec ref → v2.3, onboarder row added to "What you get" table, Quickstart split into greenfield/brownfield paths, repo layout updated. |

## Canonical bootstrap prompts

### Onboarder — `./onboard-project.sh <source-path> [--type 1|2|3|4]`

Set by `onboard-project.sh` as `BOOTSTRAP_PROMPT`; the onboarder entrypoint detects it and invokes `claude "$BOOTSTRAP_PROMPT" --permission-mode dontAsk --allowed-tools "<embedded-list>"` interactively. This becomes the methodology's reference prompt for onboarder commissioning, parallel to the planner/auditor prompts canonicalised in s008's report.

> Read /methodology/onboarder-guide.md (symlinked as /work/CLAUDE.md) and /methodology/onboarder-handover-template.md. The brownfield source materials are at /source (read-only); they have already been imported into /work as the initial commit. Your project type hint is: \<1|2|3|4|unknown\>. Operator-supplied initial context (if any) is at /onboarding-intake.md (a zero-length or absent file means none was provided). Synthesise the project, elicit priorities and unknowns from the operator interactively, and produce the handover brief at /work/briefs/onboarding/handover.md following the nine-section structure in the template. When the operator is satisfied with the handover, commit with the exact message 'onboarding: handover brief', push to origin main, and discharge.

### Architect first-attach — `./attach-architect.sh` after onboarding

Set inside the architect entrypoint when `/work/briefs/onboarding/handover.md` exists AND `/work/SHARED-STATE.md` does not. Invoked as `claude "$bootstrap_prompt" || true` interactively (no `-p`).

> Read /work/briefs/onboarding/handover.md, which is the onboarding handover brief for this project (produced by the onboarder before you attached). It contains nine sections: project identity, source materials inventory, code structural review, history review, a SHARED-STATE.md candidate, a TOP-LEVEL-PLAN.md candidate, known unknowns, the operator's stated priorities, and carry-over hazards. Adopt the SHARED-STATE.md candidate and the TOP-LEVEL-PLAN.md candidate as your starting drafts at /work/SHARED-STATE.md and /work/TOP-LEVEL-PLAN.md. Refine them with the operator, who is attached to this session interactively. Use sections 7 (known unknowns) and 8 (operator's stated priorities) as your first agenda. When you and the operator are satisfied with SHARED-STATE.md and TOP-LEVEL-PLAN.md, commit and push them to main, then begin the project's methodology from this point.

The trigger condition (`handover present AND SHARED-STATE absent`) fires exactly once per project. On the architect's second and later attaches, `SHARED-STATE.md` exists (the architect committed it during its first session) and the bootstrap block is skipped; the architect drops to the plain interactive shell for `claude --resume` exactly as it did pre-s012 for greenfield projects.

## A.6 — Option α vs Option β: chosen α

Picked Option α (entrypoint detects). Rationale:

- **Closer to existing patterns.** s008's planner/auditor entrypoints already do the "entrypoint detects BOOTSTRAP_PROMPT, runs claude non-interactively, drops to shell" dance. The architect now does an analogous (interactive-flavored) variant. Same shape, same place in the codebase.
- **Keeps `attach-architect.sh` thin.** The existing wrapper is a single `exec docker compose attach architect` line. Option β would have needed it to detect the handover, set env, possibly restart the container, then attach — three extra concerns in a script whose value-add is "be a stable name the operator types".
- **Restart-on-onboard mirrors s008's commission-pair.sh teardown.** The architect-restart step lives in `./onboard-project.sh` (which already manages the onboarder container lifecycle), not in `attach-architect.sh`. The operator running `./attach-architect.sh` sees no behaviour change between greenfield and brownfield projects from their seat — onboard-project.sh has already done the prep.

Override path documented: an operator who wants Option β can swap the entrypoint block back to the pre-s012 architect entrypoint and put the detection logic into `attach-architect.sh`. The trigger condition (`handover present AND SHARED-STATE absent`) is the same; only the location of the check moves.

## A.7 test transcript

Captured at `briefs/s012-onboarder-shell/test-onboarder-shell.transcript`. **Results: 35 passed, 0 failed.**

Phase coverage:

| Phase | What it asserts |
|-------|-----------------|
| 0 | Required images present (agent-base, agent-onboarder, agent-architect, agent-git-server). |
| 1 | Scaffold scratch substrate (keys, network, volumes, compose+env). |
| 2 | git-server up; bare repos initialised; **onboarder key recognised in the authorized_keys role list** (s012 A.4 check); main.git starts at the initial empty commit. |
| 3 | Architect up; entrypoint completed; no handover present; bootstrap block dormant (greenfield-equivalent). |
| 4 | Synthetic type-1 source tree at /tmp/.../source (README.md + main.py). |
| 5 | Source-tree import via onboarder SSH key + agent-net debian helper; **git-server hook accepts onboarder push to refs/heads/main**; commit count = 2; subject = `onboarding: import source materials`. |
| 6 | Onboarder run with stub-claude mounted at `/usr/local/bin/claude:ro` via `compose run -v`; entrypoint logs "Bootstrap prompt detected" + "Claude discharged"; exit 0. |
| 7 | Main.git commit count = 3; latest subject = `onboarding: handover brief`; HEAD's parent is the import commit. |
| 8 | handover.md exists in main, non-empty, contains all nine `## N. <heading>` patterns from the template. |
| 9 | Architect restarted with stub-claude mounted; entrypoint detects handover; logs "Onboarding handover detected" + "Architect bootstrap session ended"; stub claude marker shows it was invoked with a prompt starting `Read /work/briefs/onboarding/handover.md`. |
| 10 | After phase 9, scratch substrate is past the initial empty commit; `./onboard-project.sh <source>` (with `ARCHITECT_CONTAINER` + `GIT_SERVER_CONTAINER` env overrides pointing at the scratch substrate) exits non-zero and prints "refusing to onboard"; state on main.git is unchanged (still 3 commits). **Single-shot enforcement verified end-to-end.** |
| 11 | Argparse error paths: no-args ("source-path is required"), bad-path ("source-path is not a directory"), invalid `--type 99` ("--type must be 1, 2, 3, 4"), `--help` (usage + exit 0). |

Stub-claude pattern note: the brief envisioned the s007/s008 "stub honours `-p`" shape. The onboarder runs claude **interactively** (no `-p`), so the test's stub is invoked as `claude "<prompt>" --permission-mode dontAsk --allowed-tools "..."` instead. The stub ignores its args and produces a valid 9-section handover, commits with the canonical message, and pushes. Same pattern, generalised one positional argument over. The s007/s008 stubs stay valid for planner/auditor (which still use `-p`); only the onboarder/architect-bootstrap stubs use the non-`-p` invocation.

## F51 doc-fix excerpts

### `methodology/architect-guide.md` — Authoring the tool-surface field

> ### `cd` vs `git -C`: pattern asymmetry across mounts
>
> When authoring an audit brief's tool surface, think explicitly about which working directory the auditor's git operations will run from. The auditor has two mounts with different writability, and the choice of pattern follows from that asymmetry:
>
> - **Main-repo clone at `/work` is mounted read-only.** Some claude-code tool surfaces deny `Bash(cd:*)` into mounted read-only roots, and even where `cd` is allowed it is fragile — a subshell exit can drop the auditor back to a writable cwd unexpectedly. **Author the surface so the auditor uses `git -C /work <subcmd>`** with an absolute path rather than `cd /work && git`. Grant `Bash(git -C /work log:*)`, `Bash(git -C /work diff:*)`, etc. explicitly. Example: `Bash(git -C /work log:*)` — not `Bash(git log:*)` plus `Bash(cd /work)`.
> - **Auditor repo at `/auditor` is read-write and is the auditor's natural workspace.** `cd /auditor` followed by plain `git` is fine here because the clone is writable and the auditor is expected to work *in* it (write the report, build tooling). Grant `Bash(cd:*)` and `Bash(git *:*)` patterns scoped naturally; the cwd convention works.

### `methodology/auditor-guide.md` — Your tool surface

> ### `cd` vs `git -C`: which pattern matches which mount
>
> You operate across two mounts with different writability, and your tool surface will typically reflect this asymmetry:
>
> - **`/work` (read-only checkout of the section branch tip).** If the architect did their job, your surface grants `Bash(git -C /work log:*)`, `Bash(git -C /work diff:*)`, etc. — the absolute-path `git -C` form rather than `cd /work && git`. Use those exactly as granted; do not invent `cd /work` workarounds when an examination probe needs more. If you find your surface is missing a `git -C /work …` pattern you genuinely need, that is a "brief insufficient" condition — write the note into the auditor repo naming the missing pattern, do not paper over it with shell tricks.
> - **`/auditor` (your read-write workspace).** This is your natural cwd. Plain `cd /auditor` followed by ordinary `git add / commit / push` works because the clone is writable. Your surface will typically grant `Bash(cd:*)` and `Bash(git *:*)` here; use them straightforwardly.

### Spec — no touch

The brief asked the implementing agent to discover whether `agent-orchestration-spec.md` also needed a touch for symmetry. Decision: **no spec change for F51**. The spec stays at the contract level ("Required tool surface field present, parsed, translated"); the `cd`/`git -C` choice is operational implementation detail that lives in the guides where it shapes day-to-day brief authoring and audit operation. The guides are derivative-from-spec per their own headers, but the substance of F51 is not in the spec to begin with — it's about how to *operate* the field, not what the field is.

## Handover-brief template section headings (full reference)

The template at `methodology/onboarder-handover-template.md` mandates these nine headings, in this order, with this exact wording. The architect entrypoint's bootstrap-detection check keys off the file's presence at `/work/briefs/onboarding/handover.md`; downstream consumers (architect, future audit machinery, future re-onboarding tooling) will key off the headings for section extraction. The test in A.7 verifies presence by `grep -E '^## N\. <heading>$'`:

1. `## 1. Project identity`
2. `## 2. Source materials inventory`
3. `## 3. Code structural review`
4. `## 4. History review`
5. `## 5. SHARED-STATE.md candidate`
6. `## 6. TOP-LEVEL-PLAN.md candidate`
7. `## 7. Known unknowns`
8. `## 8. Operator's stated priorities`
9. `## 9. Carry-over hazards`

The template treats each as a "must contain" specification rather than a fillable form. Sections 3 and 4 are pre-shaped for the future code migration agent and history migration agent (Sections B and C) — they are valid in Section A's substrate with operator-acknowledged "no automated review run" stubs, and they will be populated by the sub-agents without changing the section's identity or location.

## Notable findings

### F52 — onboarder import needs an explicit chown after `cp -a`

`cp -a /source/. .` preserves the host user's UID (typically 1000) on the copied files. The import temp-clone is created inside a `docker run --rm debian:bookworm-slim` running as root by default, so the temp dir is root-owned but the copied files are 1000-owned. Without a normalising `chown -R root:root .` step before `git add`, git rejects the working tree with `fatal: detected dubious ownership in repository`. Caught during A.7 test development. Fix lives in both `onboard-project.sh` and `infra/scripts/tests/test-onboarder-shell.sh`.

Forward implication: if a future section moves the import step into the onboarder container itself (running as the agent user, UID 1000), this concern reverses — the container's UID matches the source's UID and no chown is needed. The choice of where the import runs is the only handle here; the chown is a host-side artefact.

### F53 — architect /work staleness on long-running architect

The architect container is long-lived. Setup brings it up; the operator may not attach for hours or days. Meanwhile `onboard-project.sh` pushes the handover to main. Without intervention, the architect's `/work` clone is stale — the entrypoint check for `briefs/onboarding/handover.md` would never see the new file.

Resolved in s012 by two coordinated changes: the architect entrypoint runs `git -C /work pull --ff-only --quiet` on every start, and `onboard-project.sh` runs `docker restart ${ARCHITECT_CONTAINER}` after the onboarder discharges. Net effect: by the time the operator runs `./attach-architect.sh`, the architect has already re-entered its entrypoint with the handover present in `/work`, so the bootstrap fires.

The `--ff-only` is intentional: if `/work` has diverged from origin (an architect that committed local-only briefs while disconnected from git-server), the pull will fail loudly with a warning rather than silently merging. The warning is printed; the entrypoint proceeds. This is conservative — it surfaces a real anomaly without blocking startup.

### F54 — onboarder bootstrap is interactive, divergent from planner/auditor

The planner and auditor entrypoints use `claude -p "${BOOTSTRAP_PROMPT}" --permission-mode dontAsk --allowed-tools ...` (non-interactive, print-mode). The onboarder uses `claude "${BOOTSTRAP_PROMPT}" --permission-mode dontAsk --allowed-tools ...` (no `-p` — interactive, prompt seeds the session). This is deliberate: the planner/auditor work without a human in the loop, but the onboarder's elicitation phase **requires** the operator to be in the conversation. The architect's first-attach bootstrap uses the same non-`-p` shape for the same reason.

The brief said "follows the s008 self-bootstrapping pattern". This phrasing covers the **env-var-driven trigger** (BOOTSTRAP_PROMPT detected → entrypoint invokes claude with it before dropping to shell) but does not constrain the `-p` flag. Where the pattern is the operational shape, the `-p`-vs-not choice follows the role's interactivity profile.

Implication for any future test author: the stub-claude pattern needs a tiny generalisation — accept the prompt as `$1` (when invoked non-`-p`) OR as `$2` (when invoked with `-p "<prompt>"`). The s007/s008 stubs handled `-p` only; the s012 test handles non-`-p` only; a future "test all roles in one harness" would dispatch on $1.

### F55 — single-shot enforcement is script-level, not hook-level

The git-server's `update` hook permits the `onboarder` role to push to `refs/heads/main` without path restriction. Single-shot is enforced by `./onboard-project.sh` inspecting `main.git`'s commit count before any state mutation; the hook is a fallback for accidental misuse, not the policy boundary. This is deliberate: a path-based hook rule cannot distinguish the import commit (touches source-tree paths) from the handover commit (touches `briefs/onboarding/handover.md`) without coupling the hook to onboarding semantics. The hook stays simple; the policy lives in one obvious place.

A.7 phase 10 verifies the script-level enforcement end-to-end against the scratch substrate.

### F56 — onboarder allowed-tools list is embedded, not brief-parsed

s011 introduced the "Required tool surface" → `--allowed-tools` plumbing for planners and auditors, parsing the surface from the section/audit brief at commission time. The onboarder has no section brief — it's commissioned by `./onboard-project.sh` and is a project-scoped, not section-scoped, role. Its tool-surface needs are invariant across project types and runs (read /source + /methodology, write /work/briefs/onboarding/, git ops against main, lightweight shell inspection), so embedding a curated allow-list in the entrypoint is correct here.

If a future section wants to make the onboarder's tool surface configurable (e.g., to let an operator preauthorize an LSP probe or a project-specific verifier), the natural shape would be a top-level methodology document (`methodology/onboarder-tool-surface.md`?) that the entrypoint parses via the existing `parse-tool-surface.sh`. Out of scope here.

## Residual hazards

- **Real-project migration not yet exercised.** A.7 uses a synthetic two-file type-1 source tree and a stub claude. The shell's behaviour against a real brownfield codebase — with type 2/3/4 materials, real elicitation rounds, real handover synthesis — has not been observed on this branch. The first real run will happen post-Section C, against a deliberately migrated project. Sections B and C should be ordered before any such run; running onboarding against a real project with the current shell (no code migration agent, no history migration agent) would produce a handover with two large sections marked "no automated review run" that the architect would need to fill manually, which defeats the migration's value proposition.

- **Sub-agent dispatch path is undocumented.** The onboarder-guide tells the agent "do not dispatch sub-agents" because none exist yet. When Sections B and C ship, the guide will gain lifecycle and boundary text for the dispatch mechanism. The asymmetry between profession-name top-level roles and descriptive-name sub-agents is documented (a.1 §"Sub-agent naming convention"), but the mechanics — how the onboarder spawns and waits for sub-agents, how their findings flow into sections 3 and 4 of the handover, how the operator approves their tool surfaces — are entirely Section B / C concerns. The shell does not preempt those design choices.

- **Onboarder image not picked up by `setup-common.sh`'s build phase by default.** `docker compose --profile ephemeral build` (line 148 of setup-common.sh) builds all ephemeral-profile services, which now includes `onboarder`. **Verified manually:** a `docker build -t agent-onboarder:latest infra/onboarder/` succeeded during A.7 test prep (cached agent-base layer + new entrypoint.sh). However, on a host where setup was last run before s012 ships, the image is absent until either (a) the operator re-runs setup, or (b) they `docker compose --profile ephemeral build` manually. The latter is fast (the dockerfile is tiny). The deployment-docker §6.4 paragraph does not warn about this; if a future operator runs setup once at version N and then ships s012 forward, the missing image surfaces only when they try `./onboard-project.sh`. The error message is informative (`Unable to find image 'agent-onboarder:latest' locally`) but the friction is real. Mitigation belongs in a future "version upgrade" runbook, not in s012.

- **Architect entrypoint `git pull --ff-only` is silent on conflict.** The pull is `--quiet`; if it fails, the entrypoint prints a one-line warning and proceeds. For the brownfield onboarding flow this is correct (the architect was idle, nothing diverged, the pull should succeed cleanly). For a long-lived architect that has been disconnected and made local commits, it could mean the architect starts up without the latest origin/main. The warning is in the entrypoint stdout (visible in `docker logs architect`), but a casual operator who never reads container logs would not see it. Not blocking; flagged for a future "operational observability" pass.

- **Operator intake file is mounted via `${INTAKE_FILE:-/dev/null}`.** Compose interpolates this at parse time; the resulting bind mount has `/dev/null` as its source when no intake is provided. The onboarder entrypoint checks `[ -f /onboarding-intake.md ] && [ -s /onboarding-intake.md ]` to gate the "present" banner; `/dev/null` mounted as `/onboarding-intake.md` is a 0-byte file, so the `-s` test correctly reports "none". This works but is mildly counterintuitive ("why is /dev/null being mounted as a markdown file?"). A future cleanup could use a more idiomatic guard (compose `extends:` overlay, or always require an explicit `--intake-file`). Cosmetic, not load-bearing.

- **Methodology-run smoke discipline (s011) not exercised against the onboarder.** s011's section report establishes the discipline that any future section touching commissioning, tool-surface, role entrypoints, or methodology spec must include a methodology-run smoke pass in its Definition of Done. s012 touches the spec (new role) and adds a role entrypoint, so the discipline applies. The A.7 test exercises the onboarder's commissioning end-to-end against a synthetic substrate; it does **not** exercise a downstream planner/auditor commission against the post-onboarding main (because no section brief exists yet at that point). This is consistent with the brief's "out of scope: real-project migration runs" but worth flagging — the methodology-run smoke for s012 would be "run onboarder, then have the architect author s001 brief, then commission a planner, then audit", and that's a four-section dance, not a one-section verification.

## Definition of done — status

- [x] `methodology/onboarder-guide.md` exists, structurally parallel to other role guides.
- [x] `methodology/onboarder-handover-template.md` exists, documents the nine-section structure.
- [x] `infra/onboarder/{Dockerfile,entrypoint.sh}` exist; container builds cleanly (verified during A.7 prep); entrypoint honours `BOOTSTRAP_PROMPT`.
- [x] `docker-compose.yml` has an `onboarder` service in the ephemeral profile.
- [x] `setup-linux.sh` and `setup-mac.sh` generate the onboarder keypair idempotently (via `generate-keys.sh` + `setup-common.sh` mkdir).
- [x] `./onboard-project.sh` exists at the repo root, executable, with `<source-path>` + optional `--type`/`--intake-file`.
- [x] Architect entrypoint detects the handover and bootstraps the first attach (Option α).
- [x] `infra/scripts/tests/test-onboarder-shell.sh` exists and passes (35/35) using the stub-claude pattern.
- [x] F51 doc-fix landed in `architect-guide.md` and `auditor-guide.md`.
- [x] `deployment-docker.md`, `agent-orchestration-spec.md`, `README.md` updated per A.9.
- [x] Section report at `briefs/s012-onboarder-shell/section.report.md` (this file) including brief echo, per-task summary, canonical bootstrap prompts, α-vs-β choice + rationale, test transcript reference, F51 excerpts, template headings, residual hazards.

## Push status

Section branch will be pushed to origin before discharge. The human handles the section→main merge, per the substrate-iteration pattern that s001–s011 established.
