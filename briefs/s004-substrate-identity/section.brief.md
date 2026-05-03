# turtle-core update brief — substrate identity sentinel

## What this is

A follow-up to the s001/s002/s003 iteration brief. Addresses the
residual hazard surfaced in the s002 section report: plain
`./setup-linux.sh` will silently regenerate per-role SSH keys when
`infra/keys/<role>/` is empty, without checking whether a substrate
already exists. If a substrate is running against the same tree (or
against a *different* tree on the same host whose Docker state is
visible — the case Jonathan hit), the host and containers diverge.

The fix is not a fail-fast on empty directories. The deeper problem is
that **a substrate has no explicit identity**. Presence of key files is
inferred state; setup should be checking authoritative state.

This brief packages the fix as one section, **s004-substrate-identity**.

---

## Recommendations baked in (override before dispatch)

Four design calls. Each flagged below; edit before dispatch to override.

1. **Identity is a UUID stored in two places, generated on first setup.**
   - `.substrate-id` file at repo root, gitignored, mode 0644.
   - Label `app.turtle-core.substrate-id=<uuid>` on the
     `claude-state-architect` Docker volume, set at volume creation.
   - Both must match on every setup invocation. Mismatch is fatal.

   Considered alternatives: storing only on disk (loses the cross-tree
   detection that's the actual bug), storing only in Docker (the tree
   has to be authoritative for a checked-out clean state to be a fresh
   install), using git remote URL or repo path (fragile under renames
   and forks).
   **Override:** change the format, location, or label namespace.

2. **Migration of existing substrates (like hello-turtle): explicit
   one-shot command, not auto-detection.**
   `./setup-linux.sh --adopt-existing-substrate` (and equivalent for
   mac). Run by the user once after upgrading to the substrate-id
   release. Generates a UUID, writes the sentinel, labels the
   `claude-state-architect` volume. Refuses to run if a `.substrate-id`
   already exists in the tree.

   Considered alternative: auto-tag on first run after upgrade. Rejected
   because it would silently legitimize whatever substrate state happens
   to be present — including the wrong one (if multiple substrates
   exist on the host). Explicit command makes the upgrade visible and
   the user accountable for which substrate is being adopted.
   **Override:** specify auto-tagging or a different command name.

3. **Existing key files in `infra/keys/` are sufficient evidence of an
   existing substrate during adoption.** The `--adopt-existing-substrate`
   flow assumes that if `infra/keys/<role>/id_ed25519` files exist on
   disk, they belong to whatever substrate the volume label will be
   attached to. The flow does not attempt to verify that the host
   keys match the keys the running container actually has bind-mounted
   — that level of paranoia is out of scope.

   **Override:** add a verification step that exec's into the running
   architect to confirm key file SHA matches host.

4. **One section, executed serially after s003.** The work is tightly
   coupled — design + setup integration + generate-keys.sh refactor +
   migration + docs all touch the same code paths. Splitting would
   introduce more coordination cost than it saves.
   **Override:** request a split (likely along
   identity-mechanism / migration / docs lines).

---

## Top-level plan

**Goal.** Make substrate identity an explicit, checkable property.
Eliminate the silent-key-regeneration hazard. Provide a clean
migration path for existing substrates.

**Scope.** One section. No parallelism.

**Sequencing.** Execute after s001/s002/s003 land in `main`.

**Branch.** `section/s004-substrate-identity` off `main`.

---

## Section s004 — substrate-identity

### Section ID and slug

`s004-substrate-identity`

### Objective

Introduce an explicit substrate-identity mechanism. Setup scripts and
key-generation behavior must check this identity before touching state.
Provide a one-shot migration command to adopt existing substrates that
predate the mechanism.

### Available context

The bug was identified during s002 verification on Jonathan's
Chromebook. The trigger: he ran `./setup-linux.sh --install-docker` in
the *turtle-core* template repo (a clone of the GitHub repo, used for
substrate development), while a separate substrate was running from a
different tree (`~/hello-turtle/`). The turtle-core tree had empty
`infra/keys/<role>/` directories (correct state for the template).
Setup ran key generation as a side effect (s002 fixed this for the
`--install-docker` flag specifically, but the no-flag path retains the
hazard). The host's turtle-core tree gained fresh keys; the running
hello-turtle substrate continued running against its own (different,
older) keys via its own bind mounts. No actual divergence was observed
because the two substrates were unrelated, but the divergence path is
real for any case where the same tree is the source of truth for a
running substrate.

