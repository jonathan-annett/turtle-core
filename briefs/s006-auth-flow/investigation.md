# s006 — investigation report

Task: `t006.001-investigate`. Read-only investigation of Path B
authentication flow on a fresh substrate. Answers questions 1–6 from
the section brief §6.a, plus a residual observation worth flagging
before the fix lands.

Scope discipline note: this task is read-only — no source files were
modified. The probe of local `claude-state-{architect,shared}` volumes
in §3 used a `--rm` debian helper container with both volumes mounted
read-only.

---

## 1. Architect entrypoint — privilege model and chown behavior

`infra/architect/Dockerfile` declares `USER agent` (after a brief
`USER root` block that creates `/auditor`). The entrypoint inherits
that, so `infra/architect/entrypoint.sh` runs **as `agent` (uid 1000)
from line 1** — not as root.

The entrypoint never chowns `/home/agent/.claude`. It cannot: it has
no privilege to do so. The script's only writes touch `~/.ssh-rw/`,
`/work` (the workspace volume), and `/auditor`. The
`claude-state-architect` volume mounted at `/home/agent/.claude` is
treated as a pre-existing writable directory.

What actually happens on first-attach to a freshly-created
`claude-state-architect` volume:

- The agent-base Dockerfile creates `/home/agent` as `agent:agent`
  via `useradd -m`. It never creates `/home/agent/.claude`.
- Docker mounts the empty named volume at the (non-existent) path
  `/home/agent/.claude`. Because the path does not exist in the
  image layer, **Docker has no source ownership to copy from** and
  creates the mount root as `root:root` mode `0755`. This is the
  bug the brief identifies.
- `claude-code` then runs as `agent`, attempts to write
  `.credentials.json` into a root-owned directory, and silently
  fails (the OAuth handshake completes server-side, but the local
  credential write returns EACCES which `claude-code` swallows).

When the architect volume is *re-used* across container restarts the
ownership is whatever was set the first time. Because nothing in the
substrate ever rewrites it, the bug is sticky once the volume is
created — only `docker volume rm` + recreate (or the manual
`docker exec -u root … chown`) clears it.

Path A on a fresh volume avoids the bug by accident: `setup-common.sh`
step 7 (lines 161-170) runs a one-shot helper container as root, copies
`.credentials.json` into the volume, and `chown 1000:1000`s the file.
The mount root stays `root:root 0755` but the file inside it is
agent-owned, which is enough for `claude-code` to read it. Path A
never tries to *write* to the mount root.

Path B has nothing to copy in, so step 7's helper does not run, and
the architect later tries to write — hence the bug.

## 2. Ephemeral entrypoints — same shape, same bug class

The three ephemeral images (`planner`, `coder-daemon`, `auditor`) all:

- Inherit `USER agent` from `agent-base`. Their Dockerfiles do not
  revert to `USER root` for the entrypoint.
- Have separate `entrypoint.sh` files (not a shared script) that
  differ only in the role-specific git-clone and identity-config
  blocks. None of them chown `/home/agent/.claude`.

Each ephemeral mounts the *shared* volume at `/home/agent/.claude`,
not the architect volume. So the bug surfaces here only on the very
first commission against a freshly-created `claude-state-shared`
volume — once `setup-common.sh` step 7 (or `verify.sh` step 6) has
copied `.credentials.json` into the shared volume as root + chown'd
it to agent, the file is readable for ephemeral subsequent reads.

But: if an ephemeral ever needs to *write* to `/home/agent/.claude`
(e.g. `claude-code` rotates the access token mid-run and writes the
new one back), the write will fail for the same reason — mount root
is `root:root`. This is latent in the current setup; it has not bit
anyone yet because Path B never got far enough to exercise it.

## 3. The `claude-state-shared` volume — current contents, scaffold path

On *this* host (developer machine, Path A), `claude-state-shared`
contains exactly one file:

```
drwxr-xr-x 1 root root  34   .
-rw------- 1 1000 1000 470   .credentials.json
```

Mount root is `root:root 0755`; the credentials file is `agent:agent
0600`. There is no `backups/` or `cache/` subtree.

The `backups/` and `cache/` subdirectories the brief observed on the
VPS were *not* scaffolded by any substrate code. They were created
by `claude-code` itself, presumably after the first interactive
`claude /login` ran inside a planner container. `claude-code` writes
to `~/.claude/backups/` and `~/.claude/cache/` as part of its normal
operation; once it ran with the manual chown applied, it populated
those directories in-place.

Trace of who *does* populate the shared volume legitimately:

- `setup-common.sh` step 7 (lines 185-195): the second helper
  container in `provision_auth()` copies `.credentials.json` from
  architect volume to shared volume. No-op for Path B at setup time
  (architect has no creds yet).
