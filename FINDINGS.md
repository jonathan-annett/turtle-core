# FINDINGS.md — substrate-iteration findings register

Register of findings raised during substrate-iteration work on
turtle-core. This is the canonical source for which F-numbers
are taken and what each one means; check here before assigning a
new one.

**Next available F-number: F62.**

(F50 and F52 were resolved in s013. F59 was raised and resolved in the s014 amendment. F60 and F61 were raised and resolved in the s014 hotfix. See entries below.)

## How to use this register

- **Adding a finding.** Append the next sequential F-number with
  title, status, severity, origin, resolution (if any), and a
  short description. Bump the "Next available F-number" line at
  the top.
- **Closing a finding.** Update status from `open` or `deferred`
  to `fixed` (with the section that resolved it) or `retracted`.
  Leave the entry in place — history is more useful than a clean
  slate.
- **Cross-referencing.** Briefs and section reports can refer to
  findings by F-number with no further citation; the register is
  the lookup.

## Status legend

- **open** — recently surfaced, not yet triaged or scheduled.
- **deferred** — known and acknowledged; no action planned in the
  current sequence. May be picked up later, eliminated by other
  work, or remain documented indefinitely.
- **fixed** — resolved in a specific section. Resolution section
  noted on the entry.
- **retracted** — was raised but on investigation turned out not
  to be a real finding (different cause, false positive, etc.).
- **informational** — documents a design decision or rationale
  rather than tracking a bug. Stays referenceable; not actionable.

## Severity

- **HIGH** — blocks or significantly degrades methodology runs.
- **LOW** — narrow impact, workaround available, or cosmetic.
- **INFO** — no severity in the bug sense; applies to
  `informational` entries documenting rationale.

---

## Findings

### F1–F41 — Pre-handover-chain history

Findings raised in earlier substrate-iteration work, predating
the currently-visible handover chain. Detail lives in older
handovers (pre-s011). Not backfilled here; reach for the handover
chain if you need to look up a specific number in this range.

### F42 — verify-runner used login shell, broke venv PATH

**Status:** fixed in s011. **Severity:** LOW. **Origin:** session
ending in handover-s011-shipped-option-b-flashed.

`setup-common.sh`'s verify-runner invoked commands via `bash -lc`
(login shell), which re-sourced profile scripts and reset PATH,
dropping the virtualenv prefix. Fixed by switching to `bash -c`.

### F43 — verify-runner didn't wrap with pipefail

**Status:** fixed in s011. **Severity:** LOW. **Origin:** same
session as F42.

Pipeline failures silently passed because verify-runner didn't
set `pipefail`. Fixed: `bash -c "set -o pipefail; ${cmd}"`
wrapper.

### F44 — platformio verify broke under pipefail

**Status:** fixed in s011. **Severity:** LOW. **Origin:** same
session.

`platformio-esp32.yaml` verify used `pio platform show espressif32
| head -1`. Under pipefail, `pio` gets SIGPIPE → BrokenPipeError
→ fails. Fixed: `>/dev/null` instead of piping to `head -1`.

### F45 — hypothesised Docker bridge / LAN routing broken on Crostini

**Status:** retracted. **Severity:** N/A. **Origin:**
investigation during smoke debugging.

Initially hypothesised that Docker bridge or LAN routing was
broken on Crostini. Retracted: the smoke test that suggested
this was itself a false negative (see F46). Actual reachability
works (proven via `docker exec agent-architect ssh tdongle-pi
hostname`).

### F46 — LAN smoke test false negative for coder-daemon

**Status:** deferred (informational). **Severity:** LOW.
**Origin:** smoke debugging that led to F45's retraction.

The LAN smoke test in `setup-linux.sh` gives a false negative for
`coder-daemon` → registered remote host. The smoke test runs a
fresh one-shot coder without proper mounts; reachability actually
works. Substrate-side bug in the smoke test itself.

### F47 — wrong-clone keys against running substrate's git-server

**Status:** deferred. **Severity:** LOW. **Origin:** s011 session.

`commission-pair.sh` from the wrong clone silently uses that
clone's role keys, gets permission-denied against the running
substrate's git-server. Operator-discipline issue rather than a
substrate bug. **Eliminated by construction by s012
(resource-name parameterisation)** if/when that section ships —
wrong-clone keys can't collide across clones with different
project names.

### F48 — ephemeral creds go stale after architect OAuth refresh

