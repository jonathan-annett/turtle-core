# s009 — section report: platform-plugin

## Brief echo

The s009 brief at `briefs/s009-platform-plugin/section.brief.md`
identifies the next structural gap after s008's deterministic
commissioning: the substrate's role images (`coder-daemon` and
`auditor`) are single-toolchain. They carry node + npm +
build-essential + python3 baked at image build time, with no first-
class way for a project targeting Go, Rust, C/C++, or an embedded
platform to extend them.

s009 introduces a **platform plugin model**. Each target platform is
defined by a small YAML file in `methodology/platforms/<name>.yaml`.
At substrate setup, the human selects one or more platforms via
`./setup-linux.sh --platform=<name>` (or `--platform=<a>,<b>` for
polyglot). The setup pipeline renders role Dockerfiles by composing
the static template with the selected platform layers, then builds
the images and runs setup-time verify per platform per role.

The model also covers **runtime device passthrough**, a hard
requirement for embedded targets: PlatformIO's `pio test` for ESP32
flashes the device over USB and reads test results back via UART.
Without serial access, the auditor can only do static analysis and
the coder can't TDD the way embedded coders actually work. Platform
YAMLs may declare `runtime.device_required`, `runtime.device_hint`,
and `runtime.groups` (e.g. `[dialout]`); the operator wires devices
in via `--device=<host-path>`. The substrate is forward-compatible
with the planned-next-section remote serial bridge: a tunnelled
virtual `/dev/tty*` on the Docker host is consumed transparently.

Five design calls were baked into the brief:

