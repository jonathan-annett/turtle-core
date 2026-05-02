# s001-tool-surface — section report

## Brief echo

Codify per-role Claude Code invocation flags in the methodology, add a
"Required tool surface" field to the task brief template, and make the
coder-daemon translate that field into `--allowed-tools` when spawning
coder subshells. Coder is non-interactive (`-p` + `--permission-mode
dontAsk`); planner stays interactive (judgement role); auditor uses
stream-json passthrough for the check-in rule.

## Repo-state findings (before doing the work)

The brief warned that items 1.a–1.c may already be applied. Audit of
the section branch base (`main` @ b5586e1):

| Item | Pre-existing? | Notes |
|---|---|---|
| 1.a — spec §7.3 "Required tool surface" field | **yes** | `methodology/agent-orchestration-spec.md:269`. Field is between "Touch surface" and "Constraints" with the exact wording the brief specified. |
| 1.b — planner-guide.md "Writing a task brief" | **yes** | `methodology/planner-guide.md:84`. Includes the warning sentence about the daemon denying out-of-list actions. |
| 1.c — deployment-docker.md §4.5 + §4.3 cross-reference | **no** | Blocker: `deployment-docker.md` did not exist in the repo at all. Many substrate files (`daemon.js`, `commission-pair.sh`, `verify.sh`, `setup-common.sh`, `docker-compose.yml`, `.env.example`) cited §-numbers from this doc, but the file itself was never committed. |

Resolved with the human in the loop: the human pasted the canonical
deployment-docker.md content. I committed it as a baseline (commit
89645f7), then applied the §4.5 + §4.3 edits on top (commit 07e7a91).
Without that step 1.c could not have been performed as the brief
specified.

## Per-task summary

### Task 1.a — spec §7.3 field

**Status:** already in repo at section base. No change needed.

### Task 1.b — planner-guide.md addition

**Status:** already in repo at section base. No change needed.

### Task 1.c — deployment-docker.md §4.5 + §4.3 cross-reference

**Status:** applied fresh.

- Added new `### 4.5 Per-role invocation flags` between §4.4 (sqlite
  schema) and §5 (per-role images), with three subsections:
  - **Coder:** `-p`, `--permission-mode dontAsk`, `--allowedTools` from
    the brief; out-of-allowlist actions deny rather than block.
  - **Planner:** interactive REPL or stream-json with passthrough,
    `--permission-mode default` or `acceptEdits`.
  - **Auditor:** interactive stream-json, `--permission-mode
    acceptEdits` scoped to the auditor repo; main-repo read-only is
    enforced by the Docker volume mount, not by permission mode.
- Updated §4.3 step 4 ("Spawns claude-code as a child process") to
  append "(with the per-role flags from §4.5)".

Plus: added the deployment-docker.md baseline document itself, since it
did not exist. The baseline content matches the substrate's existing
§-references (e.g. daemon.js comments cite §4.1 / §4.3 / §4.4 / §4.5,
and the doc now contains those sections).

Diff: see commits 89645f7 and 07e7a91 on this branch.

### Task 1.d — coder-daemon `--allowed-tools` from brief

**Status:** applied fresh.

- New module `infra/coder-daemon/parse-tool-surface.js` parses the
  "Required tool surface" field from a task brief. Accepts both the
  bullet form (`- **Required tool surface.**`) and the heading form
  (`## Required tool surface`); accepts JSON arrays and YAML simple
  lists in the fenced code block that follows.
- `daemon.js` now reads the brief from the cloned tree, calls
  `parseToolSurface()`, and:
  - On success, passes `--allowed-tools <list>` plus the existing
    `--permission-mode dontAsk` to the spawned `claude-code` process.
  - On failure (missing field, no code block, unparseable content,
    empty list), terminates the commission with status `failed` and a
    clear error message ("required-tool-surface parse failed: ...").
- Removed the previous `allowed_tools` request-body parameter — the
  brief file is the single source of truth.
- `Dockerfile` now COPYs `parse-tool-surface.js` into `/daemon/`.
- `package.json` gains a `"test": "node --test test/"` script.

Diff: see commit d109188 on this branch.

## Verification

`node --test infra/coder-daemon/test/parse-tool-surface.test.js`
inside the `agent-coder-daemon` image. 12 tests, 12 pass:

