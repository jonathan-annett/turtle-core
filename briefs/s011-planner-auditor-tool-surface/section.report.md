# Section report — s011 planner/auditor tool surface

Branch: `section/s011-planner-auditor-tool-surface` off `main`.
Base: `1890ee4` (s010 merge).
Tip:   `27e1b56`.

## Brief echo

s011 fixes a regression that shipped silently across s008 → s009 →
s010: when commission-pair.sh introduced non-interactive planner
bootstrap (s008 `47327a0` / `fba61ae`), it ran `claude -p
"${BOOTSTRAP_PROMPT}"` without any `--allowed-tools` argument. The
planner's claude session therefore had an effectively empty tool
surface and every methodology-required git operation (`git checkout`,
`git branch`, `git commit`, `git push`, `git merge`) was denied by
default. The planner self-diagnosed as "brief insufficient" — that is
correct behaviour on its part, but the cause was in the substrate,
not the brief. The same gap existed in the auditor entrypoint. The
regression was masked because s009 and s010 shipped substrate
machinery without exercising a real methodology run end-to-end.

The fix shape was symmetric and uniform with the existing coder
pattern: extend the `brief → "Required tool surface" field →
--allowed-tools` plumbing from task briefs (which works since s001's
`d109188`) up to section briefs (architect → planner) and audit
briefs (architect → auditor). The mechanism is now uniform across
all three role-pair handoffs: same field shape, shared parser, same
fail-clean semantics, same spec wording.

s011 also ports three substrate defects discovered during the
aborted Option B run on `~/hello-turtle/` (F42 / F43 / F44 — verify-
runner discipline in setup-common.sh and the platformio-esp32 YAML)
and **establishes a discipline marker**: any future section that
touches commissioning, tool-surface, role entrypoints, or the
methodology spec must include a methodology-run smoke pass in its
Definition of Done.

## Per-task summary with commit hashes

| Task | Commit | Summary |
|------|--------|---------|
| 11.a | `49a6aa6` | `methodology/agent-orchestration-spec.md` — added "Required tool surface" to section-brief schema (§7.2) and audit-brief schema (§7.6); cross-referenced from the task-brief field (§7.3); §9 expanded to note tool-surface translation is uniform across all three role-pair handoffs; spec version bumped 2.1 → 2.2. Also updated `deployment-docker.md` §4.5 with the new planner/auditor flag descriptions. Stages the section brief at `briefs/s011-planner-auditor-tool-surface/section.brief.md`. |
| 11.b | `809f564` | `methodology/architect-guide.md` — added the field to the "good section brief" / "good audit brief" shape lists and a new "Authoring the tool-surface field" subsection with YAML/JSON format examples and concrete pattern guidance for common section shapes (pure-code, remote-host SSH, HIL, audit-read-only). |
| 11.c | `8335c33` | `methodology/planner-guide.md` — new "Your tool surface" subsection noting the planner is now both **producer** (task-brief tool surface for coders) and **consumer** (section-brief tool surface from architect). Brief-insufficient recovery path documented for legitimately missing tools. |
| 11.d | `2504783` | `methodology/auditor-guide.md` — symmetric "Your tool surface" subsection. Typical audit surface (read-only main inspection plus verification tooling) and brief-insufficient recovery path. |
| 11.e | `ff7b1f4` | `infra/scripts/lib/parse-tool-surface.sh` — bash port of `infra/coder-daemon/parse-tool-surface.js`. `infra/scripts/tests/test-parse-tool-surface.sh` — 15-case test suite (11 cases mirroring the JS tests, 4 extra). `infra/planner/entrypoint.sh` — parses the brief, passes `--allowed-tools` + `--permission-mode dontAsk` to claude in non-interactive bootstrap mode, fails clean otherwise. `commission-pair.sh` sets `BRIEF_PATH` alongside `BOOTSTRAP_PROMPT`. Parser bind-mounted at `/usr/local/lib/turtle-core/parse-tool-surface.sh` via `docker-compose.yml`. |
| 11.f | `45760fa` | `infra/auditor/entrypoint.sh` — symmetric to 11.e. `audit.sh` sets `BRIEF_PATH`. `infra/auditor/Dockerfile` + `docker-compose.yml` auditor service — same bind-mount as the planner. |
| 11.g | `d74eddf` | F42: `setup-common.sh` verify-runner — `bash -lc` → `bash -c` (line ~182). F43: same wrapper — added `set -o pipefail; ${cmd}`. F44: `methodology/platforms/platformio-esp32.yaml` coder-daemon verify list — `pio platform show espressif32 \| head -1` → `pio platform show espressif32 >/dev/null`. Each fix re-implemented (not patch-copied) with inline rationale comments. |
| 11.h | `27e1b56` | `infra/scripts/tests/manual/methodology-run-smoke.md` — runbook for the full architect → planner → coder → auditor pipeline on a fresh substrate clone, including substrate-identity-gate gymnastics for running scratch alongside production. Mirrors the s010 procedure file pattern. Documents the pre-validation captured during implementation (parser tests pass, parser works inside a built planner image, parser fails clean on missing field). |