- `verify.sh` lines 78-102: identical helper, runs every time
  `verify.sh` is invoked. This is the canonical refresh path. The
  brief's recommendation 4 calls for a `verify.sh
  --refresh-credentials` mode — that mode already exists implicitly:
  `verify.sh` always runs the refresh.

Conclusion for Q3: nothing in the substrate scaffolds `backups/` or
`cache/`. Those are claude-code's own bookkeeping, written by the
first ephemeral to successfully run claude-code as agent against the
shared volume. They are not load-bearing for the credential-sharing
mechanism.

## 4. `verify.sh` and the architect→shared copy

`verify.sh` lines 78-102 contain the copy step. It runs every
invocation, is idempotent, and explicitly handles the "credentials not
yet present" case (rc=99) with a user-facing message pointing at
`./attach-architect.sh` + `claude auth login` + re-run verify.sh.

So the credential-sharing **code path exists and is correct.** The
brief's premise — "shared volume is created but `.credentials.json`
is never copied into it" — was true on the VPS only because the
architect's chown bug prevented `.credentials.json` from ever
landing in `claude-state-architect`, so the verify.sh sync step had
nothing to copy and (correctly) hit the rc=99 branch. The brief
collapsed two bugs into one symptom.

What is missing:

- `setup-common.sh` does not call `verify.sh` after instructing the
  user to run `claude auth login` in Path B. (It does run verify.sh
  as a final sanity check at step 9, but that runs *before* the
  user has had a chance to log in.) Path B's documented sequence
  in the trailing banner (lines 226-237) tells the user to attach,
  log in, and that's it — no mention of re-running `verify.sh`
  afterward to refresh the shared volume.
- The brief's recommendation 4 says "verify.sh --refresh-credentials"
  should be triggered after first login. Implementation-wise, a
  flag is unnecessary — `verify.sh` already always refreshes — but
  the **documentation of the trigger** is missing.

The cleanest hook is to update the setup-common.sh trailing banner
(and README Path B section) to make "run `./verify.sh`" an explicit
post-login step, not an optional one.

## 5. Ephemeral compose mounts — wired correctly, but RW not RO

`docker-compose.yml` mounts `claude-state-shared` at `/home/agent/.claude`
in all three ephemerals:

| service        | line | mount                                                |
|----------------|------|------------------------------------------------------|
| `planner`      | 73   | `claude-state-shared:/home/agent/.claude`            |
| `coder-daemon` | 94   | `claude-state-shared:/home/agent/.claude`            |
| `auditor`      | 110  | `claude-state-shared:/home/agent/.claude`            |

So Q5's wiring concern is resolved: yes, all three mount the shared
volume at the right path. The brief speculated mounts might be
missing — they aren't.

However: the brief's parenthetical noted "intended path is
`/home/agent/.claude` mounted **read-only**" — the actual mounts are
**read-write**. This is a deliberate divergence per
`deployment-docker.md` §9 line 574: "the volume is mounted writable
so claude-code can update it on token rotation if absolutely
necessary." So the mode is intentional, but the brief's
recommendation that ephemerals "inherit those credentials and start
in a logged-in state" without writing assumes RO semantics.

If the fix preserves RW (recommended, matches the doc), then the
chown fix must apply to the shared volume's mount root for the same
reason it applies to the architect's — to allow claude-code's
in-container token-refresh write path to succeed. If RO is chosen,
the chown bug becomes moot for ephemerals but the doc and the
in-container claude-code behavior need re-checking.

## 6. `deployment-docker.md` §9 vs. implementation — divergences

§9 (lines 564-580) is the canonical description of the dual-volume
pattern. Compared to actual implementation:

| Doc claim                                                       | Implementation match?     |
|-----------------------------------------------------------------|---------------------------|
| Two volumes, fixed names, `external: true`                      | Yes — compose lines 137-142|
| `claude-state-architect` mounted RW at architect's `~/.claude`  | Yes — compose line 47     |
| `claude-state-shared` mounted at every ephemeral's `~/.claude`  | Yes — see §5 above        |
| Shared holds *only* `.credentials.json`, never history/state    | True today; not enforced  |
| Refresh helper is canonical writer of shared volume             | True — verify.sh + setup  |
| `verify.sh` is the operator's "re-sync" gesture                 | True — runs every invoke  |
| Refresh is idempotent + safe to run on every commission         | True                      |

The divergences are not in §9 itself — §9 accurately describes the
*design*. The divergences are between the design and what the
substrate actually delivers on Path B:

- §9 is silent on the chown-on-fresh-volume failure mode. The
  design assumes the mount root is writable by `agent`; the
  implementation accidentally makes it root-owned on Path B.
- §9 line 574 says ephemerals "should never write through" the
  shared volume except for token rotation. The substrate enforces
  this only by convention, not by mount mode.
- README Path B walkthrough (per the brief) does not surface the
  `./verify.sh` re-run step required to populate the shared volume
  after the architect's first login.

---

## Summary of findings

The brief's two-bug framing is essentially correct, with one
clarification:

1. **Chown bug — confirmed and root-caused.** The agent-base
   Dockerfile does not pre-create `/home/agent/.claude`, so Docker
   creates the mount root as `root:root 0755` on first attach. All
   four entrypoints run as `agent` per their Dockerfile USER
   directives, so the entrypoint itself cannot chown — the fix must
   land either earlier (Dockerfile pre-create) or by changing the
   privilege model (USER root + drop via gosu).

2. **Credential-sharing gap — partially mis-diagnosed.** The
   substrate *does* have a credential-sharing mechanism: the helper
   container in `verify.sh` lines 78-102 (and in `setup-common.sh`
   lines 185-195) copies `.credentials.json` from architect volume
   to shared volume, idempotently, with correct ownership. The
   brief's observation of an empty shared volume on the VPS was a
   *downstream* symptom of bug 1 — the architect never wrote
   credentials into its own volume, so there was nothing for the
   refresh step to copy. Bug 2 collapses into bug 1 plus a
   documentation gap (Path B walkthrough doesn't tell the user to
   re-run `verify.sh` after logging in).

## Minimum set of changes that makes Path B work as documented

Driven by the findings above, the fix scope can be tighter than the
brief anticipated:

1. **Pre-create `/home/agent/.claude` in `infra/base/Dockerfile`**
   as `agent:agent` mode `0700`. This single line eliminates the
   chown bug for all four images at once, because Docker copies
   image-layer ownership into a freshly-created named volume's
   mount root. No entrypoint changes needed; no USER-root /
   privilege-drop dance.

   Alternative if (1) doesn't suffice — e.g. if Docker's
   volume-init behavior on some platforms differs from the Linux
   case — fall back to the brief's original "run entrypoint as root,
   chown, drop privileges" pattern. This requires reverting `USER
   agent` in the Dockerfiles and adding `gosu` (or equivalent) to
   the base image. Higher blast radius, but unambiguous. Worth
   testing (1) first.

2. **No new code in `verify.sh`.** The `--refresh-credentials`
   flag the brief proposed is unnecessary; `verify.sh` already
   always refreshes. Skip the flag work.

3. **Documentation fixes:**
   - Update `setup-common.sh`'s trailing banner (lines 216-240) to
     make `./verify.sh` an explicit Path B post-login step.
   - Update README's Path B walkthrough to the same effect.
   - Update `deployment-docker.md` §9 to note the chown
     pre-creation requirement (so future image refactors don't
     accidentally drop the `mkdir -p /home/agent/.claude` from the
     base image).

4. **Optional — RW vs RO mount for ephemerals.** Per §9 the RW mode
   is intentional (token rotation). Leave as-is; the chown fix
   from (1) makes it work either way.

## Residual observation worth flagging

The brief's recommendation 5 (OAuth refresh-token rotation) is
already covered by `verify.sh`'s idempotent refresh. There is no
hidden bug in the rotation path — the rotation mechanism is "operator
re-runs verify.sh" and that works today. The only *latent* concern
is what happens if an ephemeral container is mid-run when the
architect's token rotates and the planner's claude-code attempts to
write a refreshed token back to its read-write shared-volume mount.
With the current root-owned mount root, that write would fail. The
chown fix from (1) closes this case as a side effect.

## Open questions for architect review before 6.b dispatch

1. **Confirm fix approach (1) vs (1') — Dockerfile pre-create vs.
   USER root + gosu.** The pre-create is materially smaller and
   carries no privilege-model change. Does that match your
   intent, or do you want the entrypoint-driven fix per the brief
   for symmetry / future-proofing?

2. **`verify.sh --refresh-credentials` flag — drop entirely?** The
   brief's recommendation 4 is a no-op as written. Confirm it can
   be dropped from 6.b's deliverable list.

3. **Ephemeral mount mode — keep RW (matches §9) or switch to RO?**
   The brief implicitly assumed RO; the doc explicitly chose RW
   for token rotation. Keeping RW is the smaller diff.

4. **Scope of doc updates.** Three doc surfaces (setup-common.sh
   banner, README Path B, deployment-docker.md §9). Confirm all
   three should be updated in 6.b, or any deferred.

If the answers are "(1), drop the flag, keep RW, update all three
docs," then 6.b shrinks to roughly: one line in `infra/base/Dockerfile`,
one banner edit in `setup-common.sh`, one README section, one
§9 sentence. Plus a manual end-to-end Path B test transcript.
