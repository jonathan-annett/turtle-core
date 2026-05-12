# F50 — substrate-wide platform composition

## How to read this brief

This is a **substrate-iteration brief** for work on turtle-core
itself. Read [`CLAUDE.md`](CLAUDE.md) at the repo root before
proceeding — it captures the work-mode (single-agent host-side, not
the methodology's dispatch flow), the `methodology/` boundary, and
the substrate-internal artifact set. The brief assumes that context.

The "Recommendations baked in (override before dispatch)" pattern:
each design call below states a position, the rationale, the
considered alternative, and override-language. If a position is wrong
for your read of the problem, raise it as an amendment **before**
starting the work. Once dispatched, the design calls are committed;
mid-section design changes need an explicit amendment.

Check `FINDINGS.md` at the repo root before assigning any new
F-numbers during this section's work. Next available F-number at the
time this brief is authored is **F59**.

---

## What this is

F50 makes platform composition for dispatched-agent containers an
automatic property of section commissioning. The architect (or
project-level state) declares which platforms a section needs; the
substrate composes an agent image with those platforms at commission
time, with deterministic image naming and free caching. As a side
effect, F50 also closes F52 by adding a tool-surface validator at
commission time that checks every binary named in the agent's tool
surface is present on PATH in the composed image.

F50 was surfaced by the s011 smoke-run auditor (whose image lacked
`node`/`npm` when commissioned against a Node section) and formalised
by the s011 handover-Claude as a HIGH-severity deferred finding. It's
the next substrate-iteration section, scheduled between Section A
(onboarder shell — s012, shipped) and Section B (code migration
agent), and a hard prerequisite for B because the migration agent
needs target-language toolchains to do structural code review.

---

## Relationship to s009 (the platform-plugin section)

F50 is **not greenfield** — it builds on the platform-plugin system
that shipped in s009. The boundary between them, and the framing the
implementing agent should hold while reading the design calls below:

**What s009 already provides (preserve, build on, do not rewrite):**

- `methodology/platforms/<name>.yaml` — the registry of platforms,
  with seven ship-with entries (`default`, `go`, `rust`,
  `python-extras`, `node-extras`, `c-cpp`, `platformio-esp32`).
  Methodology-facing because architects need to consult it when
  authoring section briefs and TOP-LEVEL-PLAN.
- `infra/scripts/render-dockerfile.sh` — renders role Dockerfiles
  from base + platform YAMLs via the `# PLATFORM_INSERT_HERE`
  sentinel.
- `infra/scripts/lib/validate-platform.sh` — validates platform YAML
  schemas (this is **distinct from** F50's tool-surface-binary-on-PATH
  validator — different concerns; both keep their distinct names).
- `infra/scripts/lib/platform-args.sh` — shared argument parsing for
  the existing platform flags.
- `--platform=<name>` flag on `setup-linux.sh` / `setup-mac.sh` for
  picking a substrate-default platform at setup time.
- `--add-platform=<name>` flag for adding platforms to a running
  substrate.
- Composition coverage for the `coder-daemon` and `auditor` roles.

**What F50 genuinely adds:**

1. **Per-section declaration locus.** Currently platforms are
   substrate-wide (chosen once at `setup-linux.sh --platform=...`);
   F50 makes them per-section, with the project superset in
   TOP-LEVEL-PLAN.md and an optional per-section override in the
   section brief.
2. **JIT composition with hash-keyed image cache.** Currently s009
   renders+builds at setup time into a static
   `infra/<role>/Dockerfile.generated`; F50 composes at commission
   time, producing hash-tagged images that get reused across
   commissions and rebuilt only when the declaration or registry
   changes.
3. **Coverage extension** to the `planner`, `onboarder`, and (when
   Section B lands) `code-migration-agent` roles.
4. **Tool-surface validator** — binaries declared in
   `Required tool surface` checked against binaries-on-PATH in the
   composed image. Closes F52. Genuinely new.
5. **Architect-guide guidance** on decomposing multi-platform
   projects (TDD-with-mocks default; multi-platform sections as
   explicitly-flagged exception). New methodology content.

**Registry location stays in `methodology/` — s009 had it right.**
The CLAUDE.md boundary test asks "would a user-project agent ever
need this?" Architects reference the registry when authoring section
briefs (to know what platforms exist) and when populating
TOP-LEVEL-PLAN.md's platforms section. Architects are methodology
actors; the registry is what they reference. The substrate-internal
*consumer* of the registry (the composition script) lives in
`infra/`, but the *reference* is correctly methodology-facing.

**Migration path from s009 to F50 (operator-graceful).** Existing
substrates set up with `--platform=<name>` continue to work without
operator intervention. At commission time, F50 reads the project
superset from TOP-LEVEL-PLAN.md's `## Platforms` section if present;
if absent, the project superset is derived from s009's setup-time
selection (recorded in the substrate's existing state — exact
location known to the implementing agent from the existing code).
The s009 flags continue to function. The new architect-guide
subsection (T9 below) encourages operators to migrate to explicit
TOP-LEVEL-PLAN.md declarations when convenient, but no pre-existing
setup breaks.

**`--add-platform=<name>` is preserved as a commission-time
override.** Operators retain the escape hatch for ad-hoc
debugging — e.g., adding `xxd` to one auditor commission without
modifying any brief. The flag adds platforms on top of whatever the
section's declaration produces; the resulting image is still
hash-cached and the validator still runs against it.

---

## Recommendations baked in (override before dispatch)

### 1. Where the declaration lives

**Position.** Project-level superset in `TOP-LEVEL-PLAN.md` (new
"Platforms" section), with optional per-section override in the
section brief (new "Required platforms" field, parallel to s011's
"Required tool surface").

**Rationale.** The architect maintains both files. Project-wide
platforms ("this is a Node project") live with project-wide
constraints; section-specific platforms ("this section is
firmware-only") live with section-specific constraints. The asymmetry
with tool surface (per-brief only) is deliberate — tool surface
genuinely varies section by section, but platforms are mostly
project-wide. Forcing every brief to re-enumerate the same platforms
is verbose and error-prone.

**Semantics for multi-platform projects.** Project-level declares
the superset (`{node, platformio}` for a Node-server-plus-ESP32-
firmware project). Sections declare their subset (`{platformio}` for
firmware work, `{node}` for server work, both for cross-cutting
integration). A silent section gets the full project superset — safe
default, potentially heavier than needed. The architect should
specify subsets explicitly when sections specialise, per the new
architect-guide subsection in T9 below.

**Validator rule.** Section set must be ⊆ project-level set.
Declaring a platform outside the project superset fails commission
with a clear error. Catches typos and forces a new platform to be
added at project level (architect updates `TOP-LEVEL-PLAN.md`) before
a section can use it — project view stays consistent.

**Considered alternative.** Per-brief only, no project level —
simpler grammar, but pushes the same declaration into every section
brief. Cost outweighs simplicity for single-platform projects and
breaks down further for multi-platform projects where sections
naturally specialise.

**Override.** If grammar uniformity matters more than authoring
efficiency, put platforms in the section brief only; remove the
TOP-LEVEL-PLAN section and the subset validator. Composition
mechanism is unchanged.

### 2. When composition happens

**Position.** Just-in-time at commission. `commission-pair.sh`,
`audit.sh`, and `onboard-project.sh` each read the section's
platform declaration, compute the image hash, check the local docker
cache, and either reuse the tagged image or build it before the
agent comes up.

**Hash semantics.** The hash is over the canonical declaration:
sorted platform set, each platform's `name@version` (if pinned) or
`name` (bare, resolves to registry default), **plus** each
platform's registry-entry content hash. The registry-entry hash
matters — without it, updating an entry's install steps (e.g.,
changing how `python` is installed) wouldn't invalidate cached
images of sections using that platform; with it, the composed
image's hash changes automatically and JIT rebuilds.

The hash does **not** cover image content bytes. Two clones building
the same declaration may pull different upstream package versions
from apt/pip/npm if the mirrors have updated between builds,
yielding different image contents with the same tag. F50 doesn't
promise byte-level reproducibility — that's downstream of upstream
registries and is project-dependency-management territory, not
substrate territory. State this explicitly in the spec / architect-
guide so operators don't expect determinism the design doesn't
promise.

**Considered alternative 1.** Setup-time preload (build all images
during substrate setup). Cleaner operator story ("after setup,
you're ready") but introduces coupling between setup state and
project declarations that has to be re-synchronised whenever
declarations change, and can't preload future section overrides
anyway.

**Considered alternative 2.** Runtime install inside the agent
container (boot, `apt-get install`, then start work). Slow, fragile,
pushes work that should be cached up to every commission. Rejected.

**Override.** If operator clarity outweighs the coupling concern,
bring composition to setup time. Trade-off: slower setup, and a
`verify.sh`-style refresh path on declaration changes.

### 3. Platform taxonomy

**Position.** Language-level names (`node`, `python`, `go`, `rust`,
`platformio`, etc.) drawn from the existing registry at
`methodology/platforms/`, which s009 established. Each registry
entry maps name → install steps (a shell snippet plus any required
apt/brew dependencies) and declares a default version. Version
pinning available via `name@version` syntax (`python@3.11`). Bare
names get the registry default.

The registry stays in `methodology/` per the boundary-test reasoning
in the "Relationship to s009" section above — architects reference
it, so it's methodology-facing. F50 extends the registry with any
additional fields needed for JIT (most likely a content-hash input
field if not already implicit in the YAML structure; this is what
gives Q2's hash its "registry-entry hash" input for cache
invalidation on entry changes).

**Format.** Continue with s009's YAML structure. New fields added by
F50 are additive — existing seven ship-with entries get updated
minimally (just to add whatever new field the hashing needs); no
breaking changes to the schema. The exact addition is the
implementing agent's call provided it preserves backward
compatibility with `render-dockerfile.sh`'s existing parser.

**Considered alternative 1.** Move the registry to
`infra/platforms/` to make it "substrate-internal." Rejected: the
boundary test puts it in `methodology/` (architects reference it),
and migrating would be a significant blast radius for no design
benefit.

**Considered alternative 2.** Free-form install commands instead of
a named taxonomy. Already rejected by s009; F50 doesn't revisit.

**Considered alternative 3.** Finer granularity (`npm` as separate
from `node`). Already rejected by s009 (the seven ship-with
platforms are language-level); F50 doesn't revisit.

**Override.** If the implementing agent finds that extending the
existing YAML format for hashing is awkward (e.g., the registry's
current parser is fragile), they may propose a side-car
`.hash` file per platform entry or a separate manifest. Document
the rationale either way; this is the only place the brief leaves
the registry-data-shape question genuinely open.

### 4. Image construction approach

**Position.** Reuse s009's `render-dockerfile.sh` for the rendering
step; F50 wraps it with the JIT orchestration layer.

The new `compose-image.sh` invokes `render-dockerfile.sh` (or its
internals) to generate the Dockerfile content from base + per-
platform install layers, then runs `docker build` with the
deterministic hash as the tag. The rendering logic — how a platform
YAML becomes Dockerfile lines via the `# PLATFORM_INSERT_HERE`
sentinel — is unchanged from s009.

What's new is the orchestration: hash computation (Q2), cache
lookup, dynamic invocation at commission time rather than setup
time, hash-tagged image naming. Generating linear Dockerfiles for
arbitrary platform combinations is what `render-dockerfile.sh`
already does; F50 doesn't reinvent it.

**Override.** If `render-dockerfile.sh`'s current shape doesn't fit
cleanly under a JIT wrapper (e.g., it assumes setup-time invocation
with side effects on `infra/<role>/Dockerfile.generated`), the
implementing agent may refactor it — extract a library function
that returns the rendered Dockerfile content, leaving the existing
setup-time entry point as a thin caller for backward compatibility.
Document the refactor in the section report.

### 5. Caching strategy and image lifecycle

**Position on caching.** Hash incorporates canonical-sorted platform
set + each platform's registry-entry content hash (per (2) above).
Same declaration + same registry state → same tag → reuse local
image. Different declaration or changed registry entry → different
tag → rebuild.

**Image naming.** Pattern like `turtle-core/<role>:platforms-<hash>`
where `<hash>` is a short prefix of the canonical hash. Role prefix
because auditor/coder/onboarder/migration-agent may have different
base layers even with the same platform set.

**Image lifecycle.** No auto-pruning. The substrate doesn't track
which composed images remain relevant to any section's needs —
operator hygiene via standard `docker image prune` periodically.
Explicit choice: tracking relevance would invert the source-of-truth
from declaration → image to image → declaration, which the design
avoids.

### 6. Onboarder integration

**Position.** Universal mechanism, empty declaration. The onboarder
reads platform declarations like every other dispatched role, but
its declaration is always empty → its composed image is the base
agent image (no platforms added). Cleaner than special-casing the
onboarder out of the mechanism.

### 7. Code-migration-agent integration

**Position.** The migration agent role is another dispatched role
under §3.3. F50 reads the section's platform declaration at
commission time and composes the migration-agent image with those
platforms. No special-casing — once Section B defines the role, F50
already handles its image composition.

### 8. Backward compatibility

**Position.** Existing substrates set up via s009's `--platform=<name>`
flag continue to work without operator intervention. The migration
to F50's per-section model is graceful, not breaking.

**Mechanic.** At commission time, F50's composition script looks for
a `## Platforms` section in TOP-LEVEL-PLAN.md. If present, that's
the project superset. If absent, the project superset is derived
from s009's setup-time platform selection (which is already
recorded in the substrate's state — the exact location is in s009's
code and the implementing agent will see it). Either way, the
project superset is well-defined; per-section overrides and silent-
section semantics work identically in both cases.

**Sections s001–s012** (and anything else pre-dating the "Required
platforms" field) have no override, so they get the project
superset. For a substrate set up with `--platform=node`, that means
the same platforms they had before — no behavior change. For a
substrate set up with default, the project superset is empty → base
image → also no behavior change. Either way: pre-F50 sections work
unchanged.

**`--add-platform=<name>` continues to function** as a commission-
time override that adds platforms to a specific commission's image
(see "Relationship to s009" above). The resulting image is still
hash-cached and the Q9 validator still runs against it.

**The architect-guide subsection (T9)** recommends operators migrate
to explicit `## Platforms` declarations in TOP-LEVEL-PLAN.md when
convenient, but no upgrade pressure is applied — the auto-derive
fallback is durable, not transitional.

**Considered alternative.** Require operators to add `## Platforms`
explicitly as part of upgrading to F50, with a hard error if absent
on a non-default substrate. Rejected — too operator-hostile for a
section that's notionally additive.

### 9. Validation (F52 closure, deliberately coupled)

**Position.** At commission time, after the image is composed and
before the agent starts, the substrate verifies that every distinct
binary named in the agent's tool surface (s011 work) is present on
the composed image's PATH. If any binary is named but missing, the
commission fails loudly with a clear error naming the missing
binaries and the platform set used.

**Why bundled with F50.** Platform composition and tool-surface
validation are deliberately coupled in this section: both happen at
commission time, both inspect the to-be-used agent image, and the
validator's lookup (binaries-on-PATH) is the same surface the
composition mechanism produces. Splitting them into separate
sections would execute the validator at a different point than the
composition that produces what it validates against — strictly
worse than the coupling. F52 closes as a consequence; this is
design coherence, not scope creep. State this rationale explicitly
in the section report so future readers don't misread the bundling.

### 10. Multi-platform sections and parallel coders

**Position on multi-platform sections.** Handled by the set-based
declaration (1). A section declaring `{node, python}` gets one
composed image with both platforms installed. The hash addresses
the composition cleanly regardless of cardinality.

**Position on parallel coders.** When a planner dispatches multiple
coders in parallel for tasks within a section, they all share the
section's single composed image. The section is the unit of platform
declaration; the image is its cache; coders share the image but
operate on disjoint task branches. Explicit position because
parallel-coders-per-section is a natural pattern that the design
needs to be unambiguous about.

### 11. Ecosystem-deps seam

**Position.** The composed image contains language-level toolchains
and their associated package managers (`npm`, `pip`, `cargo`, etc.)
— the platforms from the registry. Project-level dependency
installation (`npm install`, `pip install -r requirements.txt`,
`cargo fetch`) happens at agent runtime, against the composed
image's package managers, against the project's working tree.
That's task work, not platform composition.

**Implication for tool surface.** Agent tool surface for any
platform-using section should include the ecosystem package-manager
command(s) (`Bash(npm ...)`, `Bash(pip install ...)`, etc.) in the
permitted-tools allowlist. The Q9 validator catches mismatches:
declaring `Bash(npm install)` in the tool surface without `node` in
the platform set fails commission.

### 12. TDD-with-mocks → methodology architect-guide

**Position.** F50's section work includes a new subsection in
`methodology/architect-guide.md` titled "Decomposing a multi-platform
project." It captures the TDD-with-mocks pattern: most cross-platform
work is feasible single-platform at the agent level (firmware section
works against mock server, server section works against mock client,
both converge on a stable contract); multi-platform sections are the
explicitly-flagged exception for cross-cutting work where mocks
won't suffice.

The subsection should make clear that the architect should default
to single-platform per section and escalate to multi-platform only
when the section genuinely needs to see both sides. Length probably
30–60 lines, sitting alongside existing architect-guide content
about section briefs and shared-state.

**Why in architect-guide.** The guidance isn't substrate-internal —
it's about how the architect decomposes sections, which is
architect-role concern. Belongs in `methodology/`, not buried in
F50's section archive.

---

## Top-level plan

Tasks roughly in dependency order. Spec / methodology updates ride
alongside the substrate work rather than gating it.

1. Platform registry — structure + initial entries.
2. Composition mechanism — script that reads declaration, computes
   hash (including registry-entry hashes), composes and caches the
   image.
3. Tool-surface validator — at commission, binaries-on-PATH check
   against the composed image.
4. Wire composition + validator into `commission-pair.sh`.
5. Wire composition + validator into `audit.sh`.
6. Wire composition + validator into `onboard-project.sh`.
7. Section brief schema — add "Required platforms" field.
8. TOP-LEVEL-PLAN schema — add "Platforms" section.
9. `methodology/architect-guide.md` — new "Decomposing a
   multi-platform project" subsection.
10. Spec bump v2.3 → v2.4 — note platform declarations in §7.1
    and §7.2.
11. Tests — unit + integration + a methodology-run smoke covering
    the four-role dance with platform composition exercised end-to-
    end (validates F50 and retroactively s012).
12. FINDINGS.md updates — F50 fixed, F52 fixed, next available F59
    (or higher if section work surfaces new findings).
13. README + `CLAUDE.md` ride-alongs — README layout/pointers
    updates; CLAUDE.md gets a one-line note about the
    "Recommendations baked in (override before dispatch)" pattern
    as a substrate-iteration convention.

---

## Section ID and slug

**`s013-platform-composition`.** (s012 is shipped; s013 is the next
section number. If for any reason `git log --all` shows a different
state when you start, raise it before branching.)

---

## Objective

Make the dispatched-agent container images for `coder`, `auditor`,
`onboarder`, and (when Section B lands) `code-migration-agent`
automatically include the target-language platforms the section's
work needs. Eliminate the manual `--add-platform=<extras>`
workaround. Close F50 and F52.

---

## Available context

### Existing primitives

**From s009 (this is what F50 extends — see "Relationship to s009"
near the top for the full boundary):**

- `methodology/platforms/<name>.yaml` — platform registry. Seven
  ship-with entries (`default`, `go`, `rust`, `python-extras`,
  `node-extras`, `c-cpp`, `platformio-esp32`).
- `infra/scripts/render-dockerfile.sh` — Dockerfile renderer using
  the `# PLATFORM_INSERT_HERE` sentinel.
- `infra/scripts/lib/validate-platform.sh` — platform YAML schema
  validator (distinct from F50's tool-surface validator; both keep
  their distinct names and concerns).
- `infra/scripts/lib/platform-args.sh` — shared parsing for the
  existing platform flags.
- `--platform=<name>` on `setup-linux.sh` / `setup-mac.sh` —
  s009's setup-time platform selection.
- `--add-platform=<name>` — commission-time platform addition.
- The substrate state file or env where s009 records its setup-time
  platform selection (location known to the implementing agent from
  the s009 code).

**Pre-s009 substrate primitives F50 wires into:**

- `infra/<role>/Dockerfile` and `infra/base/Dockerfile` — base
  images. The composed image layers on top.
- `commission-pair.sh`, `audit.sh`, `onboard-project.sh` — the three
  commissioning entry points. Each gets a composition+validation
  call added (T4–T6).
- s011's tool-surface parser (in `infra/scripts/`) — provides the
  binary list for the F52 validator.
- `methodology/architect-guide.md` — gets the new "Decomposing a
  multi-platform project" subsection (T9).
- `methodology/agent-orchestration-spec.md` — bumps from v2.3 to
  v2.4 with platform-declaration mentions in §7.1 and §7.2 (T10).

### Related findings

- **F50** (HIGH, deferred): this section's reason for existing.
- **F52** (LOW, deferred): `xxd` granted in tool surface but not
  installed; closes here via the Q9 validator.
- **F46** (deferred, informational): LAN smoke test false-negative —
  not directly addressed; may surface during methodology-smoke.
- **F47** (deferred, LOW): wrong-clone keys against running
  substrate's git-server — orthogonal, not addressed.

### Conventions to reuse

- s011's "Required tool surface" field parsing pattern is the model
  for the new "Required platforms" grammar. Line-oriented,
  bash-parseable.
- The s012 `parse-tool-surface.sh` is the prior art for the
  validator's tool-surface ingestion.
- s012's single-shot pattern (script-level enforcement + hook
  fallback) is the model for the registry hashing — the policy
  lives in one obvious place, not spread across components.

---

## Tasks (informal decomposition)

**T1 — Extend the platform registry.** The registry already exists
at `methodology/platforms/` (from s009) with seven ship-with entries.
F50 extends it with whatever new field(s) the Q2 hashing needs —
most likely a content-hash-input field that captures the bytes from
which the registry-entry hash is computed. The exact addition is the
implementing agent's call provided it's additive (no breaking
changes to `render-dockerfile.sh`'s existing parser) and keeps the
seven ship-with entries valid. Document the new field shape in a
brief comment at the top of one of the YAML files or in a
`methodology/platforms/README.md` if there's no such file already.

**T2 — JIT composition orchestrator.** Implement
`infra/scripts/compose-image.sh` (or similar location). Takes role
+ platform set declaration. Computes canonical hash (sorted set +
per-entry registry hashes from T1). Checks local docker cache for
the tagged image. If miss, invokes the existing s009
`render-dockerfile.sh` to generate the Dockerfile content, then
runs `docker build` with the computed tag.

The rendering logic is s009's; do not duplicate it. If
`render-dockerfile.sh`'s current shape doesn't fit cleanly under a
JIT wrapper (e.g., it has side effects on
`infra/<role>/Dockerfile.generated` that make it awkward to invoke
at commission time), refactor it: extract a library function that
returns rendered Dockerfile content, leave the setup-time entry
point as a thin caller. Idempotent — repeated `compose-image.sh`
calls with the same declaration are cheap (cache hit).

**T3 — Tool-surface validator (F52 closure).** Implement
`infra/scripts/validate-tool-surface.sh` (or similar). Takes an
image tag + parsed tool-surface bash-command list. Extracts the
distinct binaries referenced. Verifies each is on PATH in the image
(e.g., `docker run --rm <tag> sh -c 'command -v <bin>'`). On any
miss, aborts with a clear error listing missing binaries and the
platform set used.

This is a **different validator** from s009's
`validate-platform.sh`, which validates YAML schema. The two have
non-overlapping concerns and keep their distinct names. If their
naming becomes confusing in practice, F50 may choose a more
disambiguating name (e.g., `validate-image-against-tool-surface.sh`)
— implementing agent's call.

**T4 — `commission-pair.sh` integration.** Parse the section
brief's "Required platforms" field (with project-level fallback
from `TOP-LEVEL-PLAN.md`). Compose+validate the planner/coder image
before bringing up the pair. Composition is idempotent so re-runs
of a hung pair don't rebuild unnecessarily.

**T5 — `audit.sh` integration.** Same shape as T4 for the auditor.
Read the section's platform declaration (with project-level
fallback). Compose the auditor image. Validate against the audit
brief's tool surface.

