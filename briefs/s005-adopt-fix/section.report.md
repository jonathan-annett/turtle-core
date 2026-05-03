# s005-adopt-fix — section report

## Brief echo

Follow-up to s004 (substrate identity sentinel). The
`substrate_id_adopt` flow shipped in s004 had a bug surfaced during
operator-side adoption on hello-turtle: the architect container was
stopped before `docker volume rm claude-state-architect`, but
stopped-but-not-removed containers still hold volume references, so
the volume rm failed. The script bailed cleanly (diagnostic preserved,
original volume untouched, scratch volume held the data), and manual
recovery (`docker compose rm -f architect`, then rerun) completed the
rotation. This section codifies that recovery into the script and
adds a regression scenario.

The brief baked in three recommendations (use `docker compose rm -f`
after the existing stop rather than restructuring; extend the existing
test harness rather than adding a new file; let s005's report stand
alone without retroactively editing s004's). All three were accepted;
no overrides requested.

## Summary of the fix

A single two-line insertion in `substrate_id_adopt`, immediately after
the existing `docker compose stop architect`:

```bash
docker compose rm -f architect >/dev/null 2>&1 || \
    _log "WARN: 'docker compose rm -f architect' returned non-zero — proceeding anyway."
```

`-f` skips the confirmation prompt; `-s` (stop first) is unnecessary
because the preceding `stop` already halted the container. The command
is idempotent — if the container is already absent (re-running adoption
after a partial completion), `rm -f` succeeds without effect. The
WARN-and-proceed posture matches the existing handling of
`docker compose stop architect`: the subsequent volume rm carries its
own diagnostic that names the still-using-it case, so a defensive log
preserves the existing failure-mode story rather than introducing a
hard fail at this step.

The data-preservation logic (scratch-volume copy, recreate-with-label,
restore) is unchanged. The rest of `substrate_id_adopt` — pre-flight
checks, scratch-volume rotation, sentinel write — is untouched.

## Modified site(s)

`substrate_id_adopt` is defined once, in `infra/scripts/substrate-identity.sh`
(lines 242–401 pre-fix). The fix is the only modification; no other
call sites or duplicate implementations exist. `setup-common.sh:58`
calls it; `setup-linux.sh` and `setup-mac.sh` reach it through
`setup-common.sh` via `TURTLE_CORE_DO_ADOPT=1`. No changes were needed
in those entry points.

## Test output — new regression scenario (Scenario 8)

Created in `infra/scripts/tests/test-substrate-identity.sh`. The
scenario stands up a real standalone container holding the test volume,
stops it (without removing it — mimicking what `compose stop architect`
leaves behind), then runs `substrate_id_adopt` and asserts:

- `Adoption complete.` log line present
- `EXIT=0` from the function
- `.substrate-id` written and non-empty
- volume re-labelled with the new UUID
- volume contents (root + nested) preserved
- the held container has been removed

To make this work the harness's docker stub was extended to also
intercept `compose rm` (mirroring the existing `compose stop` stub).
When `TEST_ARCH_CONTAINER` is set, both intercepts redirect to the
real standalone container so the stop+rm sequence is actually
exercised; when unset they no-op. Existing scenarios (no
`TEST_ARCH_CONTAINER`) are unaffected by the new branch.

Output (with the fix):

```
Scenario 8: adoption with stopped-but-present architect container
[substrate-identity] Adopting existing substrate. New identity: 343ad3fa-deb2-40d7-86c7-dcbb908d69ee
[substrate-identity] Volume rotation in progress — this stops the architect container,
[substrate-identity] preserves turtle-core-test-vol-1823 contents, recreates it with the label,
[substrate-identity] restores contents, and lets the rest of setup restart the architect.
[substrate-identity] Stopping architect container (graceful, ~10s timeout)...
[substrate-identity] Creating scratch volume turtle-core-test-vol-1823-rotate-1823...
[substrate-identity] Copying turtle-core-test-vol-1823 → turtle-core-test-vol-1823-rotate-1823...
[substrate-identity] Removing turtle-core-test-vol-1823 (contents preserved in turtle-core-test-vol-1823-rotate-1823)...
[substrate-identity] Recreating turtle-core-test-vol-1823 with app.turtle-core.substrate-id=343ad3fa-deb2-40d7-86c7-dcbb908d69ee...
[substrate-identity] Restoring contents from turtle-core-test-vol-1823-rotate-1823 → turtle-core-test-vol-1823...
[substrate-identity] Removing scratch volume...
[substrate-identity] Adoption complete. Substrate identity: 343ad3fa-deb2-40d7-86c7-dcbb908d69ee
EXIT=0 FRESH=0 ID=343ad3fa-deb2-40d7-86c7-dcbb908d69ee
PASS: adoption (stopped container holding volume): completed, container removed, contents preserved
```

### Verifying the test reproduces the original bug

To confirm the new scenario actually exercises the fixed bug (rather
than passing trivially), the fix was temporarily reverted (`git stash`
on `infra/scripts/substrate-identity.sh`) and the harness re-run.
Scenarios 1–7 still passed; Scenario 8 failed at exactly the operator-
observed failure point, with the original FATAL diagnostic:

```
[substrate-identity] Removing turtle-core-test-vol-30536 (contents preserved in turtle-core-test-vol-30536-rotate-30536)...
[substrate-identity] FATAL: could not remove turtle-core-test-vol-30536 — is a container still using it?
                  Run 'docker ps -a --filter volume=turtle-core-test-vol-30536' to find it. Original volume is intact.
FAIL: adoption (stopped container holding volume): expected completion despite volume reference
```

`Summary: 8 passed, 1 failed`. The fix was then restored (`git stash
pop`) and the harness re-run to confirm 9/9. This demonstrates that
Scenario 8 binds to the specific bug (it depends on the rm step
actually removing the container so the subsequent `docker volume rm`
can succeed) and not to a coincidental property.

## Test output — full run

After the fix, the entire harness:

```
Scenario 1: fresh install                              PASS
Scenario 2: matching id                                PASS
Scenario 3: mismatched ids                             PASS
Scenario 4: disk only                                  PASS
Scenario 5a: volume only, labelled                     PASS
Scenario 5b: volume only, unlabelled                   PASS
Scenario 6: adoption                                   PASS
Scenario 7: adoption refuses pre-existing sentinel     PASS
Scenario 8: adoption with stopped-but-present
            architect container                        PASS
Summary: 9 passed, 0 failed
```

All seven pre-existing scenarios continue to pass — the docker-stub
extension was additive and the WARN-and-proceed posture for the new
`compose rm` call matches the surrounding script's existing tolerance
for `compose stop` returning non-zero.

## Residual hazards

None observed in the fix path itself. Some context-of-the-fix notes:

1. **Test-only**: the harness does not (and cannot easily) verify
   the post-adoption restart of the architect — that is the
   responsibility of the rest of `setup-common.sh` (`compose up -d`)
   and is exercised by real setup runs. The brief's suggestion of
   asserting "container is running again" was reinterpreted as
   "container holding the volume has been removed" because that is
   what `substrate_id_adopt` itself does; restart is downstream.

2. **No interaction with `setup-common.sh`'s adoption-then-gate
   flow**: after `substrate_id_adopt` returns, `setup-common.sh`
   continues to `substrate_id_gate` (now seeing matching state),
   then `compose up -d git-server architect`. The adoption sites in
   `setup-common.sh` were left untouched and inspected for any
   assumption that could be broken by the `rm` of the architect
   container. None found — the subsequent `compose up -d` recreates
   the container from the compose file regardless.

3. **No README / troubleshooting changes**: brief's out-of-scope list
   was honoured. Existing entries cover adoption pathologies
   generically.

4. **No `docker compose rm` semantics ambiguity in the field**: the
   command targets the architect service definition in `compose.yml`,
   so it removes the architect container even if it was created with
   a non-default project name. No edge case observed.

## Out-of-scope items noted

None — no incidental bugs were spotted in `substrate_id_adopt` or its
surroundings during the fix.