## Deterministic prompts for planner and auditor

The bootstrap prompt **text** is unchanged from s008. What changed is
the env passed alongside it (the new `BRIEF_PATH`) and the entrypoint
plumbing that activates between receiving `BOOTSTRAP_PROMPT` and
invoking `claude -p`.

### Planner — `commission-pair.sh <section-slug>`

```
Read /work/${brief_path} and execute the section per the methodology
in /methodology/planner-guide.md (which is symlinked as
/work/CLAUDE.md). The coder daemon is at http://coder-daemon:${port}.
Your bearer token is in $COMMISSION_TOKEN. Discharge when the section
is done.
```

Env: `BOOTSTRAP_PROMPT`, `BRIEF_PATH=/work/${brief_path}`,
`COMMISSION_*` as before.

`claude -p "${BOOTSTRAP_PROMPT}"` invocation:

```
claude -p "${BOOTSTRAP_PROMPT}" \
    --permission-mode dontAsk \
    --allowed-tools "$(parse-tool-surface.sh "${BRIEF_PATH}")"
```

The `dontAsk` mode + `--allowed-tools` pattern mirrors the
coder-daemon's invocation (deployment-docker.md §4.5 #Coder): non-
interactive bootstrap has no human in the loop to unblock a
permission dialogue, so out-of-allowlist actions deny rather than
prompt.

### Auditor — `audit.sh <section-slug>`

```
Read /work/${brief_path} and execute the audit per
/methodology/auditor-guide.md (symlinked as /work/CLAUDE.md). Your
private workspace is /auditor (writable). The main repo at /work is
read-only. Write the audit report to the auditor repo at the path
named in the brief, commit and push, then discharge.
```

Env: `BOOTSTRAP_PROMPT`, `BRIEF_PATH=/work/${brief_path}`.

Same `claude -p ... --permission-mode dontAsk --allowed-tools ...`
invocation as the planner.

## Smoke-test transcript

The methodology-run smoke is a manual procedure documented at
`infra/scripts/tests/manual/methodology-run-smoke.md`. Pre-validation
captured during s011 implementation:

- **Parser unit tests pass.** `bash infra/scripts/tests/test-parse-tool-surface.sh` → 15/15.
- **Parser works inside a built planner image.** Built `agent-planner:s011-test` from the s011 Dockerfile, ran the parser with both a brief that has a tool surface and one that doesn't:
  - Has-field: emitted `Read,Edit,Write,Bash(git checkout:*),Bash(git commit:*),Bash(git push:*),Bash(curl:*)` with rc=0.
  - Lacks-field: emitted `tool-surface: brief at /work/test-brief.md has no 'Required tool surface' field. The architect must author this field; see methodology/agent-orchestration-spec.md §7.2 (section briefs) or §7.6 (audit briefs).` with rc=1.
- **All shell changes pass `bash -n`** (parser, planner/auditor entrypoints, commission-pair.sh, audit.sh).

The full operator-side transcript of the architect drafting +
planner run + audit run on a scratch substrate will be appended to
the procedure file the next time it is executed end-to-end. The
operator should run it before any future section that touches the
commission pathway.

## Resolution of the six design calls

All six recommendations from the brief were kept as written.

1. **Tool-surface authoritative source: section/audit brief authored by
   architect** — kept. Mirrors the existing task-brief field; one parser
   pattern, one documentation pattern, one mental model. No methodology-
   wide config file; no hybrid scheme. The hybrid option remains a viable
   later enhancement.

2. **Fail clean when tool surface is absent** — kept. The entrypoints
   print an actionable error pointing at the offending brief and the
   spec section, then drop to a shell for post-mortem. No silent default
   to permissive (security/correctness hazard); no silent default to
   empty (which was the bug we are fixing).

3. **Tool-surface field format: mirror the existing task-brief format**
   — kept. The bash parser (`parse-tool-surface.sh`) is a port of the
   JS parser (`parse-tool-surface.js`). Same input schema (bullet or
   heading marker, fenced YAML or JSON list inside). Same 15-case test
   coverage. Same failure messages.

4. **Spec is canonical; guides are regenerated** — kept. Hand-edited
   the three role guides consistently with the spec change; the guide
   header lines were bumped from `v2.1` to `v2.2`. No regen script
   exists in the repo today; the "derivative" language in the guide
   headers describes human-curated regeneration, not scripted.

5. **F42/F43/F44 porting: re-implement directly in turtle-core, do not
   copy patches from hello-turtle** — kept. Each fix is local to one
   site in turtle-core and carries an inline comment with the rationale
   and cross-reference to this section. The hello-turtle clone was not
   touched.

