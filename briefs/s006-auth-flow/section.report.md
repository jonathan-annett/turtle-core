# s006-auth-flow — section report

## Brief echo

Follow-up to s005, surfaced during the first end-to-end run on a
fresh VPS substrate. Path B authentication did not work end-to-end
on a fresh install. Two related symptoms were observed:

1. The architect's `/home/agent/.claude/` mount root was root-owned
   on first start, so when `claude /login` ran as agent, the
   credential write silently failed. OAuth completed server-side
   but no `.credentials.json` landed on disk.
2. `claude-state-shared` was created at setup time but never
   received `.credentials.json`, so ephemeral planners / coders /
   auditors could not inherit auth.

The brief baked in five recommendations and asked the architect to
override before dispatch. Recommendations 1, 2, 3, and 5 were
accepted as written; recommendation 4 (a `verify.sh
--refresh-credentials` mode) was deferred pending investigation,
and the investigation revealed it was unnecessary — the refresh
helper already exists, runs every `verify.sh` invocation, and is
idempotent. The four open questions raised in `investigation.md`
were resolved by the architect as: (1) Dockerfile pre-create over
the brief's entrypoint-driven fix, (2) drop the
`--refresh-credentials` flag, (3) keep RW ephemeral mount, (4)
update all three doc surfaces.

## Summary of investigation findings

Full report at `briefs/s006-auth-flow/investigation.md`. Headlines:

- The bug had two distinct causes that surfaced as one symptom.
  Cause A was the Dockerfile gap; cause B was the alpine helper's
  ownership leak (only fully understood after the first iteration's
  re-test exposed it).
- The brief's "credential-sharing mechanism missing" framing was a
  downstream symptom of cause A: with no creds in the architect
  volume, the refresh helper hit its rc=99 branch correctly, leaving
  the shared volume empty.
- All compose mounts were already correctly wired. No
  `docker-compose.yml` changes needed.

## Root cause and fix

The fix landed in two iterations because the bug had two layers.

### Layer 1 — Dockerfile pre-create (architect Path B)

`infra/base/Dockerfile` did not pre-create `/home/agent/.claude`.
Docker initialises an empty named volume's mount root by copying
the *first-mounting container's* image-layer ownership at the same
path. With nothing to copy from, Docker creates the mount root as
`root:root 0755`. On Path B the architect is the first mount, so
this hits the architect volume; `claude-code` (running as agent)
silently fails to write `.credentials.json` on first
`claude auth login`.

Fix: in the same `RUN` that creates the agent user, also create
`/home/agent/.claude` as `agent:agent 0700`. One image change
covers all four agent images via inheritance from `agent-base`.

### Layer 2 — alpine helper chowns the destination volume root

The Dockerfile pre-create only protects volumes where the agent
image is the *first* container to mount them. For
`claude-state-shared` (and for `claude-state-architect` on Path A),
the alpine refresh helper in `verify.sh` and `setup-common.sh` is
the first writer. The helper runs as root and `cp`s
`.credentials.json` into `/dst`; Docker creates `/dst` as
`root:root 0755` in the volume the first time the helper mounts
it, and that ownership persists. When the planner later mounts the
volume, the agent-base pre-create has no effect — Docker only
seeds an empty volume from image content; once non-empty, existing
ownership stands.

Symptom this caused in the planner (observed during first re-test
on the VPS): `/home/agent/.claude` is `root:root 0755` with
agent-owned `.credentials.json` inside. Reads work; atomic-replace
writes (`.tmp` → rename) and subdir creation
(`cache/`, `backups/`) both fail EACCES. Token rotation would
have failed silently several hours into a session.

Fix: in all three alpine helper invocations
(`verify.sh` §6, `setup-common.sh` Path A copy, `setup-common.sh`
architect→shared sync), unconditionally `chown 1000:1000 /dst &&
chmod 0700 /dst` regardless of whether there are creds to copy.
Idempotent on already-correct volumes; **retroactive on existing
broken volumes** — running the new `verify.sh` on a substrate
that pre-dates the fix repairs both volumes' mount roots in
place.

### Documentation updates

- `setup-common.sh` trailing-banner "First steps" block split into
  Path A / Path B paths; Path B now explicitly tells the operator
  to run `./verify.sh` after first login.
- `README.md` Path B walkthrough now includes the `./verify.sh`
  step with rationale (propagates creds into shared volume;
  skipping it leaves ephemerals un-authed).
- `methodology/deployment-docker.md` §9 carries an implementation
  note on the pre-create requirement so a future image refactor
  doesn't drop the `mkdir`.

## Files modified

```
infra/base/Dockerfile                      # +6 / -2  (pre-create + comment)
verify.sh                                  # +14     (chown /dst in helper)
setup-common.sh                            # +21 / -2 (chown /dst in both helpers
                                           #          + Path A/B banner split)
README.md                                  # +9 / -2  (Path B walkthrough)
methodology/deployment-docker.md           # +1 / -1  (§9 implementation note)
briefs/s006-auth-flow/investigation.md     # +313    (6.a deliverable)
briefs/s006-auth-flow/section.report.md    # this file
```

