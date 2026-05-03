# s004-substrate-identity — section report

## Brief echo

Address the residual hazard surfaced in the s002 section report: plain
`./setup-linux.sh` will silently regenerate per-role SSH keys when
`infra/keys/<role>/` is empty, without checking whether a substrate
already exists. The fix is not a fail-fast on empty key directories —
the deeper problem is that a substrate has no explicit identity, so
setup has been inferring presence from key files instead of checking
authoritative state. This section introduces explicit substrate
identity as a `.substrate-id` UUID at the repo root paired with a
matching `app.turtle-core.substrate-id` label on the
`claude-state-architect` Docker volume; gates setup on that pair;
refactors `generate-keys.sh` to refuse standalone use when state is
inconsistent; and ships a `--adopt-existing-substrate` migration
command for substrates that predate the mechanism.

The brief baked in four design recommendations (UUID-in-two-places,
explicit migration command, host keys as sufficient evidence of an
existing substrate, single section). All four were accepted; no
overrides requested.

## Per-task summary

### Task 4.a — define the identity mechanism

**Status:** done.

`.substrate-id` at the repo root, single line of UUID v4 in
lower-case canonical form, mode 0644, gitignored. Paired with
`app.turtle-core.substrate-id=<uuid>` on the `claude-state-architect`
Docker volume, set at volume-create time. Documented as a new §3.5
"Substrate identity" subsection in `methodology/deployment-docker.md`,
including the five-outcome matrix, the rationale for the architect
volume as the carrier (durable, owned-once, predates ephemerals), and
a forward reference to the `--adopt-existing-substrate` flag.

The incoming `turtle-core-substrate-identity.brief.md` was filed under
`briefs/s004-substrate-identity/section.brief.md` to align with the
section-numbering convention the substrate enforces on managed
projects (and consistent with the s003 retroactive filing of the
s000-setup brief).

Diff: see commit `318b2c4`.

### Task 4.b — substrate-identity gate in setup-common.sh

**Status:** done.

Created `infra/scripts/substrate-identity.sh` as a sourced helper that
exports the constants (`SUBSTRATE_ID_VOLUME`, `SUBSTRATE_ID_LABEL_KEY`,
`SUBSTRATE_ID_FILE`) and four functions: `substrate_id_generate`,
`substrate_id_is_valid`, `substrate_id_read_disk`,
`substrate_id_read_volume`, `substrate_id_write_disk`, and the gate
itself, `substrate_id_gate`. The gate covers the brief's five outcomes:

| `.substrate-id` | architect volume | label | Behavior |
|---|---|---|---|
| absent | absent | n/a | Fresh: generate UUID, write sentinel, FRESH=1. |
| absent | present | any | Die loudly (Case 2) — tree naive of running substrate. |
| present | absent | n/a | Die loudly (Case 3) — tree describes a substrate with no live Docker state. |
| present | present | absent | Die loudly (Case 4) — predates the mechanism; recommend adoption. |
| present | present | mismatch | Die loudly (Case 5) — different substrates. |
| present | present | match | Quiet success (Case 6); export `SUBSTRATE_ID`, FRESH=0. |

`setup-common.sh` sources the helper and runs the gate immediately
after the prerequisite checks (`docker info`, `docker compose
version`) and before any state mutation — directory creation, key
generation, volume create, image build, `compose up`. The gate
exports `SUBSTRATE_ID` and `SUBSTRATE_ID_FRESH_INSTALL` for downstream
use, plus `TURTLE_CORE_SETUP_AUTHORIZED=1` so generate-keys.sh's own
guard recognises the setup-mediated context.

Constants are written with the `: "${VAR:=default}"` form so the test
harness can override them without patching the helper.

Diff: see commit `998cffc`.

### Task 4.c — wire the volume label

**Status:** done. Deviated from the brief's literal recommendation;
documented below.

**Brief recommendation:** declare the label in `docker-compose.yml`:

```yaml
volumes:
  claude-state-architect:
    labels:
      app.turtle-core.substrate-id: "${SUBSTRATE_ID:?...}"
```

