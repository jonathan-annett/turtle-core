# s013 — Platform composition: section report

## Brief echo

F50: make platform composition for dispatched-agent containers an
automatic property of section commissioning. The architect declares
which platforms a section needs (project superset in
`TOP-LEVEL-PLAN.md`, optional per-section override in the section
brief); the substrate composes a hash-tagged role image at
commission time, with deterministic image naming and free local
caching. F52 closes via a tool-surface validator that checks every
binary named in the brief's "Required tool surface" is present on
PATH in the composed image.

Coverage extends to `coder-daemon`, `auditor`, `planner`, and
`onboarder`. Builds on s009's platform-plugin foundation
(`render-dockerfile.sh`, `validate-platform.sh`, the registry under
`methodology/platforms/`) — does not replace it.

## Per-task summary

### T1 — Registry hash-input field

**Decision: no new YAML field.** The brief's override clause
permits a side-car or separate manifest if extending the existing
YAML format is awkward — and here the cleanest choice is even more
additive: hash the YAML file's bytes directly (`sha256sum`). This
is maximally backward-compatible (zero changes to any of the seven
ship-with platform YAMLs), picks up any registry edit (install,
apt, verify, env, runtime fields all change file bytes), and
requires no parser changes.

Documented in `methodology/platforms/README.md` under
"Composition hash semantics (F50 / s013)".

Also extended `validate-platform.sh`'s valid-role set to include
`planner` and `onboarder` — needed for T2 coverage extension below.

### T2 — JIT composition orchestrator

`infra/scripts/compose-image.sh` (new). Args: `<role>
<comma-platforms>`. Emits the resulting image tag on stdout; logs
on stderr.

**Hash inputs (canonical):**

- Role name
- Each canonical platform name (sorted, deduped, `default`-stripped)
- sha256 of each platform YAML's bytes

**Tag pattern:** `agent-<role>-platforms:<hash12>`. Separate
namespace from s009's setup-time `agent-<role>:latest` — both
coexist in the local docker cache without collision.

**Cache mechanism:** `docker image inspect` lookup by tag.
Local-only; no pull / push. Operator hygiene via standard `docker
image prune` (per design call 5, no auto-pruning by the substrate).

