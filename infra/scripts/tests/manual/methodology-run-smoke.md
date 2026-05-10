# Manual procedure — methodology-run smoke test

This walks the full architect → planner → coder → auditor pipeline
end-to-end on a fresh substrate clone with the s011 planner/auditor
tool-surface plumbing in place. **The grep at the end is the
assertion.**

This is the integration test that validates s011's fix for the
regression first observed during the aborted Option B run on
hello-turtle: the planner running non-interactively in claude could
not perform any methodology-required git operation, because its
`--allowed-tools` flag was empty. After s011 the section brief's
"Required tool surface" field is parsed by the planner entrypoint
and translated into `--allowed-tools`, mirroring how the coder
already worked since s001.

The smoke test in `infra/scripts/tests/test-substrate-end-to-end.sh`
proves the substrate plumbing comes up, but does not run a real
methodology pipeline. This file fills that gap and is **mandatory
to run after any section that touches commissioning, tool-surface,
role entrypoints, or the methodology spec** (s011 establishes that
discipline).

## Preconditions

1. **Linux host with Docker and the prerequisites of `./setup-linux.sh`**.
2. **The host's existing turtle-core substrate must be torn down** for
   the duration of the smoke. The smoke uses the same global Docker
   volume names (`claude-state-architect`, `claude-state-shared`) and
   the substrate-identity gate (§3.5 of `deployment-docker.md`) will
   fail loudly otherwise. Restore afterward.

   ```
   # backup the existing substrate's identity for restore
   docker volume inspect claude-state-architect \
       --format '{{json .Labels}}' > /tmp/restore-substrate-id.json
   cp ~/turtle-core/.substrate-id /tmp/restore-substrate-id 2>/dev/null || true

   # tear down the current substrate (keeps named volumes intact)
   cd ~/turtle-core
   docker compose down
   ```

3. **Claude-code authenticated on the host** so the new scratch
   substrate can use Path A credential propagation. The fresh-substrate
   architect inherits `~/.claude/.credentials.json`.

## Step 1 — fresh substrate clone

Pick a scratch path outside any existing turtle-core working tree:

```
SCRATCH=/tmp/turtle-core-s011-smoke
rm -rf "${SCRATCH}"
git clone ~/turtle-core "${SCRATCH}"
cd "${SCRATCH}"
git checkout section/s011-planner-auditor-tool-surface
```

(Or clone from origin once the section branch is pushed — `git clone
git@<remote>:turtle-core.git` then checkout the branch.)

## Step 2 — bring up the scratch substrate

Important: the substrate-identity gate will see no `.substrate-id`
in the scratch tree AND no existing `claude-state-architect` volume
(because step 0 tore the production substrate's services down — the
volume is still present but the labels still match the production
tree, which is now absent). If the gate refuses to proceed (Case 2:
"docker volume exists but this tree has no .substrate-id"), the
cleanest path is to **temporarily rename** the production volume,
run the smoke, then restore.

```
# move the production architect volume out of the way for the smoke
docker volume create claude-state-architect-prod-saved
docker run --rm \
    -v claude-state-architect:/src:ro \
    -v claude-state-architect-prod-saved:/dst \
    debian:bookworm-slim \
    sh -c 'cp -a /src/. /dst/'
docker volume rm claude-state-architect

# same for claude-state-shared (no substrate-id label; just snapshot)
docker volume create claude-state-shared-prod-saved
docker run --rm \
    -v claude-state-shared:/src:ro \
    -v claude-state-shared-prod-saved:/dst \
    debian:bookworm-slim \
    sh -c 'cp -a /src/. /dst/'
docker volume rm claude-state-shared
```

Now run setup on the scratch tree:

```
cd "${SCRATCH}"
./setup-linux.sh
```

**Expected:** clean setup, no `--platform=` or `--remote-host=` flags
(default platform, no remote hosts — minimum surface for the smoke).
The substrate-identity gate generates a fresh UUID, writes
`.substrate-id`, brings up `agent-architect` and `agent-git-server`.

If `./setup-linux.sh` fails on any verify-runner step, **this is the
F42/F43/F44 fix from 11.g being exercised** — re-read the failure
text and confirm whether you've correctly cherry-picked those fixes.