**T6 — `onboard-project.sh` integration.** Empty platform set
always; onboarder's image is the base agent image. The compose call
is a no-op for cache hits after first run — fine; preserves the
universal mechanism.

**T7 — Section brief schema.** Update the section-brief template
(documented in `methodology/architect-guide.md`) to include
"Required platforms" as an optional field. Grammar: line-oriented
like tool surface, one platform per line, bare name or
`name@version`.

**T8 — TOP-LEVEL-PLAN schema.** Add "## Platforms" section to the
canonical TOP-LEVEL-PLAN template. Same grammar as the section
field. Intent is to declare the project superset for use in the
subset validator.

**T9 — Architect-guide new subsection.** Write "Decomposing a
multi-platform project" in `methodology/architect-guide.md`. Cover:
TDD-with-mocks as the default pattern; project-superset / section-
subset / silent-section semantics; audit implications of multi-
platform sections; the default-single-platform / explicit-multi-
platform-exception guidance.

**T10 — Spec bump to v2.4.** Update
`methodology/agent-orchestration-spec.md`:
- §7.1 (top-level plan): add "Required platforms (project superset)"
  to the field list.
- §7.2 (section brief): add "Required platforms (optional override)"
  with one sentence on subset semantics.
- Cross-reference `architect-guide.md` for decomposition discipline.
- Version footer bumped to v2.4.