**Status:** deferred. **Severity:** LOW. **Origin:** s011 session.

Ephemeral roles (planner, coder-daemon, auditor) read
claude-code credentials from a shared volume populated by setup
from the architect's volume. When the architect's OAuth access
token rotates (every several hours), the shared volume goes
stale. Workaround documented: re-run `./verify.sh` (which doubles
as the refresh helper).

### F49 — s008 bootstrap regressed methodology runs

**Status:** fixed in s011. **Severity:** HIGH (was the headline
regression). **Origin:** discovered when methodology runs
requiring autonomous git operations from planner/auditor failed
under s008's non-interactive bootstrap.

s008 made planner/auditor invocations autonomous via
`BOOTSTRAP_PROMPT` but never extended s001's `--allowed-tools`
mechanism to them — every git operation got denied. Fixed in
s011 by making the architect author a "Required tool surface"
field in section and audit briefs, with a shared bash parser
that planner/auditor entrypoints use to set `--allowed-tools` +
`--permission-mode dontAsk`.

### F50 — platform composition

**Status:** fixed in s013. **Severity:** HIGH. **Origin:**
s011 smoke run (auditor image lacked node/npm).

Substrate didn't auto-couple a section's platform needs to agent
images. Affected auditor, coder, and the upcoming code migration
agent (Section B). Resolved in s013 by:

- TOP-LEVEL-PLAN.md `## Platforms` section declaring the project-
  wide superset; section briefs may declare an optional `Required
  platforms` subset override; section ⊆ project superset is
  enforced.