**What I did instead:** set the label via `docker volume create
--label app.turtle-core.substrate-id=$SUBSTRATE_ID` in
`setup-common.sh`'s volume-provisioning loop, and added a comment
block to `docker-compose.yml` explaining where the label comes from.

**Why:** `claude-state-architect` and `claude-state-shared` are
declared `external: true` with fixed names. Compose ignores all
configuration on external volumes — labels declared in the compose
YAML would never be applied. Removing `external: true` would let
compose set the label at create time, but it would also change
operational semantics (`compose down -v` on the main project would
wipe the volume, which is currently a property the README documents
as the deliberate "nuke and start over" path; the external flag is
also belt-and-braces against per-pair compose teardowns reaching
upward). Keeping the volume external and labelling it at
`docker volume create` time preserves both properties. The
fail-fast `${SUBSTRATE_ID:?SUBSTRATE_ID not set}` assertion in the
loop guards against label-less creation if some future refactor
sources `setup-common.sh` out of order.

The rest of the brief's intent — that compose should not invent a
label and that `SUBSTRATE_ID` must be set before the volume is
created — is preserved.

Diff: see commit `fb1f11a`.

### Task 4.d — refactor generate-keys.sh

**Status:** done.

`generate-keys.sh` now refuses to run unless one of two conditions
holds. **The script's new contract** — spelled out as the brief's
reporting requirement asks:

> generate-keys.sh requires either (a) `TURTLE_CORE_SETUP_AUTHORIZED=1`
> in the environment (set only by `setup-{linux,mac}.sh` after its
> own substrate-identity gate has run, covering both fresh-install and
> ordinary re-setup paths), or (b) standalone invocation in a tree
> whose `.substrate-id` exists *and* whose `claude-state-architect`
> volume's `app.turtle-core.substrate-id` label exactly matches.
> Without one of those, the script exits 1 with a message directing
> the operator at setup, which performs the proper diagnosis.
> Standalone invocation in a coherent state remains possible (the
> brief explicitly accepts this), but inconsistent-state cases — the
> ones that produced the s002 hazard — are now blocked.

The script sources `substrate-identity.sh` for the constants and the
read helpers, so the standalone check uses the same logic as the
gate. The constants are overridable via env vars; this is also what
lets the test harness substitute synthetic volume names.

Diff: see commit `164e1be`.

### Task 4.e — `--adopt-existing-substrate` flag

**Status:** done. Volume-label-mutation path: **recreate-with-preserve.**