6. **Methodology-run smoke test: minimal hello-world, single section,
   captured transcript** — adapted. The procedure document follows the
   s010 manual-procedure pattern (`remote-host-tdongle.md`) and is
   captured at `infra/scripts/tests/manual/methodology-run-smoke.md`.
   The end-to-end captured transcript is appended by whoever next runs
   the procedure on a fresh substrate; in this section, only pre-
   validation pieces that could be exercised without disturbing the
   production substrate were captured inline (parser unit tests,
   parser inside a built planner image, shell syntax checks). The
   procedure documents the substrate-identity-gate gymnastics needed
   to run a scratch substrate concurrent with production.

## Notable findings

### F45 — section-brief tool surface vs. planner permission mode

The planner has historically been spec'd as a "judgement role" with
the human in the loop, so its claude session ran with `--permission-mode
default` or `acceptEdits` (deployment-docker §4.5). Non-interactive
bootstrap (s008) broke that invariant: there is no human in the loop
during `claude -p "${BOOTSTRAP_PROMPT}"`. The s011 entrypoint resolves
this by switching to `--permission-mode dontAsk` **only in the
non-interactive bootstrap path**. The interactive (manual-shell)
commission-pair.sh path is untouched and retains the spec-default
behaviour.

This is a substantive permission-model change for the non-interactive
planner. The auditor inherits the same change for symmetric reasons.
It is worth recording explicitly so a future section that wants to
revive interactive planner behaviour with the new tool-surface plumbing
knows where the mode toggle lives.

### F46 — substrate-identity gate complicates scratch-substrate testing

Running a fresh substrate clone alongside an existing production
substrate triggers the substrate-identity gate's Case 2 ("docker
volume present, this tree has no .substrate-id"). The volume-swap
dance documented in the smoke procedure (§Step 2 / §Step 8) works
but is awkward for a casual operator.

This isn't a substrate defect — the gate is correctly preventing
silent volume-id mismatch — but the friction is real. A future
section could parameterise the volume names (e.g.
`SUBSTRATE_VOLUME_PREFIX`) so a scratch substrate uses
`claude-state-architect-scratch-${pid}` and avoids the collision.
Out of scope here.

### Original F46 from the brief — LAN smoke false negative on Crostini

The brief mentions F46 (LAN smoke test false negative on Crostini) as
deferred. Not touched here.

### F47 — commission-pair from wrong clone uses wrong keys

The brief mentions F47 as "UX paper-cut; can fold in if trivially
adjacent during entrypoint work, otherwise leave for a follow-up".
Not folded in: the entrypoint work this section did was about
parsing briefs, not about validating clone↔keys correspondence. F47
remains deferred.

### F48 — ephemeral creds stale after architect OAuth refresh

Documented workaround (re-run `verify.sh`) still applies. Not touched.

## Residual hazards

- **Smoke transcript appendix is empty.** The methodology-run smoke
  procedure document at `infra/scripts/tests/manual/methodology-run-smoke.md`
  has a `## Transcript: <YYYY-MM-DD>` placeholder for the operator
  to append on first end-to-end run. The pre-validation that *was*
  captured (parser tests, parser inside a built planner image) is
  necessary but not sufficient — a real architect + planner + coder +
  auditor run on a fresh substrate has not yet happened on this branch.
  The auditor should require it before sign-off.

- **The bash parser depends on `jq`.** `jq` is in `agent-base`'s apt
  install line, so the planner and auditor (which inherit) have it.
  If a future cost-driven base-image audit removes `jq`, the JSON
  branch of `parse-tool-surface.sh` will fail loudly with an
  `jq: command not found`. Tests are red-flag in that case.

- **The fallback "scrape brief path out of BOOTSTRAP_PROMPT" exists
  only as defence-in-depth.** Both `commission-pair.sh` and
  `audit.sh` set `BRIEF_PATH` explicitly. If a downstream caller
  generates `BOOTSTRAP_PROMPT` differently (e.g., not starting with
  `Read /work/...`), the scrape returns empty and the entrypoint
  falls through to shell-mode with an error. This is fail-clean by
  design, but it does mean the env contract is BRIEF_PATH + BOOTSTRAP_PROMPT,
  not BOOTSTRAP_PROMPT alone.

- **The s011 brief itself does not include a "Required tool surface"
  field.** s011 was implemented as substrate-iteration (single agent
  on host, not commissioned via planner) per the brief's "How to read
  this brief" section, so the gap doesn't matter for s011's own
  execution. The dogfood smoke section's hello-world brief will be the
  first brief authored under the new schema; it is exercised by the
  operator-run smoke procedure.

- **Discipline marker is documented, not enforced.** The smoke
  procedure's last section says "any future section that touches
  commissioning … must include a methodology-run smoke in its DoD."
  This is a convention; no CI gate enforces it. The next section's
  architect-author is on the honour system, with the section report
  as the audit trail.

## Push status

Section branch will be pushed to origin before discharge (Finding 35
discipline). Architect handles the section→main merge after audit.