- `infra/scripts/compose-image.sh` composes a hash-tagged role
  image at commission time (`agent-<role>-platforms:<hash12>`),
  cached locally by sha256 of (role + canonical sorted platform
  list + each platform YAML's bytes). Same declaration + unchanged
  registry → cache hit. Registry edit → automatic invalidation.
- Coverage extends to coder-daemon, auditor, planner, and
  onboarder. The s009 setup-time `agent-<role>:latest` tag is
  preserved as a separate namespace; existing substrates continue
  to work unchanged.
- `commission-pair.sh`, `audit.sh`, and `onboard-project.sh` each
  resolve platforms, compose, and (for the brief-bearing scripts)
  validate the tool surface before bringing the agent up.
- Backward compatibility: substrates without `## Platforms` in
  TOP-LEVEL-PLAN.md fall back to `.substrate-state/platforms.txt`
  (s009's record of the setup-time selection). The fallback is
  durable, not transitional.

### F51 — audit-brief tool surface omitted cd / git -C patterns

**Status:** fixed in s012 (A.8 doc-fix ride-along).
**Severity:** HIGH (manifested in two consecutive real audits
with two different auditor-invented workarounds before fix).
**Origin:** s011 smoke run; recurred in hello-turtle s001 audit.

Audit-brief tool surface template, as generated by the architect,
omitted `cd` and `git -C` patterns. First auditor on
hello-turtle s001 got stuck on `cd /auditor` and `git -C
/auditor …` denials; second auditor adapted by working from
`/work` as starting cwd with absolute paths. Fixed in s012 by
adding "cd vs git -C: pattern asymmetry across mounts"
subsection to `methodology/architect-guide.md` (audit-brief
authoring side) and a symmetric subsection to
`methodology/auditor-guide.md` (receiving side). Spec untouched
(the cd/git-C choice is operational, not contract).

### F52 — xxd granted in tool surface but not installed in image

**Status:** fixed in s013. **Severity:** LOW. **Origin:** s011
smoke run. **Resolved as part of:** F50 (s013) — bundled
deliberately because platform composition and tool-surface
validation share the same commission-time gate; splitting them
would have validated the image at a different point than the
composition that produced it.

`xxd` granted in tool surface but not installed in the auditor
image; no validation between the allowlist and image contents.
Resolved by `infra/scripts/validate-tool-surface.sh`, which
extracts the distinct binaries named in any `Bash(<bin> ...)`
pattern and runs `docker run --rm <image-tag> ... command -v <bin>`
to verify each is on PATH. A miss fails commission with a clear
error naming the missing binaries and the platform set used.
Distinct from `infra/scripts/lib/validate-platform.sh` (s009),
which validates YAML schema; the two have non-overlapping
concerns and keep their distinct names.

### F53 — smoke runbook placeholder syntax confuses bash

**Status:** deferred. **Severity:** LOW (doc). **Origin:** s011
session (hit live; restore got tangled, Jonathan started over).

Smoke runbook's restore section uses `<placeholder>` syntax that
bash interprets as input redirection (`-bash: original-uuid: No
such file or directory`). Should be `${UUID}` with an explicit
`UUID=$(cat /path/to/.substrate-id)` instruction above. Doc fix
only.

### F54 — onboarder import needs explicit chown after cp -a

**Status:** fixed in s012. **Severity:** LOW. **Origin:** s012
A.7 test development.

`cp -a /source/. .` preserves the host user's UID (typically
1000) on the copied files. The import temp-clone runs in
`docker run --rm debian:bookworm-slim` as root by default, so
the temp dir is root-owned but the copied files are 1000-owned.
Without a normalising `chown -R root:root .` before `git add`,
git rejects the working tree with `fatal: detected dubious
ownership in repository`. Fixed in both `onboard-project.sh` and
`infra/scripts/tests/test-onboarder-shell.sh`. If a future
section moves the import step into the onboarder container
itself (running as the agent user, UID 1000), this concern
reverses — no chown needed.

### F55 — architect /work staleness on long-running architect

**Status:** fixed in s012. **Severity:** HIGH (would have broken
the architect attach-with-handover path silently). **Origin:**
s012 test design.

The architect container is long-lived. Setup brings it up; the
operator may not attach for hours or days. Meanwhile
`onboard-project.sh` pushes the handover to main. Without
intervention, the architect's `/work` clone is stale — the
entrypoint check for `briefs/onboarding/handover.md` would never
see the new file. Resolved in s012 by two coordinated changes:
the architect entrypoint runs `git -C /work pull --ff-only
--quiet` on every start, and `onboard-project.sh` runs `docker
restart ${ARCHITECT_CONTAINER}` after the onboarder discharges.
`--ff-only` is intentional — surfaces real anomalies (architect
with local-only commits) without silently merging.

### F56 — onboarder bootstrap is interactive, divergent from planner/auditor

**Status:** informational (design decision). **Severity:** INFO.
**Origin:** s012 implementation.

Planner and auditor entrypoints use `claude -p
"${BOOTSTRAP_PROMPT}" --permission-mode dontAsk --allowed-tools …`
(non-interactive, print-mode). The onboarder uses `claude
"${BOOTSTRAP_PROMPT}" --permission-mode dontAsk --allowed-tools
…` (no `-p` — interactive, prompt seeds the session). Deliberate:
the planner/auditor work without a human in the loop, but the
onboarder's elicitation phase requires the operator to be in the
conversation. The architect's first-attach bootstrap uses the
same non-`-p` shape for the same reason. **Implication for
future test authors:** the stub-claude pattern needs a tiny
generalisation — accept the prompt as `$1` (when invoked
non-`-p`) OR as `$2` (when invoked with `-p "<prompt>"`). The
s007/s008 stubs handled `-p` only; the s012 test handles non-`-p`
only; a future "test all roles in one harness" would dispatch on
`$1`.

### F57 — single-shot enforcement is script-level, not hook-level

**Status:** informational (design decision). **Severity:** INFO.
**Origin:** s012 implementation.

The git-server's `update` hook permits the `onboarder` role to
push to `refs/heads/main` without path restriction. Single-shot
enforcement lives in `./onboard-project.sh`, which inspects
`main.git`'s commit count before any state mutation; the hook is
a fallback for accidental misuse, not the policy boundary.
Deliberate: a path-based hook rule cannot distinguish the import
commit (touches source-tree paths) from the handover commit
(touches `briefs/onboarding/handover.md`) without coupling the
hook to onboarding semantics. The hook stays simple; the policy
lives in one obvious place.

### F61 — architect's /work clone is stale between phase-1 push and phase-2 dispatch

**Status:** fixed in s014 (hotfix, polished). **Severity:** HIGH
(blocked dispatch in the post-merge smoke). **Origin:** s014
post-merge methodology-run smoke (phase 1 of
`briefs/s014-code-migration-agent/smoke-runbook.md`, surfaced after
F60 was patched).

**Mechanism.** `infra/architect/entrypoint.sh` (s012 / F55) runs
`git -C /work pull --ff-only --quiet` on every architect-container
start, keeping /work in sync with origin/main across operator
sessions. But that mitigation fires on architect *restart*, and
`./onboard-project.sh` only restarts the architect at the END of
the three-phase flow (after phase 3 lands the final handover).
Between phase 1 (onboarder pushes the migration brief) and phase 2
(host runs `dispatch-code-migration.sh`), the architect's /work is
whatever it was at the architect's previous startup — typically the
initial empty commit on a fresh substrate.

`dispatch-code-migration.sh`'s `check_brief_exists` (and its
subsequent `docker exec ${arch} cat /work/${brief_path}`) inspects
the architect's **working tree** at `/work/${brief_path}`, not the
`origin/main` ref. Without an explicit pull between phase 1 and
phase 2, the working tree never contains the brief the onboarder
just pushed — dispatch fails with "brief not found at
briefs/onboarding/code-migration.brief.md" even though the brief is
present on origin/main.