```
ok 1 - parses YAML list under bullet marker
ok 2 - parses JSON array under heading marker
ok 3 - accepts h3 heading marker
ok 4 - fails loudly when the field is absent
ok 5 - fails when no code block follows the field
ok 6 - fails when code block is empty
ok 7 - fails when JSON in code block is malformed
ok 8 - fails on empty list
ok 9 - fails on empty string entry in JSON
ok 10 - field bullet with colon variant is recognised
ok 11 - skips intermediate text between marker and code block
ok 12 - does not consume code blocks that belong to a later field
1..12
# tests 12
# pass 12
# fail 0
```

The success/failure pair the brief required:
- Test 1 ("parses YAML list under bullet marker") — present-and-valid
  field; parser returns `["Read", "Edit", "Bash(git *)"]`.
- Test 4 ("fails loudly when the field is absent") — brief without the
  field; parser throws with message containing
  "lacks required-tool-surface declaration".

Container rebuild verified: `docker build infra/coder-daemon/`
completes cleanly with the new file copied in; `node --check
/daemon/daemon.js` returns 0; `require('/daemon/daemon.js')` resolves
the parse-tool-surface module successfully.

Not yet exercised end-to-end: a live commission through the running
daemon. The host has no node binary, but the daemon image does, and
the parser is exercised by the test suite that runs inside that image.
A future planner+coder integration run will be the first end-to-end
test; the brief did not require one for this section.

## Aggregate surface area

Files touched:
- `methodology/deployment-docker.md` — created (530 lines), then §4.3
  amended and §4.5 added (+27 lines).
- `infra/coder-daemon/daemon.js` — `--allowed-tools` now sourced from
  brief; request-body `allowed_tools` removed; brief-parse step added.
- `infra/coder-daemon/parse-tool-surface.js` — new.
- `infra/coder-daemon/test/parse-tool-surface.test.js` — new.
- `infra/coder-daemon/Dockerfile` — COPY parse-tool-surface.js.
- `infra/coder-daemon/package.json` — `test` script.

Files NOT touched (per brief constraints):
- `methodology/architect-guide.md`
- `methodology/auditor-guide.md`
- Existing task-brief examples elsewhere in the repo (none exist).

## Risks and open issues

- **`agent-coder-daemon:latest` image needs a rebuild** before the next
  pair commission, to pick up parse-tool-surface.js. `docker compose
  build coder-daemon` from the repo root suffices.
- **Existing planner code that posts `allowed_tools` in the request
  body** will silently have that field ignored. Nothing in this repo
  does so today (grep confirms), but downstream forks may. Behavior is
  not silently permissive — any commission whose brief lacks the field
  fails loudly, regardless of body contents.
- **`SETUP-BRIEF.report.md` §3 item 3** (lines 270–276) calls out that
  the daemon previously took `allowed_tools` from the POST body and
  notes this gap; that note is now obsolete. s003 retroactively files
  the report under `briefs/s000-setup/`; a follow-up note there could
  link to this section's fix, but the brief does not require it.
- **Parser permissiveness:** the parser accepts a fenced code block
  with no language tag (treated as YAML). This is intentional — the
  spec §7.3 wording does not mandate a tag — but means a coder author
  who pastes a raw bullet list outside any code block will get a
  "no fenced code block follows the field heading" failure. The error
  message is clear; the failure is recoverable by the planner editing
  the brief.

## Suggested next steps and dependencies for downstream sections

- s002 (installer-integration) is independent of this section.
- s003 (spec-catchup) item 3.a edits `deployment-docker.md §9`. That
  section was committed as part of this section's baseline — 3.a will
  be a straight edit to that pre-existing §9 OAuth-auth bullet.
- After s003 lands, consider whether the now-obsolete §3 item 3 of
  `SETUP-BRIEF.report.md` warrants an addendum noting that the gap was
  closed in s001. Out of scope for s001/s003 as written.

## Pointers to task reports

The brief's "informal decomposition" suggested two task branches but
made the split optional. I executed s001 directly on the section
branch (no separate task branches) because:
- 1.a and 1.b required no commits.
- 1.c is one commit's worth of doc edits (plus the baseline
  prerequisite, which is its own commit by nature — different file
  scope and intent).
- 1.d is one tightly-scoped code+test commit.

Three section-branch commits, each with self-explanatory messages and
matching the spec §7.4 expectations for what task reports would have
contained:
- 89645f7 — deployment-docker.md baseline.
- 07e7a91 — deployment-docker §4.5 + §4.3 cross-reference.
- d109188 — coder-daemon brief-parser + tests.