The "modified entrypoints" line item from the brief's DoD is empty
by design: the investigation showed the chown had to land in the
base image and the alpine helpers, not in the entrypoints (which
run as `agent` and have no privilege to chown).

## Verification

### On the developer host (scratch volumes)

Layer 1 fix (Dockerfile pre-create):

- Patched base image builds clean; all five role images
  (`agent-{base,git-server,architect,planner,coder-daemon,auditor}`)
  rebuild on top without regression.
- Fresh empty named volume mounted at `/home/agent/.claude` in the
  base image is `agent:agent 0700`; agent can write
  `.credentials.json`.

Layer 2 fix (alpine helper chown), tested across four scenarios on
scratch volumes:

| scenario                                         | end state                  | agent writes work? |
|--------------------------------------------------|----------------------------|--------------------|
| Fresh empty dst volume, run new helper           | uid 1000 mode 0700         | yes                |
| Idempotent re-run on already-correct volume      | unchanged                  | yes                |
| Pre-existing broken dst (root:root 0755 + file)  | retro-fixed to uid 1000 0700 | yes                |
| rc=99 path (no creds in src)                     | uid 1000 mode 0700         | yes                |

Scenario 3 is the upgrade-path verification: `verify.sh` retro-fixes
`claude-state-shared` (and via `setup-common.sh`,
`claude-state-architect` on Path A) on an existing substrate without
volume teardown.

### On the VPS (end-to-end Path B)

Re-test on a fresh VPS substrate with the iteration-2 fix landed.
Transcript captured operator-side at
`~/s006-test-transcript-v2.log`. All three previously-failing
planner-side checks now pass:

- `ls -la /home/agent/.claude/` in the planner shows
  `agent:agent 0700` (was `root:root 0755`).
- `touch /home/agent/.claude/.credentials.json.tmp` in the
  planner succeeds (was EACCES — the bug that would have surfaced
  on token rotation).
- `mkdir /home/agent/.claude/cache` in the planner succeeds (was
  EACCES — the bug that would have prevented `claude-code`
  scaffolding cache/backups subdirs).

Architect side also verified:

- `ls -la /home/agent/.claude/` on first attach shows
  `agent:agent 0700` (Dockerfile pre-create taking effect on the
  first mount of the empty `claude-state-architect` volume).
- `claude auth login` writes `.credentials.json` successfully
  on the first attempt — no manual chown workaround required.
- `verify.sh` reports 10 ok / 0 fail post-login, including
  `architect creds present and synced into shared volume`.

The full sequence — `setup-linux.sh`, `attach-architect.sh`,
`claude auth login`, detach, `verify.sh`, `commission-pair.sh
<slug>`, planner starts logged-in — works without manual
intervention on first try.

## Residual hazards

- **Layer 2 retro-fix narrows the upgrade-path concern.** The
  earlier draft of this report flagged "existing volumes are not
  retro-fixed" as a residual hazard. That is now wrong for two of
  three cases: re-running the new `verify.sh` on a substrate that
  pre-dates the fix repairs `claude-state-shared`'s mount root in
  place, and re-running `setup-linux.sh` (which invokes the Path A
  helper) repairs `claude-state-architect`'s mount root on Path A
  hosts. Neither requires `docker compose down -v` or volume
  teardown.

  The remaining un-retro-fixed case is **Path B architect volumes
  that pre-date the fix and still have a root-owned mount root**.
  These exist only on substrates where the operator hit the
  original bug, applied the manual `docker exec -u root
  agent-architect chown -R agent:agent /home/agent/.claude`
  workaround, and is still running on that volume. The workaround
  fixed the runtime symptom; the chown made the dir
  agent-owned (just like the new Dockerfile pre-create would
  have); so functionally these substrates are equivalent to a
  freshly-fixed Path B substrate. No further action required.

- **Ephemeral RW write-through under token rotation is not
  end-to-end tested.** The VPS test exercised the chown surface
  (creating `.tmp` files and subdirs in the planner), so the
  permission classes are right. An actual token-rotation event
  during a live commission has not been rehearsed because it
  requires either waiting hours for rotation or forging an
  expired token. Latent risk remains low: the chown fix removes
  the specific failure mode (EACCES on `.tmp` creation), and the
  next `verify.sh` run will re-sync from the architect anyway.

- **macOS keychain interaction with Path B.** Original s000 report
  flagged that macOS `claude-code` may store credentials in the
  system keychain rather than `~/.claude/.credentials.json`. If
  the in-container Path B login on a macOS host writes to the
  keychain rather than the volume, the s006 fix is a no-op there.
  Not tested — would need a macOS host. Outside the brief's scope
  but worth carrying forward as an open item.

## Open follow-up

None requested in s006 scope. The Path B end-to-end gate is met
on the test VPS; section is ready for review and merge to main
once approved.
