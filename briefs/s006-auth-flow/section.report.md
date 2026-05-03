# s006-auth-flow — section report

## Brief echo

Follow-up to s005, surfaced during the first end-to-end run on a
fresh VPS substrate. Path B authentication did not work end-to-end
on a fresh install. Two related symptoms were observed:

1. The architect's `/home/agent/.claude/` mount root was root-owned
   on first start, so when `claude /login` ran as agent, the
   credential write silently failed. OAuth completed server-side
   but no `.credentials.json` landed on disk.
2. `claude-state-shared` was created at setup time but never received
   `.credentials.json`, so ephemeral planners / coders / auditors
   could not inherit auth.

The brief baked in five recommendations and asked the architect to
override before dispatch. The architect (a) accepted recommendations
1, 2, 3 and 5 as written and (b) deferred recommendation 4 pending
investigation findings. The investigation (task 6.a) revealed that
the credential-sharing mechanism described by recommendation 4
*already exists* in `verify.sh` and is correct, idempotent, and runs
on every invocation — symptom 2 was a downstream consequence of
symptom 1 (no creds in architect volume → nothing for the refresh to
copy). With that clarification, the fix scope shrank materially.

The four open questions raised in `investigation.md` were resolved as:

1. Dockerfile pre-create (smaller diff, no privilege-model change).
2. Drop the `--refresh-credentials` flag (verify.sh already always
   refreshes).
3. Keep RW ephemeral mount (matches `deployment-docker.md` §9, supports
   in-container token refresh).
4. Update all three doc surfaces.

## Summary of investigation findings

Full report at `briefs/s006-auth-flow/investigation.md`. Headlines:

- **Bug 1 root cause.** `infra/base/Dockerfile` did not pre-create
  `/home/agent/.claude`. Docker initialises an empty named volume's
  mount root by copying the image-layer's ownership at the same
  path; with no path to copy from, Docker creates the mount root as
  `root:root 0755`. All four agent images set `USER agent` before
  the entrypoint runs, so the entrypoint cannot chown after the
  fact — the fix had to land in the base image, not in the entrypoint
  per the brief's recommendation 2.