When setup completes, `./verify.sh` should print `10/10`.

## Step 3 — drive the architect

Attach interactively:

```
./attach-architect.sh
```

Inside the architect, run `claude` and supply this prompt verbatim:

> Draft a minimal hello-world smoke for the s011 methodology-run
> validation. Author three files and commit them to `main`:
>
> 1. `/work/TOP-LEVEL-PLAN.md` listing one section `s001-hello`
>    with success criterion "running `python3 hello.py` prints
>    `hello, world.` to stdout".
>
> 2. `/work/SHARED-STATE.md` initialised with the substrate
>    invariants from `/substrate/platforms.txt` (and
>    `remote-hosts.txt` if non-empty) per your guide §10. If
>    those files are empty, write that the substrate is on
>    `default` platform with no remote hosts.
>
> 3. `/work/briefs/s001-hello/section.brief.md` with the
>    standard section-brief shape per spec §7.2, scoped tight:
>    objective is "create `hello.py` that prints `hello,
>    world.` and verify with `python3 hello.py | grep -q
>    '^hello, world\\.$'`"; touch surface is `hello.py`; out
>    of scope is everything else. **Include a "Required tool
>    surface" field per the v2.2 spec — the planner needs
>    Read/Edit/Write plus Bash patterns for `git checkout`,
>    `git branch`, `git commit`, `git push`, `git merge`,
>    `curl` (for daemon commissioning), and `cat`/`ls` for
>    inspection.**
>
> Commit each file in its own commit on `main`. Push when done
> and discharge.

The architect should produce three commits and push. Verify:

```
git -C /work log --oneline -5
git -C /work show --stat main:briefs/s001-hello/section.brief.md
```

Then detach (Ctrl-P Ctrl-Q).

## Step 4 — commission the planner

Back on the host:

```
cd "${SCRATCH}"
./commission-pair.sh s001-hello
```

**Expected output (paraphrased):**

```
Starting coder-daemon for s001-hello (project=turtle-core-s011-smoke-s001-hello)...
Commissioning planner against briefs/s001-hello/section.brief.md
Starting planner (foreground)...
================================================================================
  Planner container (ephemeral)
================================================================================
...
Bootstrap prompt detected; invoking claude non-interactively.
When claude discharges, you'll be dropped into a shell.

Parsing tool surface from /work/briefs/s001-hello/section.brief.md...
Allowed tools: Read,Edit,Write,Bash(git checkout:*),Bash(git branch:*),Bash(git commit:*),Bash(git push:*),Bash(git merge:*),Bash(curl:*),Bash(cat:*),Bash(ls:*)

# (claude session prints its progress — it should now be able to
#  run git checkout, branch, commit, push, etc. without "permission
#  denied" errors. It commissions a coder via curl to coder-daemon,
#  waits for completion, merges the task into the section branch,
#  writes a section report, discharges.)

Claude discharged. Dropping to interactive shell.
agent@<container>:/work$
```

**The key line** is `Allowed tools: ...` — that's s011 working. If
it's missing, or if the planner aborts with "FATAL: planner cannot
start — section brief is missing a usable 'Required tool surface'
field", the fix is broken and the section is not done.

Verify after the planner exits:

```
docker exec agent-architect git -C /work fetch
docker exec agent-architect git -C /work log section/s001-hello --oneline
docker exec agent-architect git -C /work cat-file -p section/s001-hello:hello.py
docker exec agent-architect git -C /work cat-file -p section/s001-hello:briefs/s001-hello/section.report.md \
    | head -40
```

Exit the planner shell.

## Step 5 — author the audit brief

Re-attach to the architect and prompt:

> Author `/work/briefs/s001-hello/audit.brief.md` per spec §7.6.
> Include a "Required tool surface" tight to read-only inspection:
> Read, Edit, Write (for the audit report), Bash patterns for `git
> log`, `git diff`, `git show`, `python3`, `cat`. Sign-off criteria:
> `python3 hello.py` prints exactly `hello, world.`. Commit to
> main, push, discharge.

Detach.

## Step 6 — commission the auditor

```
cd "${SCRATCH}"
./audit.sh s001-hello
```

**Expected:** auditor entrypoint parses the audit brief's tool
surface, claude runs adversarial probes, writes the audit report
to the auditor repo at the agreed path, discharges. Look for the
same `Allowed tools: ...` line in the auditor output.

Verify the audit report landed in the auditor repo:

```
docker exec agent-architect git -C /auditor fetch
docker exec agent-architect git -C /auditor pull
docker exec agent-architect cat /auditor/reports/s001-hello.audit.report.md \
    | tail -20