**Why this path was chosen.** Docker 29.4.1 (the agent's host) confirms
that `docker volume update` is *cluster volumes only*:

```
$ docker volume update --help
Usage:  docker volume update [OPTIONS] [VOLUME]
Update a volume (cluster volumes only)
```

`claude-state-architect` is a local-driver volume; `docker volume
update` cannot touch it. There is no other in-place mechanism for
mutating a Docker volume's label set. Recreate-with-preserve is the
only available path, even though Docker 25.0+ added the `volume
update` command.

**Implementation.** `substrate_id_adopt` in `substrate-identity.sh`
runs four preconditions (no pre-existing sentinel, volume must
exist, volume must not already be labelled, per-role host keys
present per the brief's "sufficient evidence" check), then performs
the rotation in seven steps:

  1. `docker compose stop architect` (graceful; non-fatal if not running).
  2. `docker volume create claude-state-architect-rotate-$$` (scratch).
  3. `docker run debian:bookworm-slim cp -a /src/. /dst/` from the live
     volume to scratch (preserves perms, ownership, subdirs).
  4. `docker volume rm claude-state-architect`.
  5. `docker volume create --label app.turtle-core.substrate-id=$NEW_ID
     claude-state-architect`.
  6. `docker run debian:bookworm-slim cp -a /src/. /dst/` from scratch
     back to the labelled volume.
  7. `docker volume rm` the scratch volume; write `.substrate-id`.

The architect restart happens later in `setup-common.sh`'s normal
flow (`compose up -d git-server architect`), so adoption + plain
setup is one continuous user invocation.

Each step that touches Docker has its own diagnostic on failure,
naming explicit recovery commands, because a half-completed rotation
needs operator intervention. Verified end-to-end against an isolated
synthetic volume in scenario 6 of the test harness: contents (root
file, nested subdir, ownership 1000:1000) survived rotation; label
applied; sentinel written.

`setup-{linux,mac}.sh` parse `--adopt-existing-substrate` and reject
the combination with `--install-docker` (the two have unrelated
purposes). When the flag is set, `setup-common.sh` runs the adopt
function before the gate; on success the gate sees matching state
and falls through to ordinary setup.

I did **not** execute `--adopt-existing-substrate` against the agent's
real host (the running `agent-architect` container has an active
claude-code session). The agent's verification was confined to the
isolated synthetic-volume harness. The user should run the flag
deliberately on their own host when they are ready; the brief's
discharge pause-point applies, in spirit, to that operator step.

Diff: see commit `8fa8957`.

### Task 4.f — README.md updates

**Status:** done.

Three additions:

  * **New top-level "Substrate identity" section** between
    Authentication and Role lifecycle. Explains the model, lists the
    five-outcome matrix in tabular form, and cross-references
    `methodology/deployment-docker.md` §3.5. Notes that
    `generate-keys.sh` is no longer safe to run standalone in
    inconsistent-state cases.
  * **New Prerequisites subsection "Optional:
    `--adopt-existing-substrate`"** alongside the existing
    `--install-docker` subsection. Documents the flag as a one-shot
    migration tool, lists its four refusal preconditions, and warns
    against using it on fresh installs.
  * **Three new Troubleshooting entries** — one per inconsistent
    gate outcome:
    - "Setup says my tree and Docker state are from different substrates"
    - "Setup says I have Docker state for a substrate this tree doesn't know about"
    - "Setup says my tree describes a substrate with no live Docker state"
    Each cites the `docker volume inspect ... --format '{{json
    .Labels}}'` diagnostic and the appropriate recovery options.

Diff: see commit `395a982`.

### Task 4.g — tests

**Status:** done; 8 of 8 scenarios pass (six required + two adoption
preconditions).

Shell harness at `infra/scripts/tests/test-substrate-identity.sh`,
~290 lines. Uses pid-suffixed scratch volume names
(`turtle-core-test-vol-<pid>`) and an isolated `/tmp` tree per test
so it cannot touch the host's real `claude-state-architect`. Each
scenario runs in a subshell that sources the helper with overridden
constants. Stubs `docker compose stop` so the adoption test does not
fight a real compose project; passes other docker calls through. UUID
source: `/proc/sys/kernel/random/uuid` (Linux) with a `uuidgen`
fallback — the harness does not require `uuid-runtime` installed.

Test runner: bash, run as `bash infra/scripts/tests/test-substrate-identity.sh`.
Cleanup runs in a trap so failures still leave the host clean.

#### Test output

```
----------------------------------------------------------------------
Scenario 1: fresh install
[substrate-identity] Fresh install. Generated substrate identity: <uuid>
[substrate-identity] Wrote .../.substrate-id; <volume> volume will be labelled with this UUID.
EXIT=0 FRESH=1 ID=<uuid>
PASS: fresh install: gate generated UUID, wrote sentinel, signalled FRESH=1
----------------------------------------------------------------------
Scenario 2: matching id
[substrate-identity] Confirmed: <uuid>
EXIT=0 FRESH=0 ID=<uuid>
PASS: matching id: gate confirmed identity quietly
----------------------------------------------------------------------
Scenario 3: mismatched ids
[substrate-identity] FATAL: substrate identity mismatch:
    .../.substrate-id (disk) : <disk-uuid>
    <volume>                 : <vol-uuid>
The tree and the Docker state are from DIFFERENT substrates...
[diagnostic and recovery options]
PASS: mismatched ids: gate failed loudly, named both UUIDs
----------------------------------------------------------------------
Scenario 4: disk only
[substrate-identity] FATAL: .../.substrate-id claims substrate identity:
    <uuid>
but docker volume '<volume>' does not exist. The tree describes a
substrate that has no live Docker state on this host.
[diagnostic and recovery options]
PASS: disk only: gate failed loudly with recovery options
----------------------------------------------------------------------
Scenario 5a: volume only, labelled
[substrate-identity] FATAL: docker volume '<volume>' exists, but this tree has no .substrate-id...
[diagnostic and recovery options including --adopt-existing-substrate]
PASS: volume only (labelled): gate failed loudly, suggested adoption
----------------------------------------------------------------------
Scenario 5b: volume only, unlabelled
[substrate-identity] FATAL: docker volume '<volume>' exists, but this tree has no .substrate-id...
[same diagnostic; gate does not distinguish labelled-vs-unlabelled when sentinel is absent]
PASS: volume only (unlabelled): gate failed loudly, suggested adoption
----------------------------------------------------------------------
Scenario 6: adoption
[substrate-identity] Adopting existing substrate. New identity: <uuid>
[substrate-identity] Volume rotation in progress...
[substrate-identity] Stopping architect container (graceful, ~10s timeout)...
[substrate-identity] Creating scratch volume <volume>-rotate-<pid>...
[substrate-identity] Copying <volume> → scratch...
[substrate-identity] Removing <volume> (contents preserved in scratch)...
[substrate-identity] Recreating <volume> with app.turtle-core.substrate-id=<uuid>...
[substrate-identity] Restoring contents from scratch → <volume>...
[substrate-identity] Removing scratch volume...
[substrate-identity] Adoption complete. Substrate identity: <uuid>
EXIT=0 FRESH=0 ID=<uuid>
PASS: adoption: contents preserved (root + nested), label applied, sentinel written
----------------------------------------------------------------------
Scenario 7: adoption refuses pre-existing sentinel
[substrate-identity] FATAL: .../.substrate-id already exists. Adoption mints a NEW identity...
[recovery instructions]
PASS: adoption: refused because .substrate-id already exists
----------------------------------------------------------------------
Summary: 8 passed, 0 failed
```

(UUIDs and paths replaced with placeholders for readability — the
harness writes real UUIDs into its temporary trees and prints the
full real values on each invocation.)

Diff: see commit `2fc50d4`.

## Aggregate surface area

Files created:
- `infra/scripts/substrate-identity.sh` — sourced helper; constants,
  generate/read/write helpers, `substrate_id_gate`,
  `substrate_id_adopt`. ~395 lines total after 4.e.
- `infra/scripts/tests/test-substrate-identity.sh` — shell test harness.
- `briefs/s004-substrate-identity/section.brief.md` — incoming brief
  filed by convention.
- `briefs/s004-substrate-identity/section.report.md` — this document.

Files modified:
- `setup-common.sh` — sources the helper; runs adopt (if flag) then
  gate; passes `SUBSTRATE_ID` into volume creation; exports
  `TURTLE_CORE_SETUP_AUTHORIZED`.
- `setup-linux.sh`, `setup-mac.sh` — `--adopt-existing-substrate`
  arg parsing, `--help` updates, mutual-exclusion with
  `--install-docker`.
- `infra/scripts/generate-keys.sh` — precondition check sourcing the
  helper; refuses on missing/inconsistent state; passes through with
  `TURTLE_CORE_SETUP_AUTHORIZED=1`.
- `docker-compose.yml` — comment block on `claude-state-architect`
  documenting where the label comes from at runtime.
- `methodology/deployment-docker.md` — new §3.5 "Substrate identity".
- `README.md` — new "Substrate identity" section, new
  `--adopt-existing-substrate` Prerequisites subsection, three new
  Troubleshooting entries.
- `.gitignore` — `.substrate-id`.

## Residual hazards

  * **Coherent-state standalone invocation of generate-keys.sh.** The
    brief's design accepts that running `generate-keys.sh` standalone
    is allowed when `.substrate-id` exists and the volume label
    matches (Case 6 of the gate). In that path, if the per-role key
    *files* happen to be missing, the script still regenerates them —
    which can desync the host's keys from a running container's
    bind-mounted view, exactly the s002 hazard pattern, just narrower.
    The brief explicitly accepts this; the prevention would be a
    daemon-process check ("is the architect container running and
    using these keys?") which crosses into territory the brief
    declared out of scope. Documented as the residual hazard the
    brief flagged.

  * **Adoption interrupts a live architect session.** Volume rotation
    requires `docker compose stop architect` — a graceful SIGTERM
    with a ~10-second timeout. claude-code's persistence is what
    survives this; if claude-code has unflushed in-memory session
    state, it can be lost. The flag is opt-in and well-documented;
    operators should not run it during active claude-code work.

  * **Half-completed rotations are operator-recoverable but require
    manual steps.** `substrate_id_adopt` prints the exact recovery
    commands when any of its docker calls fails (creating the
    labelled volume, restoring contents, etc.). It does not attempt
    automatic rollback because the steps are non-trivial and a
    half-completed rotation is rare enough that a clearly-documented
    manual recovery path is safer than auto-magic. Worth noting for
    a future hardening pass.

  * **`docker compose down -v` from the main project namespace will
    still wipe `claude-state-architect`** despite `external: true`
    (the `external` flag means compose did not create the volume,
    but `--volumes` still removes any volume the project knows about
    — see the Docker docs for the subtlety). This is unchanged from
    pre-s004; the README's troubleshooting "Nuke and start over"
    section still relies on this behavior. Worth noting only because
    it interacts with the substrate-id model: after a `down -v`, the
    volume is gone but the sentinel persists, which the gate now
    catches as Case 3 (disk-only) and the user can recover via
    `rm .substrate-id` + plain setup.

  * **The `--adopt-existing-substrate` flag was not exercised against
    the agent's real host.** The running `agent-architect` container
    has an active claude-code session; the agent's verification was
    confined to the synthetic-volume test harness. The user should
    run the flag themselves on their host when ready. The flag is
    designed to be safe (refuses if `.substrate-id` exists; preserves
    contents through scratch) but it is, by definition, the kind of
    operational change the brief asked to confirm before executing
    on a live substrate.

## Suggested next steps and dependencies for downstream sections

  * **Exercise `--adopt-existing-substrate` end-to-end on the agent's
    host.** This would close the loop on the residual hazard noted
    above. Not done in this section because doing it would interrupt
    the user's live claude-code session.
  * **Per-role identity for shared hosts.** Out-of-scope here; flagged
    in the brief. If multi-tenancy on a single host becomes a real
    need (multiple parallel section pairs against the same architect),
    a planner/coder/auditor identity per pair becomes useful.
  * **Cryptographic substrate identity.** Out-of-scope. The current
    UUID is for humans and scripts, not cryptographic verification.
    A future hardening section could sign briefs and reports with a
    long-lived substrate key.
  * **Verifying host keys match container view.** The brief's
    "Override" note for §3 of the recommendations suggested an
    optional verification step that exec's into the running architect
    to confirm the host key SHA matches what the container has
    bind-mounted. Not implemented here (out-of-scope per the brief's
    paranoia line). A future section could add this as a subsection
    of `verify.sh`.

## Pointers to commits (in lieu of separate task reports)

- `318b2c4` — 4.a: define substrate-identity mechanism (gitignore,
  deployment-docker §3.5, brief filing).
- `998cffc` — 4.b: substrate-identity gate in setup-common.sh.
- `fb1f11a` — 4.c: label `claude-state-architect` at volume-create
  time (deviation from brief documented above).
- `164e1be` — 4.d: gate `generate-keys.sh` on substrate identity.
- `8fa8957` — 4.e: `--adopt-existing-substrate` migration flag with
  recreate-with-preserve volume rotation.
- `395a982` — 4.f: README updates (model, flag, troubleshooting).
- `2fc50d4` — 4.g: shell test harness for the eight scenarios.