- **Bug 2 collapse.** The credential-sharing helper was already
  present at `verify.sh:78-102` and `setup-common.sh:185-195`, ran
  every invocation, was idempotent, and explicitly handled the
  "creds not yet present" case (rc=99). The empty shared volume on
  the VPS was caused by bug 1 (architect's volume was empty too) plus
  a documentation gap: the Path B walkthrough did not tell the user
  to re-run `verify.sh` after first login.

- **Compose mounts already correct.** All three ephemerals
  (`planner`, `coder-daemon`, `auditor`) mount `claude-state-shared`
  at `/home/agent/.claude` (RW, intentionally). No compose changes
  needed.

## Summary of the fix

Four narrow changes:

1. **`infra/base/Dockerfile`** — pre-create `/home/agent/.claude` as
   `agent:agent 0700` in the same `RUN` that creates the agent user.
   One-line fix that covers all four agent images at once via image
   inheritance.

2. **`setup-common.sh`** — replace the trailing-banner "First steps"
   block with a Path A / Path B split that makes `./verify.sh` an
   explicit Path B post-login step.

3. **`README.md`** — Path B walkthrough now includes the `./verify.sh`
   step with an explanation of why it is required (propagates
   credentials into the shared volume; skipping it leaves
   ephemerals un-authed).

4. **`methodology/deployment-docker.md` §9** — added an implementation
   note on the `claude-state-architect` bullet documenting the
   pre-create requirement and the failure mode it prevents, so a
   future image refactor doesn't accidentally drop the `mkdir`.

No entrypoint changes. No compose changes. No verify.sh changes.

## Files modified

```
infra/base/Dockerfile                      # +6 / -2  (pre-create + comment)
setup-common.sh                            # +9 / -2  (Path A/B banner split)
README.md                                  # +9 / -2  (Path B walkthrough)
methodology/deployment-docker.md           # +1 / -1  (§9 implementation note)
briefs/s006-auth-flow/investigation.md     # +313 (6.a deliverable)
briefs/s006-auth-flow/section.report.md    # this file
```

The "modified entrypoints" line item from the DoD is empty by design:
the investigation showed the chown had to land in the base image
because the entrypoints run as `agent` (no privilege to chown). No
entrypoints were modified.

## Verification on this host

End-to-end Path B verification on a *fresh* substrate could not be
run on this developer host without destroying the operator's
in-flight architect session (the architect volume holds the live
session). What was verified locally:

1. **Patched base image builds cleanly.**
   ```
   $ docker build -t agent-base:s006-test infra/base
   #7 [4/6] RUN useradd -m -s /bin/bash -u 1000 agent
       && mkdir -p /work /home/agent/.claude
       && chown agent:agent /work /home/agent/.claude
       && chmod 0700 /home/agent/.claude
   #7 DONE 0.7s
   ...
   naming to docker.io/library/agent-base:s006-test done
   ```

2. **Fresh empty named volume mounted at `/home/agent/.claude`
   inherits agent ownership.**
   ```
   $ docker volume create s006-scratch
   $ docker run --rm -u agent -v s006-scratch:/home/agent/.claude \
         agent-base:s006-test bash -c '
             stat -c "%U:%G %a %n" /home/agent/.claude
             echo test > /home/agent/.claude/.credentials.json
             stat -c "%U:%G %a %n" /home/agent/.claude/.credentials.json
         '
   agent:agent 700 /home/agent/.claude
   agent:agent 644 /home/agent/.claude/.credentials.json
   ```
   Mount root is `agent:agent 0700`, agent can write. This is the
   bug fix demonstrating itself.

3. **Role images chain on top of the patched base image without
   regression.**
   ```
   $ docker compose --profile ephemeral build
   ...
    Image agent-coder-daemon:latest Built
    Image agent-git-server:latest Built
    Image agent-planner:latest Built
    Image agent-architect:latest Built
    Image agent-auditor:latest Built
   ```
   Verified the planner image specifically inherits the fixed mount
   root via the same scratch-volume probe:
   ```
   $ docker run --rm -u agent -v s006-planner-scratch:/home/agent/.claude \
         --entrypoint bash agent-planner:latest \
         -c 'stat -c "%U:%G %a %n" /home/agent/.claude && \
             touch /home/agent/.claude/.credentials.json && \
             echo "planner write: OK"'
   agent:agent 700 /home/agent/.claude
   planner write: OK
   ```

## Verification gate before merge to main

The full Path B end-to-end transcript (setup → attach → login →
verify.sh → commission-pair planner that starts logged-in) **must be
captured on a fresh substrate** before this section merges to main.
Suggested gate: run on the VPS where the bug was originally
observed:

```
# fresh substrate, no prior claude-state volumes
./setup-linux.sh                     # Path B path: no host creds
./attach-architect.sh
> claude auth login                  # OAuth flow; should now write creds
> [Ctrl-P Ctrl-Q to detach]
./verify.sh                          # should report 10 ok / 0 fail,
                                     # including "architect creds present
                                     # and synced into shared volume"
                                     # (pre-login state would be 9 ok with
                                     # the creds-sync step in the rc=99
                                     # "[..] not yet present" branch)
./commission-pair.sh s001-cli        # planner should start logged-in
                                     # — no "claude auth login" needed
                                     # inside the planner container
```

Acceptance criteria for the gate:

- `setup-linux.sh` completes without `claude-state` volumes ever
  showing root-owned mount roots (probe: `docker run --rm -v
  claude-state-architect:/x -v claude-state-shared:/y
  debian:bookworm-slim stat -c '%U:%G %a' /x /y` → both
  `agent:agent 700`).
- `claude auth login` inside the architect succeeds and the next
  prompt does NOT print "Not logged in."
- `verify.sh` after login reports 10 ok / 0 fail with `architect
  creds present and synced into shared volume` (no rc=99).
- A commissioned planner runs `claude auth status` and reports
  `loggedIn: true`.
- No manual `docker exec -u root … chown` is required at any step.

If any of those fail, the section needs to remain on its branch and
this report should be updated with the failure context before
re-attempting.

## Residual hazards

- **Existing volumes are not retro-fixed.** Operators with an
  *existing* root-owned `claude-state-architect` mount root (i.e.,
  anyone who hit the original bug) will not see the fix simply by
  pulling the new images. The mount-root ownership is set at
  volume-create time and persists. They have two recovery options:
  (a) `docker exec -u root agent-architect chown -R agent:agent
  /home/agent/.claude` — same workaround the brief documented;
  (b) destroy and recreate the volume (`docker compose down`, `docker
  volume rm claude-state-architect`, re-run setup). The fix prevents
  the bug from recurring on *fresh* volumes; it does not retro-fix
  existing ones. Neither this report nor a setup-script migration
  attempts to detect and fix this case automatically — the operator
  cohort that hit the original bug is small (Path B users on a fresh
  substrate), and the recovery is a single shell command. Worth
  mentioning in README troubleshooting if the user wants belt-and-
  braces; not required.

- **Ephemeral RW write-through behavior under token rotation is
  still untested.** §9 says ephemerals may write `.credentials.json`
  on token rotation. With the chown fix, the mount root permits the
  write — but no test exercises it (it requires waiting hours or
  forging an expired token). Latent risk: low, because the next
  `verify.sh` invocation re-syncs from the architect anyway.

- **macOS keychain interaction with Path B.** The s000 report flagged
  that macOS `claude-code` may store credentials in the system
  keychain rather than `~/.claude/.credentials.json`. If the
  in-container Path B login also writes to the keychain (vs. to
  the volume), this fix is a no-op on macOS. Not verified — would
  need a macOS test host. Outside the brief's scope but worth
  noting.

## Open follow-up — not in s006 scope

None requested. Verifying the Path B end-to-end transcript on the
VPS is the gating step before this section merges to main; that is
operator action, not an additional task to schedule.