The four roles that consume keys (architect, planner, coder, auditor)
all read from `infra/keys/<role>/id_ed25519`, bind-mounted into their
containers from the host filesystem. The git-server holds matching
public keys in `authorized_keys`, also assembled from the host.
generate-keys.sh's current contract is "create a key if absent" — it
has no visibility into whether the substrate it's supplying already
exists.

The repo's compose file already creates the `claude-state-architect`
volume. This volume is the natural carrier for an immutable label
because it's owned by the substrate's most stable component (the
long-lived architect) and is created once at first setup.

### Tasks (informal decomposition)

The agent may decompose differently, but this is the suggested order:

**4.a — Define the identity mechanism.**
- A `.substrate-id` file at repo root, format: a single line containing
  a UUID v4. Gitignored. Mode 0644.
- A label `app.turtle-core.substrate-id=<uuid>` on the
  `claude-state-architect` Docker volume.
- Document the format and location in `methodology/deployment-docker.md`
  (a new subsection in §3 or §9 — agent's call).

**4.b — Integrate identity check into setup-linux.sh and setup-mac.sh.**
At a sensible early point in setup, before any key generation or
volume creation:

- If `.substrate-id` exists on disk: read it; check that
  `claude-state-architect` exists with a matching label. Three
  outcomes:
  - Both present and matching: proceed (existing substrate, expected
    case for re-runs).
  - Both present but mismatched: fail loudly. Error message must name
    the disk uuid, the volume uuid, and explain that this means the
    tree and the Docker state are from different substrates. Suggest
    `docker volume inspect claude-state-architect --format '{{json .Labels}}'`
    for diagnosis and recovery options (tear down with
    `docker compose down -v`, restore the right tree, or run
    `--adopt-existing-substrate` if appropriate).
  - Disk has id, volume doesn't (or doesn't exist): fail loudly. Means
    the user has a tree from one substrate but no live Docker state
    matches it. Suggest `--adopt-existing-substrate` if they're
    intentionally migrating, or `rm .substrate-id` if they want a fresh
    install.
- If `.substrate-id` is absent: check whether
  `claude-state-architect` exists at all.
  - Volume absent: fresh install. Generate UUID, write sentinel,
    proceed to volume creation (which will pick up the label from the
    compose definition — see 4.c).
  - Volume present (without label or with): fail loudly. Means there's
    a substrate in Docker that this tree doesn't know about. Suggest
    `--adopt-existing-substrate` if the user knows the Docker state
    matches this tree, or `docker compose down -v` to start fresh.

**4.c — Wire the volume label into docker-compose.yml.**

Add the label to `claude-state-architect` in the `volumes:` section:

```yaml
volumes:
  claude-state-architect:
    labels:
      app.turtle-core.substrate-id: "${SUBSTRATE_ID:?SUBSTRATE_ID must be set}"
```

The setup scripts export `SUBSTRATE_ID` from `.substrate-id` before
invoking compose. The `:?` form fails fast if the variable is unset,
which is the right behavior — compose should not invent a label.

**4.d — Refactor generate-keys.sh.**

Add a precondition: refuse to run if the parent substrate state is
inconsistent. Specifically, the script should require either:
- `.substrate-id` exists AND the volume label matches (ordinary
  re-setup), or
- the script is invoked in a context that explicitly sets a flag
  signaling "first-time install with no substrate-id yet" (set by
  setup scripts during fresh-install path in 4.b).

Without one of those, the script exits non-zero with a message
directing the user to run setup-linux.sh / setup-mac.sh, which will
diagnose properly.

This means generate-keys.sh is no longer a standalone-safe entry
point. That's a design tightening worth noting in the section report.

**4.e — Implement `--adopt-existing-substrate` flag.**

Add to setup-linux.sh and setup-mac.sh. Behavior:
- Refuse if `.substrate-id` already exists in the tree (safety: don't
  let the user re-adopt and clobber an id).
- Verify that the running Docker state is consistent (volume exists,
  containers can be inspected, keys on host match what containers see
  to whatever extent is checkable without root). If checks fail, abort
  with diagnostics rather than adopting.
- Generate a new UUID, write `.substrate-id`, label the existing
  `claude-state-architect` volume.
- Note the volume-label immutability constraint: Docker volume labels
  cannot be updated after creation. The label must be added by
  recreating the volume, OR the agent must investigate whether
  `docker volume update` (Docker 25+) is available for this. Document
  whichever path is taken.

If volume-recreation is required, that's a substrate-restart event:
the architect container must be stopped, the volume recreated with
the label, contents preserved (copy in/out of a temporary container),
and the architect restarted. This is non-trivial — flag for the
architect's review if the agent reaches this and wants confirmation
before implementing.