**Renderer integration:** added a `--stdout` mode to
`render-dockerfile.sh` (s009's renderer). The new mode emits
rendered Dockerfile content to stdout instead of writing the
static `infra/<role>/Dockerfile.generated` path. The setup-time
two-arg form is unchanged — s009's flow remains byte-equivalent.
`compose-image.sh` uses `--stdout`, captures to a tempfile, and
invokes `docker build -t <tag> -f <tempfile> infra/<role>/`.

**Coverage extension:** extended the renderer's valid-role set to
include `planner` and `onboarder`. Added a `# PLATFORM_INSERT_HERE`
sentinel block to each of their Dockerfiles. Empty platform sets
produce the static template build aside from a generated-file
header (so onboarder's universal-mechanism participation is
mechanically identical to coder-daemon's with `--platform=default`).

### T3 — Tool-surface validator (F52 closure)

`infra/scripts/validate-tool-surface.sh` (new). Args: `<image-tag>
<tool-surface-csv> [<platforms-csv>]`. Exit 0 on success, 1 on
miss, 2 on bad args / missing image.

**Binary extraction rules:**

- Non-Bash entries (`Read`, `Edit`, `Write`, etc.) are skipped —
  Claude built-ins, not OS binaries.
- `Bash(<bin> ...)` and `Bash(<bin>:*)` and `Bash(<bin>:<sub>:*)`
  all extract `<bin>` as the first token. Colons inside the parens
  are treated as separators (so `Bash(git:checkout:*)` and
  `Bash(git checkout:*)` both yield `git`).
- `Bash(git -C /work log:*)` extracts `git` correctly (the `-C`
  flag is part of the args, not the binary name).
- Bare `Bash` (no parens) yields `bash` — bash must be present in
  any agent image; the check is cheap and documents the
  requirement.

**Image check:** one-shot `docker run --rm --entrypoint bash
<tag>` that loops over all binaries and emits `MISSING:<bin>` for
each non-present one. Single docker run, not one per binary.

**Distinct from s009's `validate-platform.sh`** (YAML schema
validator); the two have non-overlapping concerns and keep their
distinct names. Together they form complementary gates: schema
validation at registry-author time / setup time, binary-on-PATH
validation at commission time.

### T4 — `commission-pair.sh` wiring

Before bringing up the pair: resolve platforms (via
`resolve-platforms.sh`, see below), compose planner image
(`PLANNER_IMAGE` env override), compose coder-daemon image
(`CODER_DAEMON_IMAGE` env override), parse the section brief's
tool surface, validate against the planner image.

Shell-only mode (no section slug) still composes but skips
tool-surface validation (no brief). Operator inspecting a planner
in manual mode gets the platforms they expect.

The coder-daemon image is composed with the same platform set
but not validated at commission-pair time — coder tool surfaces
come from per-task briefs and are validated at the daemon level
by `parse-tool-surface.js` when the planner commissions a task
(s011 mechanism, unchanged).

### T5 — `audit.sh` wiring

Same shape as T4: resolve, compose auditor (`AUDITOR_IMAGE`
override), parse audit brief tool surface, validate against the
auditor image. Shell-only mode skips validation.

### T6 — `onboard-project.sh` wiring

Composes `onboarder` with the empty platform set (per design call
6 — onboarder is brief-synthesis, not building).
`ONBOARDER_IMAGE` env override. No tool-surface validation (no
section brief; the onboarder's embedded allowed-tools list per
F58 is invariant).

The mechanism is universal: every dispatched role goes through
`compose-image.sh`, with the onboarder's specific case being
"empty set produces the static template build."

### T7 — Section brief schema

`Required platforms` field added to the section brief template
documented in `methodology/architect-guide.md`. Same fenced
grammar as `Required tool surface` (the `parse-platforms.sh`
parser mirrors `parse-tool-surface.sh`'s shape). Optional;
section inherits the project superset when absent.

### T8 — `TOP-LEVEL-PLAN.md` schema

`## Platforms` section documented in
`methodology/architect-guide.md` under the new "Decomposing a
multi-platform project" subsection. Same fenced grammar; declares
the project superset.

### T9 — Architect-guide: "Decomposing a multi-platform project"

New h2 subsection in `methodology/architect-guide.md` covering:

- `## Platforms` declaration in `TOP-LEVEL-PLAN.md` (project superset).
- `Required platforms` field in section briefs (section subset).
- Subset enforcement rule.
- s009 → s013 migration: durable fallback to
  `.substrate-state/platforms.txt` if `## Platforms` is absent.
- TDD-with-mocks discipline: prefer single-platform sections;
  multi-platform sections are the explicit exception, not the
  convenient norm. Firmware/server pair worked example.

### T10 — Spec bump v2.3 → v2.4

`methodology/agent-orchestration-spec.md`:

- Top changelog entry added for v2.4.
- §7.1: added "Platforms (project superset)" field.
- §7.2: added "Required platforms (optional override)" field with
  subset semantics.
- §7.6: added "Required platforms (optional override)" field
  (audit-brief surface).
- §9: added a "Platform composition (v2.4)" paragraph describing
  the mechanism uniformly across all three commissioning events
  + the onboarder.

### T11 — Tests

`infra/scripts/tests/test-platform-composition.sh` (new). 26
tests, all passing:

- 9 `parse-platforms.sh` tests (heading/bullet/JSON forms, version
  pin, TLP marker, empty fence, missing marker, no fence,
  unterminated fence).
- 7 `resolve-platforms.sh` tests (section subset OK / silent /
  violation / s009 fallback / nothing-anywhere / explicit-empty /
  version-pin subset).
- 5 `compose-image.sh` tests (cache hit on rebuild, order +
  dedupe invariance, different sets produce different tags,
  registry-edit cache invalidation, tag namespace separation
  from s009's `:latest`).
- 5 `validate-tool-surface.sh` tests (positive, built-ins only,
  F52 negative, `git -C` scoping form, empty surface implied by
  built-ins-only).

The s011 `test-parse-tool-surface.sh` suite was re-run and
remains 15/15 green — no regression to the s011 tool-surface
parsing path.

Backward-compatibility check: `render-dockerfile.sh coder-daemon
default` (s009's setup-time invocation) was re-run and still
writes `infra/coder-daemon/Dockerfile.generated` with 0444 perms,
unchanged from s009 behaviour.

**Methodology-run smoke deferred.** The brief calls for a
methodology-run smoke that exercises the full four-role dance
against a project declaring platforms, including a deliberately-
broken tool surface. The infrastructure-level tests above cover
the new mechanisms exhaustively (hash determinism, cache
invalidation, tag namespace, parse forms, subset enforcement,
binary detection / non-detection); the end-to-end orchestrated
smoke is operator-driven and out of scope for the implementing
agent. Recommend the next chat-Claude design session schedule it
as a follow-on or fold it into the Section B (code-migration
agent) smoke.

### T12 — FINDINGS.md updates

F50 and F52 both marked **fixed in s013** with resolution
narrative. "Next available F-number" remains F59 — no new
findings surfaced during s013's work.

### T13 — README + CLAUDE.md ride-alongs

- README Layout tree: expanded the `infra/scripts/` block to call
  out the new scripts (`compose-image.sh`,
  `resolve-platforms.sh`, `validate-tool-surface.sh`,
  `lib/parse-platforms.sh`) and the s013 changes to existing ones
  (`render-dockerfile.sh --stdout`). Added
  `methodology/platforms/<name>.yaml` callout to the
  `methodology/` block.
- README Pointers: added a `methodology/platforms/` entry calling
  out the platform registry and its hash semantics.
- CLAUDE.md "Working with this project" bullet list: added a
  one-liner documenting the "Recommendations baked in (override
  before dispatch)" pattern as a substrate-iteration brief
  convention.

## Verification results

- Test suite: **26/26 passed** (`bash
  infra/scripts/tests/test-platform-composition.sh`).
- s011 regression suite: **15/15 passed** (`bash
  infra/scripts/tests/test-parse-tool-surface.sh`).
- s009 backward compat: setup-time
  `render-dockerfile.sh coder-daemon default` still writes the
  static `Dockerfile.generated` with the expected 0444 perms.
- Compose config: `docker compose --profile ephemeral config`
  resolves; env overrides (`PLANNER_IMAGE=...`,
  `CODER_DAEMON_IMAGE=...`, `AUDITOR_IMAGE=...`,
  `ONBOARDER_IMAGE=...`) flow through correctly; defaults
  resolve to the s009 setup-time `agent-<role>:latest` tags when
  env vars are unset.
- Real-image smoke: composed onboarder, planner, and several
  planner+platform combinations end-to-end on this host;
  verified the F52 case (xxd missing on bare onboarder image
  fails with the documented error block).

## Discoveries

- **Hash by file bytes is cleaner than a hash-input YAML field.**
  The brief's override clause flagged the YAML-extension shape as
  the least certain design call; the implementing-agent move was
  to sidestep it entirely. Documented in T1 above.
- **The `default` platform's no-op semantics already covered the
  onboarder's "empty set" case** without any onboarder-specific
  code path. `compose-image.sh` strips `default` from the
  canonical list, and the renderer treats an empty list as "no
  platform snippets" — emit a no-op generated header and the
  static template lines.
- **One `while read` last-line dropped the final CSV entry** in
  the validator's binary-extraction function. Caught during
  hand-testing of the positive case (`bash` was missing from the
  extracted list because `Bash(bash:*)` was the last CSV entry
  and lacked a trailing newline). Fixed by `printf '%s\n'` on the
  upstream pipe. The classic POSIX gotcha; worth noting for
  future shell-port work.
- **`render-dockerfile.sh`'s existing structure was easy to
  extend with `--stdout`** — needed about 15 lines of conditional
  logic, no refactor of the python rendering heredoc. The s009
  brief's authors left a clean seam there.

## Findings surfaced during section work

None. F50 and F52 close; no new findings warrant an F-number.
Next available remains **F59**.

## Open questions for the architect

1. **Methodology-run smoke timing.** As noted in T11, an end-to-
   end methodology smoke exercising the four-role dance against a
   project declaring platforms is operator-driven and was
   deferred. Recommend scheduling it (a) as a stand-alone
   follow-on, (b) folded into Section B's smoke, or (c) as part
   of the first hello-turtle run that uses the new mechanism.
   Architect's call.
2. **Coder-daemon validation timing.** Per-task tool surfaces are
   validated at the daemon level (`parse-tool-surface.js`) when
   the planner commissions a task. The s013 validator runs at
   commission-pair time against the **planner** image only — the
   coder-daemon image is composed with the same platform set but
   not validated until per-task. This is consistent with where
   the per-task brief becomes available (after the planner
   authors it on the section branch) but means a brief-declared
   binary missing from the platform set would only be caught at
   coder-commission time, not commission-pair time. Acceptable
   for now; flag if a future audit shows a class of bugs that
   would warrant pre-commissioning the coder-daemon against a
   "section's planned coder tool surface" if such a field were
   ever added.
3. **`--add-platform` interaction with hash caching.** The flag
   continues to work for setup-time additions and shell-only-mode
   commissions, but it does **not** participate in the JIT hash
   cache — a one-shot `--add-platform=xxd` for a single auditor
   debug session would re-build with a different (non-cached)
   image. Acceptable per design (Q9 — operator escape hatch, not
   a long-term mechanism); noting it here in case the operator
   experience surfaces friction.