**T11 — Tests.** Unit tests for `compose-image.sh` (hash
determinism, registry-entry-change invalidation, cache-hit
idempotence) and `validate-tool-surface.sh` (positive case, missing-
binary case, empty surface). Integration tests for each commissioning
script (composition is called with the right declaration, the image
is used, validation runs). **s009 backward-compatibility tests** —
confirm that a substrate set up with `--platform=<name>` and no
`## Platforms` section in TOP-LEVEL-PLAN.md still composes images
correctly from the auto-derived superset (Q8 mechanic); confirm that
adding an explicit `## Platforms` section overrides the auto-
derived behavior. A methodology-run smoke (s011 discipline) that
exercises the full four-role dance against a project declaring
platforms, including a deliberately-broken tool surface to verify
the validator catches the mismatch. The methodology-smoke also
retroactively validates s012's onboarder flow per the deferred audit
agreement.

**T12 — FINDINGS.md updates.** Mark F50 as fixed with section
reference (s013). Mark F52 as fixed (eliminated by F50's Q9
validator). Update "Next available F-number" to **F59** (or higher
if section work surfaces new findings). Add entries for any new
findings surfaced during the section.

**T13 — README + `CLAUDE.md` ride-alongs.** README: add
`infra/platforms/` and the new scripts to the Layout tree; mention
`infra/platforms/` under Pointers as the platform registry.
`CLAUDE.md`: add one line under conventions noting the
"Recommendations baked in (override before dispatch)" pattern as a
substrate-iteration convention.