**Architect note (recommendation):** if `docker volume update` works
in the supported Docker versions (25+ confirmed), use it. If only
24.x is available on Crostini's apt repo, prefer the recreate-with-
preserve approach and document the operational cost. **Override:**
specify which path.

**4.f — Update README.md.**

- Document `.substrate-id` and the substrate-identity model in the
  Authentication or a new "Substrate identity" subsection.
- Document `--adopt-existing-substrate` in Prerequisites or
  Quickstart, with a clear note that it's a one-shot migration tool.
- Update Troubleshooting:
  - Add a "Setup says my tree and Docker state are from different
    substrates" entry.
  - Add a "Setup says I have Docker state for a substrate this tree
    doesn't know about" entry.
  - Reference the diagnostic `docker volume inspect` command.

**4.g — Tests.**

- Add a test for the matching-id path (existing substrate, re-setup
  succeeds quietly).
- Add a test for the mismatched-id path (fails with a clear error,
  exits non-zero).
- Add a test for the disk-only path (fails, suggests adoption or
  cleanup).
- Add a test for the volume-only path (fails, suggests adoption or
  fresh install).
- Add a test for the fresh-install path (no disk, no volume → success
  with new UUID written to both).
- Add a test for the adoption path (live volume, no disk → adoption
  succeeds, both have matching id).
- Tests run in CI or via a shell harness; agent's choice. If using
  shell, document the test runner.

### Constraints

- The identity check must be the first state-mutation gate in setup.
  Anything that runs before it (platform detection, prereq verification,
  `~/.docker` ownership preflight from s002) is fine. Anything that
  could mutate substrate state must come after.
- generate-keys.sh's loss of standalone-safety is acceptable. Document
  it in the section report.
- The volume-label immutability case (4.e) must not silently fail.
  Either it works via `docker volume update`, or it does the
  recreate-with-preserve dance with explicit operator visibility, or
  it bails out with a clear "your Docker version doesn't support this;
  here's how to do it manually" message.
- No changes to roles' Dockerfiles or daemon.js. This is a
  substrate-state-management section, not a role-behavior section.

### Definition of done

- `.substrate-id` is generated on fresh setup and carried across
  re-setups.
- `claude-state-architect` carries a matching label.
- All five identity-state combinations (both match, both mismatch,
  disk-only, volume-only, fresh) handled with appropriate behavior
  per 4.b.
- generate-keys.sh refuses to run outside an authorized context.
- `--adopt-existing-substrate` works for the migration case and
  refuses to re-adopt.
- README documents the model, the flag, and the troubleshooting paths.
- Tests cover the six scenarios in 4.g.
- Section report at `briefs/s004-substrate-identity/section.report.md`
  including: brief echo, per-task summary, which volume-label-update
  path was taken (and why), what generate-keys.sh's new contract is.

### Out of scope

- Per-role identity (e.g., per-tree planner/coder/auditor identities
  for shared hosts running multiple parallel section pairs against the
  same architect). The substrate-id is one-per-substrate; if multi-
  tenancy on a host becomes a real need, that's a future section.
- Identity rotation (changing a substrate's UUID). If the user wants
  to rotate, they tear down and re-install. No tooling for this.
- Backporting to in-repo briefs (e.g., adding a substrate-id check to
  briefs/sNNN-slug/section.brief.md templates). Not relevant.
- Cryptographic identity (e.g., a substrate signs its briefs with a
  long-lived key). Out of scope; the UUID is for humans and scripts,
  not for cryptographic verification.

### Repo coordinates

- Base branch: `main`.
- Section branch: `section/s004-substrate-identity`.
- Tasks branch from there per spec §6.

### Reporting requirements

Section report at `briefs/s004-substrate-identity/section.report.md`
on the section branch. Must include:

- Brief echo.
- Per-task summary.
- Which volume-label-mutation path was taken in 4.e (`docker volume
  update` vs. recreate-with-preserve), and the reasoning.
- generate-keys.sh's new contract spelled out in one paragraph.
- Test output for all six scenarios in 4.g.
- Any residual hazards spotted during the work.

---

## Execution

Single agent on the host (same pattern as s001/s002/s003). The agent
works through 4.a–4.g in order, committing per task. After 4.e it
should pause if it determines the volume-label-update path requires
the recreate-with-preserve approach — that's an operational change to
existing substrates and worth confirmation before executing.

If the agent finds genuine ambiguity that this brief doesn't resolve,
the right move is "brief insufficient" + discharge. Same discipline
as before.