```

The sign-off line should read `I sign off on section s001 as fit for
purpose.` or equivalent. If the auditor's verification command (the
`python3 hello.py` run) was denied because `Bash(python3:*)` wasn't
in the surface, that's a tool-surface gap in the audit brief, not a
substrate fault — re-author the audit brief and re-run.

## Step 7 — capture the transcript

Save the operator-side terminal output of:
- The architect drafting session (step 3 + step 5).
- The planner run (step 4 — full stdout/stderr from `commission-pair.sh`).
- The audit run (step 6 — full stdout/stderr from `audit.sh`).
- The verification commands in steps 4 and 6.

Append the captured transcript to this file under a dated heading
(see "## Transcript: <YYYY-MM-DD>" below). Commit to the section
branch as part of the section report's evidence.

## Step 8 — teardown and restore

```
cd "${SCRATCH}"
docker compose down -v --remove-orphans
rm -rf "${SCRATCH}"

# restore the production substrate's volumes
docker volume create --label app.turtle-core.substrate-id=<original-uuid> claude-state-architect
docker run --rm \
    -v claude-state-architect-prod-saved:/src:ro \
    -v claude-state-architect:/dst \
    debian:bookworm-slim \
    sh -c 'cp -a /src/. /dst/'
docker volume rm claude-state-architect-prod-saved

docker volume create claude-state-shared
docker run --rm \
    -v claude-state-shared-prod-saved:/src:ro \
    -v claude-state-shared:/dst \
    debian:bookworm-slim \
    sh -c 'cp -a /src/. /dst/'
docker volume rm claude-state-shared-prod-saved
```

Bring the production substrate back up:

```
cd ~/turtle-core
docker compose up -d git-server architect
./verify.sh
```

Expected: 10/10 verify on the production tree, no identity-gate
complaints.

## Convention established by s011

This file's existence is a discipline marker. **Any future section
that touches the commission pathway (commission-pair.sh / audit.sh
/ entrypoints / coder-daemon / methodology spec §7 or §9) must
include a methodology-run smoke pass in its Definition of Done.**

The s008 → s009 → s010 sequence shipped a real regression that
went undetected for three sections because no section exercised
the actual pipeline end-to-end. This file is the pipeline-validity
backstop. The procedure is manual today; automation is a viable
follow-up section, but a manual procedure that someone actually
runs beats an automated one that nobody trusts.

---

## Pre-validation captured during s011 implementation (2026-05-11)

The full end-to-end run is a manual procedure (it requires interactive
architect drafting and an authenticated claude-code session). During
s011 implementation the following pieces were validated on the host
without requiring a fresh substrate stand-up:

- **Parser unit tests pass.** 15 cases under
  `infra/scripts/tests/test-parse-tool-surface.sh` (mirroring the JS
  parser's 11 cases plus four extra edge cases). All pass.
- **Parser works inside a built planner image.** Built
  `agent-planner:s011-test` from the s011 Dockerfile, ran the parser
  with the s011 brief at `briefs/s011-planner-auditor-tool-surface/
  section.brief.md` (which contains a usable tool surface — see
  below) — output: a comma-separated tools list.
- **Parser fails clean on a brief lacking the field.** Running the
  parser against a minimal brief with no "Required tool surface"
  marker exits non-zero with the actionable spec-pointing error
  message.
- **All shell changes pass `bash -n` syntax check** (parser,
  planner/auditor entrypoints, commission-pair.sh, audit.sh).
- **F42/F43/F44 are local file changes** (one line each in
  setup-common.sh and platformio-esp32.yaml); rationale and cross-
  references inline at the call sites.

The full operator-side transcript should be appended below the next
time a human executes this procedure end-to-end on a fresh substrate.

## Transcript: <YYYY-MM-DD>

(Placeholder — append captured terminal output here when the
procedure is next run.)