---

## Constraints

- **`methodology/` boundary holds.** F50 touches the spec,
  architect-guide, and (via the new templates) section briefs —
  methodology-facing. Substrate-internal artifacts (the composition
  script, the tool-surface validator) live outside `methodology/`.
  The platform registry stays in `methodology/platforms/` per the
  boundary-test reasoning (architects reference it); this is a
  deliberate placement, not a violation.
- **s009 is preserved, not replaced.** Do not delete, rename, or
  fundamentally restructure `render-dockerfile.sh`,
  `validate-platform.sh`, `platform-args.sh`, the `--platform` /
  `--add-platform` flags, or `methodology/platforms/`'s existing
  seven entries. F50 extends and orchestrates; if any of those
  components needs refactoring for clean JIT integration, refactor
  surgically and document the change in the section report.
- **Backward compatibility.** Existing sections without "Required
  platforms" continue to work — empty default or auto-derived
  superset per Q8. Do not break s001–s012 or hello-turtle
  s001-blinking-led. Existing substrates set up with
  `--platform=<name>` continue to function without operator
  intervention.
- **F46/F47 not in scope.** Other deferred findings are not touched
  unless they surface during methodology-smoke and warrant an
  on-the-spot fix.
- **No promise of image content reproducibility.** The hash is over
  the declaration; upstream package versions change. Document this
  in the spec and architect-guide so operators don't expect
  determinism the design doesn't provide.