1. **Generated Dockerfiles, not build args.** Kept.
2. **Polyglot defaults disabled.** Kept (defaults consumption is
   s010 scope; the current architect-guide paragraph just records
   the platform list, doesn't merge defaults).
3. **`--allowedTools` template model.** Kept (defaults consumption
   deferred to s010).
4. **`--add-platform` refuses on in-flight work.** Kept; refusal
   covers both running ephemeral containers AND section/* branches
   ahead of main on origin. `--force` overrides.
5. **`device_required: true` warns rather than fails.** Kept.

## Per-task summary

| Task | Subject                                                      | Commit    |
| ---- | ------------------------------------------------------------ | --------- |
| 9.a  | Platform YAML schema + 7 ship-with platforms + validator     | `a376bae` |
| 9.c  | Dockerfile renderer + sentinel anchors in role templates     | `2bc393c` |
| 9.b  | `--platform` / `--device` argument parsing                   | `ea07dff` |
| 9.d  | Compose wiring + setup-common integration (renderers, verify, devices) | `e370e40` |
| 9.f  | Expose platform configuration to architect                   | `2091f34` |
| 9.e  | `--add-platform` / `--add-device` on running substrate       | `47b06d4` |
| 9.g  | Substrate end-to-end test extended with phases 9–16          | `dc416c3` |
| 9.g* | (fixup) bash -c not -lc; cleanup correctness                 | `92d4650` |
| 9.h  | deployment-docker §10 + README quickstart                    | `49c755e` |

(Tasks landed in 9.a → 9.c → 9.b → 9.d → 9.f → 9.e → 9.g → 9.h
order rather than the brief's numeric order. 9.c was the
largest piece of new code and self-contained; 9.b's argument
parsing is small; 9.d wires them together. 9.f writes the state
files that 9.e then reads. The dependency graph shaped the
ordering; commits are independently reviewable.)

### 9.a — Platform YAML schema, ship-with platforms, validator

`methodology/platforms/README.md` documents the schema:

- Required: `name` (must match filename), `description`, `roles`
  (may be empty `{}`).
- Per-role: optional `apt` (list), `install` (list), `env` (map),
  `verify` (list).
- Optional `runtime` block: `device_required` (bool),
  `device_hint` (string), `groups` (list — supplementary groups
  for the agent user, applied via `usermod -a -G`).
- Optional `defaults` block: `test_runner`, `build_command`,
  `allowed_tools`. Currently template-only — full architect/planner
  consumption is deferred to s010.

Seven YAMLs ship: `default` (no-op), `go`, `rust`, `python-extras`,
`node-extras`, `c-cpp`, `platformio-esp32` (the only one with a
`runtime` block).

`infra/scripts/lib/yaml.sh` wraps `mikefarah/yq:4` (a tiny static-
binary docker image) with `yaml_pull`, `yaml_to_json`, and
`yaml_eval` helpers. The Mike Farah yq was chosen over Python +
PyYAML because PyYAML isn't on the host by default (only the json
stdlib is, which is enough for downstream JSON processing). The
docker wrapper means no extra host prereq beyond the docker that
the substrate already requires; the v4 tag is pinned to protect
against the well-known v3-vs-v4 syntax break.

`infra/scripts/lib/validate-platform.sh` parses each YAML via
`yaml_to_json` and runs the schema rules in a Python stdlib script.
It catches missing required fields, name/filename mismatch, wrong
types per field, unknown roles, and unparseable YAML. Setup sources
it via `platform-args.sh` and aborts on validation failure with a
clear diagnostic.

### 9.c — Dockerfile renderer

`infra/scripts/render-dockerfile.sh` reads
`infra/<role>/Dockerfile`, finds the `# PLATFORM_INSERT_HERE`
sentinel, splits into head and tail. Aggregates `runtime.groups`
across all selected platforms; if any are present, emits a single
early `USER root` + `usermod -a -G <merged> agent` block. Then for
each platform per role, emits an apt block (USER root, wrapped
install + cache clean), an install block (USER agent, RUN with &&
chained commands), an env block (one ENV K=V per entry, auto-
quoting values that contain whitespace or quotes), and a verify
block (USER agent, RUN with && chained commands). Tracks the
active USER as it emits so it doesn't sprinkle redundant USER
directives. Ends in USER agent (renderer contract — the static
template's tail is written assuming agent).

The renderer skips blocks the platform doesn't define and skips
the platform entirely if it doesn't define the requested role. So
`default` contributes nothing, and a polyglot list with one
auditor-only platform produces a clean result for both roles.

Output is written to `infra/<role>/Dockerfile.generated` and chmod
0444 to make 'do not edit' a hard contract; the renderer rm -fs
the file before each write so the read-only flag doesn't block
re-renders. `.gitignore` includes the generated path.

The static templates `infra/coder-daemon/Dockerfile` and
`infra/auditor/Dockerfile` were updated: the existing free-form
extension-point comment in coder-daemon was replaced with the
explicit sentinel; an explicit `USER root` was re-asserted before
the daemon-dirs RUN so the file stays robust regardless of which
user the renderer left us in. auditor got the sentinel inserted
between the auditor mkdir and the entrypoint COPY.

With `--platform=default` (or no flag) the only difference between
`Dockerfile.generated` and the static template is the generated-
header comment and the missing sentinel line. Image content is
byte-equivalent at the build-cache level.

### 9.b — Argument parsing

`infra/scripts/lib/platform-args.sh` is a sourceable bash helper
parsing `--platform=<csv>`, `--device=<csv>`,
`--add-platform=<name>`, `--add-device=<csv>`, and `--force`.
Multiple `--platform` / `--device` flags concatenate; literal
`default` folds away when other platforms are present. Each named
platform is validated against its YAML; each `--device` path is
validated as `test -e` on the host. For each platform with
`runtime.device_required: true` and no `--device` supplied, a
warning is emitted to stderr (per design call 5: this is a
warning, not a failure).

Both `setup-linux.sh` and `setup-mac.sh` source the helper. The
new flags appear in `--help` via `platform_args_help_block`.
Argument finalisation runs only when we'll actually proceed into
setup (skipped under `--install-docker`, which exits before
`setup-common.sh` is sourced).

### 9.d — Compose wiring + setup integration

`docker-compose.yml`: `coder-daemon` and `auditor` build sections
now point at `Dockerfile.generated`. The other services
(architect, planner, git-server) keep their static Dockerfiles —
9.c only renders the two roles whose toolchains the platform
plugin model is meant to extend.

`infra/scripts/render-device-override.sh` writes
`docker-compose.override.yml` at the **repo root** (not under
`infra/` as the brief literally specifies — see *Deviations*
below) with a `devices:` block on coder-daemon and auditor when
device passthrough is configured; removes any prior override file
when no devices are mapped.

`setup-common.sh` §5 reworked:
1. Defaults `SUBSTRATE_PLATFORMS` to `default` if the entrypoint
   didn't export it (defensive — exec'd flows still work).
2. Calls `render-dockerfile.sh` for both roles before agent-base
   builds.
3. Calls `render-device-override.sh` after compose build so the
   override is in place for later compose runs in the same setup.
4. New §5.5 setup-time verify: runs each role's verify list
   inside one-shot containers
   (`docker run --rm --entrypoint bash agent-<role>:latest -c <cmd>`).
   Bypassing the entrypoint matters because coder-daemon's
   entrypoint starts the daemon and auditor's clones git-server
   (which isn't up yet at this stage). Failure produces a clear
   platform/role/command diagnostic and aborts setup.
5. New §9.5 re-emits the device_required-without-device warning at
   the very end of setup, so it's the LAST thing the human sees
   before setup completes.

### 9.f — Expose platform configuration to architect

Two surfaces:

1. **Environment variables.** `docker-compose.yml`'s architect
   service now inherits `SUBSTRATE_PLATFORMS` and `SUBSTRATE_DEVICES`
   from the host shell (exported by `platform_args_finalize`).
2. **State files.** setup-common.sh §5.7 writes
   `.substrate-state/platforms.txt` and `.substrate-state/devices.txt`
   at the repo root before architect comes up. The architect compose
   service mounts the directory read-only at `/substrate`, so the
   architect sees `/substrate/platforms.txt` and
   `/substrate/devices.txt` populated on first start.

`architect-guide.md` got a single short subsection ('Substrate
platform invariants') under 'The shared-state document' that
directs the architect to read the two files and record the
platform/device information in `SHARED-STATE.md` as project-wide
decisions / hardware-in-the-loop devices respectively. Resists the
temptation to do more here — full architect/planner/auditor
integration (consuming `defaults.test_runner`, propagating into
briefs) is explicitly deferred to s010 per the brief's out-of-
scope list.

### 9.e — `--add-platform` / `--add-device` on running substrate

`infra/scripts/add-platform-device.sh` is dispatched by setup-linux/
mac whenever `SUBSTRATE_ADD_PLATFORM` or `SUBSTRATE_ADD_DEVICES`
is non-empty. Combining the add flags with the initial-setup
`--platform` / `--device` flags is rejected with a clear message
(the two modes are conceptually distinct: setup vs. extend in
place).

`--add-platform`:
1. Validate the new platform YAML.
2. Compose new platform list = current ∪ {new}, dropping `default`
   and de-duplicating.
3. Pre-flight (a): refuse if any container running with one of the
   role images is found via `docker ps`.
4. Pre-flight (b): refuse if `agent-git-server` is down (cannot
   determine state) or if any `section/*` branch on origin has
   commits ahead of main (queried via
   `docker exec agent-git-server git for-each-ref + rev-list`).
5. `--force` skips both pre-flights.
6. Re-render Dockerfile.generated for both roles via the renderer.
7. Rebuild only coder-daemon + auditor (architect / git-server are
   unaffected).
8. Setup-time verify the NEW platform only.
9. Update `.substrate-state/platforms.txt` and emit a hint that
   SHARED-STATE.md should be refreshed by the architect.

`--add-device`:
1. Validate paths exist on host.
2. Pre-flight (a) only — adding a device cannot invalidate
   in-progress section work.
3. Append to existing device list (de-dup); re-render override.
   No image rebuild — devices are runtime, not build-time.
4. Update `.substrate-state/devices.txt`.

The script is parameterized via `GIT_SERVER_CONTAINER` (default
`agent-git-server`) and `ROLE_IMAGE_PATTERNS` (default the
canonical role images) so the test phases (9.g) can point them at
scratch resources without running against the production substrate.

### 9.g — Test extension (phases 9–16)

Eight new phases added to
`infra/scripts/tests/test-substrate-end-to-end.sh`. Each phase
scaffolds its own platform-specific scratch state (Dockerfile.
generated, override file, .substrate-state directory, per-phase
image tags); the wrapper trap restores the host's canonical role
images at exit so the test can be run repeatedly without leaving
the host's `agent-coder-daemon:latest` carrying test platforms.

Phase 9 builds with `--platform=go` and asserts `go version` runs
inside both role images and the architect contract
(`SUBSTRATE_PLATFORMS` env + `/substrate/platforms.txt`). Phase 10
does the same for the polyglot `--platform=go,python-extras`.
Phases 11–13 exercise `--add-platform` (happy path; refusal on
running container; refusal on pending section). Phase 14 exercises
the device-wiring path through both `docker run --device` directly
AND `docker compose` autoload of `docker-compose.override.yml`
(the production code path). Phase 15 verifies the device_required
warning. Phase 16 exercises `--add-device` and asserts no rebuild
happens.

Verified across three full end-to-end runs: 58 passed, 0 failed.
The host's canonical role images carry no test platforms after
the test trap fires.

### 9.h — Documentation

`methodology/deployment-docker.md` got a new §10 'Platforms'
covering the model, the ship-with catalog, the four operator flags,
the seven-step setup pipeline, the running-substrate extension
model, the HIL test pattern, and a forward reference to the
remote-serial-bridge section. The pre-existing §10 was renumbered
to §11.

`README.md` quickstart got `--platform` examples and a paragraph
pointing to the platforms README for the catalog and to the
deployment-docker §10 for the operator workflow.

Inline comment headers in all new scripts were authored alongside
their bodies in 9.a–9.e. The architect-guide paragraph was added
in 9.f.

## Reference: rendered `Dockerfile.generated` for `--platform=go,python-extras`

### `coder-daemon`

```
# GENERATED by infra/scripts/render-dockerfile.sh — DO NOT EDIT.
# role:      coder-daemon
# platforms: go,python-extras
# Re-render via: ./setup-linux.sh (or .sh-mac); the renderer runs
# in step 5 of setup before 'docker compose build'.

# Coder daemon: ephemeral, paired with planner. Runs an HTTP server that
# accepts task-brief commissions from the planner and spawns claude-code
# subshells (one at a time) to fulfil them.
#
# This image also carries the project's BUILD TOOLCHAIN, because coders
# run as subshells inside this container and need to compile/test the
# project. The base layer is node (used both for the daemon and for the
# proof-of-concept timestamps CLI). Downstream projects extend this image
# with their language toolchain.

FROM agent-base

USER root

# Node runtime + npm. The daemon uses Express + better-sqlite3 + uuid.
RUN apt-get update && apt-get install -y --no-install-recommends \
        nodejs npm \
        build-essential python3 \
    && rm -rf /var/lib/apt/lists/*

# ----------------------------------------------------------------------------
# Project build toolchain. The line below is the sentinel consumed by
# infra/scripts/render-dockerfile.sh — the renderer composes the
# selected platform plugin layers (methodology/platforms/<name>.yaml)
# in place of this comment when producing Dockerfile.generated. With
# --platform=default (or no flag) the sentinel is simply removed and
# the file is byte-equivalent to this template aside from a generated-
# file header.
# ----------------------------------------------------------------------------

# ---- Platform: go (coder-daemon) ----
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
        golang-go \
    && rm -rf /var/lib/apt/lists/*
USER agent
RUN go version

# ---- Platform: python-extras (coder-daemon) ----
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*
USER agent
RUN python3 -m venv /home/agent/.python-extras-venv \
 && /home/agent/.python-extras-venv/bin/pip install --no-cache-dir uv poetry pytest
ENV PATH=/home/agent/.python-extras-venv/bin:${PATH}
RUN uv --version \
 && poetry --version \
 && pytest --version

# Daemon working dir. USER root is re-asserted explicitly so the file is
# robust regardless of what the renderer emitted above (a platform block
# always ends in USER agent, by contract — see render-dockerfile.sh).
USER root
RUN mkdir -p /daemon /data && chown -R agent:agent /daemon /data

USER agent
WORKDIR /daemon

COPY --chown=agent:agent package.json /daemon/package.json
RUN npm install --omit=dev --no-fund --no-audit

COPY --chown=agent:agent --chmod=0755 daemon.js              /daemon/daemon.js
COPY --chown=agent:agent              parse-tool-surface.js /daemon/parse-tool-surface.js
COPY --chown=agent:agent --chmod=0755 entrypoint.sh           /daemon/entrypoint.sh

ENTRYPOINT ["/daemon/entrypoint.sh"]
```

### `auditor`

```
# GENERATED by infra/scripts/render-dockerfile.sh — DO NOT EDIT.
# role:      auditor
# platforms: go,python-extras
# Re-render via: ./setup-linux.sh (or .sh-mac); the renderer runs
# in step 5 of setup before 'docker compose build'.

# Auditor: ephemeral claude-code session, one per audit. Minimal in the
# template; downstream projects extend this image with adversarial tools
# (fuzzers, static analyzers, exploit harnesses) per their domain.

FROM agent-base

USER root
RUN mkdir -p /auditor && chown agent:agent /auditor

# ----------------------------------------------------------------------------
# Project adversarial / static-analysis toolchain. The line below is the
# sentinel consumed by infra/scripts/render-dockerfile.sh — the renderer
# composes the selected platform plugin layers (methodology/platforms/
# <name>.yaml) in place of this comment when producing
# Dockerfile.generated. With --platform=default (or no flag) the sentinel
# is simply removed and the file is byte-equivalent to this template
# aside from a generated-file header.
# ----------------------------------------------------------------------------

# ---- Platform: go (auditor) ----
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
        golang-go \
    && rm -rf /var/lib/apt/lists/*
USER agent
RUN go version

# ---- Platform: python-extras (auditor) ----
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*
USER agent
RUN python3 -m venv /home/agent/.python-extras-venv \
 && /home/agent/.python-extras-venv/bin/pip install --no-cache-dir uv poetry pytest
ENV PATH=/home/agent/.python-extras-venv/bin:${PATH}
RUN uv --version \
 && poetry --version \
 && pytest --version

USER agent

COPY --chown=agent:agent --chmod=0755 entrypoint.sh /home/agent/entrypoint.sh

ENTRYPOINT ["/home/agent/entrypoint.sh"]
```

## Reference: rendered `Dockerfile.generated` for `--platform=platformio-esp32`

The interesting part: the `runtime.groups: [dialout]` declaration
in the platform YAML produces the `usermod -a -G dialout agent`
block at image-build time, before any platform layers. The renderer
notes this is the merged-groups block (in case multiple platforms
declare groups; here only one).

### `coder-daemon`

```
# GENERATED by infra/scripts/render-dockerfile.sh — DO NOT EDIT.
# role:      coder-daemon
# platforms: platformio-esp32
# Re-render via: ./setup-linux.sh (or .sh-mac); the renderer runs
# in step 5 of setup before 'docker compose build'.

# Coder daemon: ephemeral, paired with planner. Runs an HTTP server that
# accepts task-brief commissions from the planner and spawns claude-code
# subshells (one at a time) to fulfil them.
#
# This image also carries the project's BUILD TOOLCHAIN, because coders
# run as subshells inside this container and need to compile/test the
# project. The base layer is node (used both for the daemon and for the
# proof-of-concept timestamps CLI). Downstream projects extend this image
# with their language toolchain.

FROM agent-base

USER root

# Node runtime + npm. The daemon uses Express + better-sqlite3 + uuid.
RUN apt-get update && apt-get install -y --no-install-recommends \
        nodejs npm \
        build-essential python3 \
    && rm -rf /var/lib/apt/lists/*

# ----------------------------------------------------------------------------
# Project build toolchain. The line below is the sentinel consumed by
# infra/scripts/render-dockerfile.sh — the renderer composes the
# selected platform plugin layers (methodology/platforms/<name>.yaml)
# in place of this comment when producing Dockerfile.generated. With
# --platform=default (or no flag) the sentinel is simply removed and
# the file is byte-equivalent to this template aside from a generated-
# file header.
# ----------------------------------------------------------------------------

# ---- platform runtime.groups (merged) ----
USER root
RUN usermod -a -G dialout agent

# ---- Platform: platformio-esp32 (coder-daemon) ----
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3-venv python3-pip \
    && rm -rf /var/lib/apt/lists/*
USER agent
RUN python3 -m venv /home/agent/.platformio-venv \
 && /home/agent/.platformio-venv/bin/pip install --no-cache-dir platformio \
 && /home/agent/.platformio-venv/bin/pio platform install espressif32
ENV PATH=/home/agent/.platformio-venv/bin:${PATH}
RUN pio --version \
 && pio platform show espressif32 | head -1

# Daemon working dir. USER root is re-asserted explicitly so the file is
# robust regardless of what the renderer emitted above (a platform block
# always ends in USER agent, by contract — see render-dockerfile.sh).
USER root
RUN mkdir -p /daemon /data && chown -R agent:agent /daemon /data

USER agent
WORKDIR /daemon

COPY --chown=agent:agent package.json /daemon/package.json
RUN npm install --omit=dev --no-fund --no-audit

COPY --chown=agent:agent --chmod=0755 daemon.js              /daemon/daemon.js
COPY --chown=agent:agent              parse-tool-surface.js /daemon/parse-tool-surface.js
COPY --chown=agent:agent --chmod=0755 entrypoint.sh           /daemon/entrypoint.sh

ENTRYPOINT ["/daemon/entrypoint.sh"]
```

### `auditor`

```
# GENERATED by infra/scripts/render-dockerfile.sh — DO NOT EDIT.
# role:      auditor
# platforms: platformio-esp32
# Re-render via: ./setup-linux.sh (or .sh-mac); the renderer runs
# in step 5 of setup before 'docker compose build'.

# Auditor: ephemeral claude-code session, one per audit. Minimal in the
# template; downstream projects extend this image with adversarial tools
# (fuzzers, static analyzers, exploit harnesses) per their domain.

FROM agent-base

USER root
RUN mkdir -p /auditor && chown agent:agent /auditor

# ----------------------------------------------------------------------------
# Project adversarial / static-analysis toolchain. The line below is the
# sentinel consumed by infra/scripts/render-dockerfile.sh — the renderer
# composes the selected platform plugin layers (methodology/platforms/
# <name>.yaml) in place of this comment when producing
# Dockerfile.generated. With --platform=default (or no flag) the sentinel
# is simply removed and the file is byte-equivalent to this template
# aside from a generated-file header.
# ----------------------------------------------------------------------------

# ---- platform runtime.groups (merged) ----
USER root
RUN usermod -a -G dialout agent

# ---- Platform: platformio-esp32 (auditor) ----
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3-venv python3-pip cppcheck \
    && rm -rf /var/lib/apt/lists/*
USER agent
RUN python3 -m venv /home/agent/.platformio-venv \
 && /home/agent/.platformio-venv/bin/pip install --no-cache-dir platformio \
 && /home/agent/.platformio-venv/bin/pio platform install espressif32
ENV PATH=/home/agent/.platformio-venv/bin:${PATH}
RUN pio --version \
 && cppcheck --version

USER agent

COPY --chown=agent:agent --chmod=0755 entrypoint.sh /home/agent/entrypoint.sh

ENTRYPOINT ["/home/agent/entrypoint.sh"]
```

## Reference: rendered device override for `--device=/dev/null,/dev/zero`

```yaml
# GENERATED by infra/scripts/render-device-override.sh — DO NOT EDIT.
# devices: /dev/null,/dev/zero
# Re-render via setup (--device=<path>) or --add-device=<path>.

services:
  coder-daemon:
    devices:
      - "/dev/null:/dev/null"
      - "/dev/zero:/dev/zero"
  auditor:
    devices:
      - "/dev/null:/dev/null"
      - "/dev/zero:/dev/zero"
```

The file is at the repo root (`docker-compose.override.yml`) and
gitignored. compose autoloads `docker-compose.override.yml` from the
project directory, so every existing call site picks up the device
wiring transparently — no code changes in commission-pair.sh,
audit.sh, verify.sh, or the substrate end-to-end test.

## Validator behaviour on a deliberately-malformed YAML

Input: `name: badrole; description: ...; roles: { planner: { apt:
[foo-pkg] } }` (uses `planner`, which isn't one of the recognised
roles).

Output:

```
/tmp/tmp.Ck7Vmai0CC/badrole.yaml: roles.planner: unknown role; must be one of ['auditor', 'coder-daemon']
validator rc=1
```

The validator catches the error before the renderer or compose
build runs; setup-common.sh aborts with the message above and
references the offending file.

## Test transcript: phases 9–16

Captured from a clean run of
`bash infra/scripts/tests/test-substrate-end-to-end.sh` against
the host substrate on 2026-05-10:

```
----------------------------------------------------------------------
Phase 9: single-platform setup (--platform=go)
PASS: phase 9: coder-daemon built with --platform=go (tag=agent-coder-daemon:test-s009-10712-9-coder-daemon)
PASS: phase 9: auditor built with --platform=go (tag=agent-auditor:test-s009-10712-9-auditor)
PASS: phase 9 (i): 'go version' runs inside agent-coder-daemon:test-s009-10712-9-coder-daemon
PASS: phase 9 (ii): 'go version' runs inside agent-auditor:test-s009-10712-9-auditor
PASS: phase 9 (iii)+(iv): SUBSTRATE_PLATFORMS env and /substrate/platforms.txt both contain 'go'
----------------------------------------------------------------------
Phase 10: polyglot setup (--platform=go,python-extras)
PASS: phase 10: coder-daemon built with --platform=go,python-extras
PASS: phase 10: auditor built with --platform=go,python-extras
PASS: phase 10: both 'go version' and 'uv --version' run inside agent-coder-daemon:test-s009-10712-10-coder-daemon
PASS: phase 10: both 'go version' and 'uv --version' run inside agent-auditor:test-s009-10712-10-auditor
PASS: phase 10: /substrate/platforms.txt contains both names
----------------------------------------------------------------------
Phase 11: --add-platform happy path
PASS: phase 11: --add-platform=c-cpp succeeded (rc=0)
PASS: phase 11: state file updated to 'go,c-cpp'
----------------------------------------------------------------------
Phase 12: --add-platform refusal — running container
PASS: phase 12: --add-platform refused (rc=1)
PASS: phase 12: error message names the running planner container
PASS: phase 12: state file unchanged
----------------------------------------------------------------------
Phase 13: --add-platform refusal — pending section branch
PASS: phase 13: --add-platform refused (rc=1)
PASS: phase 13: error message names the pending section branch
PASS: phase 13: state file unchanged
----------------------------------------------------------------------
Phase 14: device passthrough wiring (--device=/dev/null)
PASS: phase 14: override file contains /dev/null:/dev/null entry
PASS: phase 14: /substrate/devices.txt contains /dev/null
PASS: phase 14: --device wiring exposes /dev/null inside coder-daemon
PASS: phase 14: compose autoload of override.yml wires /dev/null
----------------------------------------------------------------------
Phase 15: device_required warning
PASS: phase 15: setup proceeds (rc=0); SUBSTRATE_DEVICE_REQUIRED_MISSING populated
PASS: phase 15: warning text mentions device_required and platformio-esp32
----------------------------------------------------------------------
Phase 16: --add-device happy path
PASS: phase 16: --add-device=/dev/null succeeded
PASS: phase 16: state file devices.txt updated to /dev/null
PASS: phase 16: agent-coder-daemon:latest image ID unchanged (no rebuild)
----------------------------------------------------------------------
Summary: 58 passed, 0 failed
```

(58 = 31 from s007/s008 + 27 from s009 phases 9–16. The brief
predicted "39/39 (assuming s008's 31 + 8 new)" but the s009 phases
have multiple per-phase assertions, totalling 27.)

Total runtime per full pass: roughly 6–10 minutes on the host
(most of it phase 10 building python-extras with poetry, and
phase 11 rebuilding canonical role images during --add-platform).
The brief flagged this as expected.

## Resolution of the five design calls

| # | Brief recommendation | Resolution |
| - | -------------------- | ---------- |
| 1 | Generated Dockerfiles, not build args | **KEPT.** Renderer writes `Dockerfile.generated`; compose builds against it; generated file is gitignored. |
| 2 | Polyglot `defaults` disabled | **KEPT.** The current architect-guide paragraph just records the platform list; merging `defaults.test_runner` etc. is s010 scope. |
| 3 | `--allowedTools` template model | **KEPT.** Defaults consumption deferred to s010; for s009 the platform's `defaults.allowed_tools` is data carried in the YAML, not yet propagated. |
| 4 | `--add-platform` refuses on in-flight work (containers OR pending sections) | **KEPT.** Refusal covers both; `--force` overrides. |
| 5 | `device_required: true` warns rather than fails | **KEPT.** Warning emitted at parse time AND at end of setup; setup proceeds with rc=0. |

## Deviations from the brief

Two implementation deviations, both intentional:

1. **Substrate state directory location.** The brief specifies
   `/var/turtle-core-state/` as the host location for
   `platforms.txt` and `devices.txt`. Implementation uses
   `.substrate-state/` in the repo root instead, for consistency
   with the existing `.substrate-id` sentinel and `infra/keys/*`
   convention (the substrate is otherwise repo-local everywhere;
   `/var/` would be the only artefact requiring root for first
   `mkdir`). The architect-guide paragraph and architect compose
   mount reference `/substrate` as the in-container path, which
   matches the brief.

2. **Device override file location.** The brief specifies
   `infra/docker-compose.devices.yml` for the device override.
   Implementation writes to `docker-compose.override.yml` at the
   repo root. The brief acknowledged this as "pick whichever is
   cleanest with current Compose version constraints"; the repo-
   root location triggers compose autoload, which means every
   existing call site (commission-pair.sh, audit.sh, verify.sh,
   the substrate end-to-end test) gets device wiring transparently
   without a code change. .gitignore was updated accordingly.

Both deviations were noted in their respective commit messages.

## Residual hazards

- **Image cache invariants under repeated rebuilds.** During test
  development I noticed BuildKit can prune the previous canonical
  image when re-tagging via `docker compose build`, which broke
  the test's first-attempt image-restore mechanism (snapshot by
  image ID didn't survive the rebuild). Fixed by snapshotting
  through a stable per-test tag (`agent-<role>:s009-pretest-<pid>`)
  that holds the image alive. The same pattern would matter for
  any operator who wants to "save current images, run an
  experiment, restore". Not exposed as a substrate feature; the
  test owns the workaround locally.

- **Network access required at image-build time.** Several
  platforms install via curl-script (rust) or pip (python-extras,
  platformio-esp32). On a host behind a strict firewall or with
  no outbound access, those platforms fail at build. The default
  + go + node-extras + c-cpp platforms are apt-only and work
  inside any environment that has Debian repository access. No
  workaround for the curl-/pip-based platforms; the operator
  needs network access at setup time.

- **`docker compose --profile ephemeral build`'s effect on tagged
  images.** `--add-platform` rebuilds `coder-daemon` and `auditor`
  via this command. If the operator has separately tagged the
  pre-rebuild images for any reason, those tags persist; only the
  `:latest` tag is moved. Documented inline in the test code via
  the snapshot/restore mechanism.

- **`pip install platformio` is slow.** The platformio-esp32
  platform's image build takes several minutes longer than other
  platforms because pip downloads platformio and the espressif32
  toolchain (~500MB). Operators who care about setup latency may
  want to commit a pre-warmed image; out of scope for this section.

- **State files vs. running architect.** Setup writes
  `.substrate-state/{platforms,devices}.txt` BEFORE bringing up
  architect, so first-start sees populated files. On subsequent
  re-runs of setup, the state files are rewritten but the architect
  container — if already running — won't pick up the new
  `SUBSTRATE_PLATFORMS` env (compose `up -d` is a no-op when
  config matches). The architect WILL see the updated state files
  on next read, since they're mounted live. This is acceptable —
  the state files are the canonical record, the env vars are
  convenience.

- **Architect-guide paragraph is a request, not enforcement.**
  Nothing in the substrate forces the architect to actually read
  `/substrate/platforms.txt` and update `SHARED-STATE.md`. It's
  on the architect agent to do so per the guide. s010's planned
  full integration would tighten this (the planner would consume
  the state files directly when authoring task briefs).

- **Polyglot install ordering matters.** The renderer emits
  platforms in the order they appear in `--platform=<csv>`. Two
  platforms that both touch `/usr/bin/python3` (e.g. python-extras
  + platformio-esp32) could in principle conflict; in practice
  each uses its own venv path so they coexist. The brief flagged
  no test for ordering; we don't either. New platforms should be
  authored with this in mind.

## Files added or modified (summary)

New:
- `methodology/platforms/{default,go,rust,python-extras,node-extras,c-cpp,platformio-esp32}.yaml`
- `methodology/platforms/README.md`
- `infra/scripts/lib/yaml.sh`
- `infra/scripts/lib/validate-platform.sh`
- `infra/scripts/lib/platform-args.sh`
- `infra/scripts/render-dockerfile.sh`
- `infra/scripts/render-device-override.sh`
- `infra/scripts/add-platform-device.sh`

Modified:
- `infra/coder-daemon/Dockerfile` (sentinel + USER root re-assertion)
- `infra/auditor/Dockerfile` (sentinel)
- `docker-compose.yml` (Dockerfile.generated paths; architect env + mount)
- `setup-common.sh` (renderer/verify/state-file integration; trailing warning)
- `setup-linux.sh` (--platform/--device/--add-platform/--add-device parsing + dispatch)
- `setup-mac.sh` (same)
- `infra/scripts/tests/test-substrate-end-to-end.sh` (8 new phases)
- `methodology/deployment-docker.md` (new §10 Platforms; old §10 → §11)
- `methodology/architect-guide.md` (Substrate platform invariants subsection)
- `README.md` (quickstart --platform examples + paragraph)
- `.gitignore` (Dockerfile.generated, docker-compose.override.yml, .substrate-state/)
- `briefs/s009-platform-plugin/section.brief.md` (the brief itself, copied to canonical path)