The phase-1 verification block already ran `git fetch -q origin
main` (which updates the architect's `origin/main` ref) followed by
`git cat-file -e origin/main:...` (which inspects refs, not working
tree). So the verification passed; dispatch failed. The
ref-vs-working-tree split is what made the bug invisible to the
existing check.

**Why this wasn't caught earlier.** The s014 plumbing test
(`test-code-migration.sh`) drives the code-migration container
directly (`ce run --rm code-migration`) without going through
`./onboard-project.sh`'s multi-phase orchestrator — so it never
exercised the stale-/work window the orchestrator opens. The s012
test exercised `./onboard-project.sh` only for its single-shot
rejection path (Phase 10), which exits before the architect-/work-
sync code runs.

**Fix.** Replace the `git fetch -q origin main` in the phase-1
verification block with `git pull --ff-only -q origin main` —
fetches AND syncs the working tree in one operation. Fail loud with
a clear diagnostic if the pull fails (caller can inspect manually
rather than chasing a downstream "brief not found" error). Uses
`${arch_container}` not the hardcoded name to keep the s012 test's
`ARCHITECT_CONTAINER` env override working. The `--ff-only` carries
F55's "surfaces real anomalies" safety: silently merging a diverged
/work could mask a real problem.

**Generalisation.** The same /work-staleness window exists between
any pair of architect-clone-using operations that don't trigger an
architect restart. `commission-pair.sh` and `audit.sh` don't have
this exposure today because the architect commits + pushes briefs
to main directly from inside its own container — there's no
"someone else pushes, then architect's /work needs to see it" race.
The onboarder flow is unique in having a non-architect role push to
main, then expecting the architect's /work to reflect it. Future
similar flows (e.g. when the history migration agent ships in
Section C) need to remember to pull before architect-/work-reading
operations downstream of a non-architect push.

### F60 — `dispatch-code-migration.sh` repo_root resolution off by one level

**Status:** fixed in s014 (hotfix). **Severity:** HIGH (broke the
dispatch helper end-to-end). **Origin:** s014 post-merge
methodology-run smoke (first invocation against a real substrate
exposed the typo; B.8's hermetic test missed it).

**Mechanism.** `infra/scripts/dispatch-code-migration.sh` lives at
`infra/scripts/` — two levels below the repo root. The repo_root
resolution in B.5 used `dirname "${BASH_SOURCE[0]}"`/.. — one level
up, yielding `infra/` instead of the repo root. Every subsequent
`${repo_root}/infra/...` reference (sourcing
`infra/scripts/lib/check-brief.sh`, invoking
`infra/scripts/compose-image.sh`, etc.) resolved to
`infra/infra/scripts/...` — nonexistent paths.

**Why this wasn't caught earlier.** The script uses
`set -uo pipefail` (no `-e`), so `source <nonexistent-file>` printed
an error to stderr but did NOT abort the script. The B.8 plumbing
test's Phase 10 only exercised arg-parsing error paths (`--help`,
`--bogus`, missing source-path) — all of which exit BEFORE the
script reaches any `${repo_root}/...` reference. The script's
behavioural path (the actual dispatch flow) was never exercised end-
to-end by the test; the existing tests only verified arg-parse
diagnostics.

**Fix.** Change `/..` to `/../..` in the repo_root computation. One
character per slash; the path now resolves to the actual repo root.

**Lesson.** Future scripts under `infra/scripts/` (or deeper) must
use `/../..` (or deeper) in their `dirname`-relative repo_root
computation. Similar scripts in the existing tree already do this
correctly — `compose-image.sh`, `resolve-platforms.sh`,
`validate-tool-surface.sh`, `render-dockerfile.sh`. B.5's
`dispatch-code-migration.sh` was the outlier. A defensive
self-check (e.g. `[ -f "${repo_root}/CLAUDE.md" ] || die`) at the
top of any such script would have failed loud at first run; not
adding it everywhere now, but worth considering for any future
substrate-iteration section.

### F59 — `depends_on: git-server` short-circuits the external `agent-net` reference

**Status:** fixed in s014 (amendment). **Severity:** HIGH (broke
brownfield onboarding silently against a long-lived substrate).
**Origin:** s014 post-merge methodology-run smoke (phase 1 of
`briefs/s014-code-migration-agent/smoke-runbook.md`).

**Mechanism (the bit that matters).** When a docker-compose service
declares `depends_on: <name>` AND that name is another service in
the same compose file, compose instantiates `<name>` in the current
project namespace before the external network's DNS resolution can
run. The external `agent-net` network reference (declared with
`external: true, name: agent-net` at the file's bottom and joined by
every dispatched role) was already wired correctly to bridge the
ephemeral compose project (e.g. `-p hello-turtle-onboard`) to the
long-lived substrate's git-server. But `depends_on: git-server` on
the onboarder service forced compose to spin up a fresh git-server
in the ephemeral project namespace first, attaching to fresh
ephemeral `<project>_main-repo-bare` / `<project>_auditor-repo-bare`
volumes. The `container_name: agent-git-server` on the long-lived
git-server made this fail loudly with a collision; without
container_name, the failure would have been silent — onboarder
artifacts (migration brief, draft handover, code-migration report,
final handover) would land in the ephemeral bare repo, which gets
torn down at cleanup, never reaching the architect.

**Why this wasn't caught earlier.** Inherited from s012 where the
onboarder shell's test (`test-onboarder-shell.sh`) scaffolded
everything in one compose project — never exercised the cross-
project scenario. The s014 plumbing test (`test-code-migration.sh`)
followed the same single-project pattern. The first time anything
in s014 was exercised alongside a long-lived substrate it was
supposed to feed into was the post-merge methodology-run smoke.

**Fix.** Removed `depends_on: - git-server` from the onboarder
service in `docker-compose.yml`. The agent-net external network now
does the work it was always wired for: the onboarder container joins
agent-net, resolves `git-server` to the long-lived container via
DNS, and pushes to the long-lived main.git. Other ephemeral roles
(planner, coder-daemon, auditor, code-migration) already lack
`depends_on: git-server` and worked correctly cross-project — the
onboarder was the outlier. Operator-side `is_running agent-git-server`
check in `./onboard-project.sh` (lines 134-145) keeps the long-lived
git-server up before invocation; no new mechanism needed.

**Regression-proof.** `infra/scripts/tests/test-code-migration.sh`
Phase 11 (added in B.12) statically parses `docker-compose.yml` and
fails if the onboarder service declares `depends_on: - git-server`.
A future edit that reintroduces it for "clarity" will fail the test
suite at this assertion with a diagnostic naming F59 by number.

**The trap to avoid.** Reading the bug as a `container_name:`
collision and "fixing" it by parameterising `container_name` would
make the failure silent without addressing the cause — the
onboarder would still write to an ephemeral bare repo. The
`container_name:` parameterisation work is real but separate (its
own substrate-iteration section, not folded in here). F59 is about
the orchestration short-circuit; that's the contract.

### F58 — onboarder allowed-tools list is embedded, not brief-parsed

**Status:** informational (design decision). **Severity:** INFO.
**Origin:** s012 implementation.

s011 introduced the "Required tool surface" → `--allowed-tools`
plumbing for planners and auditors, parsing the surface from the
section/audit brief at commission time. The onboarder has no
section brief — it's commissioned by `./onboard-project.sh` and
is project-scoped, not section-scoped. Its tool-surface needs
are invariant across project types and runs (read /source +
/methodology, write /work/briefs/onboarding/, git ops against
main, lightweight shell inspection), so embedding a curated
allow-list in the entrypoint is correct. **Future
configurability path:** if a section wants to make the
onboarder's tool surface configurable (e.g., to preauthorize an
LSP probe or a project-specific verifier), the natural shape
would be a top-level methodology document
(`methodology/onboarder-tool-surface.md`?) that the entrypoint
parses via the existing `parse-tool-surface.sh`.