- **No auto-pruning of composed images.** Operator hygiene only;
  document this explicitly.

---

## Definition of done

- Platform registry exists with at least `node` and `python` (plus
  whatever else is straightforward).
- `commission-pair.sh`, `audit.sh`, and `onboard-project.sh` all
  compose-and-validate before commissioning.
- A section brief declaring `Required platforms: node` produces a
  coder image with `node` on PATH and passes validation.
- A section brief declaring a platform outside the project
  superset (e.g., typo) fails commission with a clear error.
- A section brief omitting "Required platforms" gets the project
  superset (or empty if no superset declared).
- The validator catches a deliberately-broken tool surface (e.g.,
  declaring `Bash(npm)` without `node` in the platform set).
- `methodology/architect-guide.md` has the "Decomposing a
  multi-platform project" subsection.
- `methodology/agent-orchestration-spec.md` is at v2.4 with
  platform-declaration mentions.
- All tests pass, including the methodology-run smoke covering the
  four-role dance.
- `FINDINGS.md` is updated; README and `CLAUDE.md` have their
  ride-along changes.
- Section report at `briefs/s013-platform-composition/section.report.md`
  written and committed.

---

## Out of scope

- The code-migration agent itself (Section B). F50 makes the
  substrate ready for it; Section B defines it.
- Parallel multi-platform agents within a single section (e.g.,
  dispatching a node-only agent and a platformio-only agent in
  parallel from the same planner). Deferred as a methodology-level
  concern.
- Image content byte-reproducibility. F50 doesn't pin upstream
  package versions in apt/pip/npm; that's project-dependency-
  management territory.
- Network egress controls during image build or runtime.
- Cross-host substrate deployments — out of scope per existing
  methodology assumptions.

---

## Repo coordinates

- **Base branch:** `main` (currently at `4c87690`).
- **Section branch:** `section/s013-platform-composition`.
- **Spec version:** v2.3 → v2.4 on the section branch; merges to
  `main` with the section.

---

## Reporting requirements

Section report at `briefs/s013-platform-composition/section.report.md`
should cover:

- **Brief echo.** What you understood F50 to be.
- **Per-task summary.** Including the registry shape decided, the
  hash computation details, the validator's observed behavior on
  the various test cases.
- **Verification results.** Unit tests, integration tests, the
  methodology-run smoke output (or an explanation if smoke is
  deferred to a follow-up section).
- **Discoveries.** Things the design calls didn't anticipate.
- **Findings surfaced during section work** (with assigned
  F-numbers, consulting `FINDINGS.md` for the next available number
  before assigning).
- **Open questions** for the architect — anything that should be
  decided before merge.

---

## Execution

Substrate-iteration work, per `CLAUDE.md`. You operate host-side on
`~/turtle-core/`, single-agent, on the section branch. No
`commission-pair.sh` for this work — the substrate itself is what's
being changed, not used. Push the section branch when complete;
the human merges to `main` after review.
