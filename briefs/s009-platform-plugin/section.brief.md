# turtle-core update brief — s009 platform plugin model

## How to read this brief (read first)

This is a **substrate-iteration** brief, not a project-methodology
brief. The deliverable modifies the substrate itself — `methodology/`,
`infra/`, top-level `*.sh`. A single agent works in-tree on the host
clone; no commission of planner / coder / auditor; no use of
`commission-pair.sh` or `audit.sh`. The section structure
(`section/sNNN-slug` branch, `briefs/sNNN-slug/section.brief.md`,
`briefs/sNNN-slug/section.report.md`) is reused for traceability, but
the methodology's role-pipeline is not invoked.

Tell-tale: if your work touches files inside `methodology/`, `infra/`,
or top-level `*.sh`, you're doing substrate-iteration. If it touches a
project's source tree (e.g., `bin/hello`, `test.sh`), it's
project-methodology and goes through the full role pipeline.

## What this is

Follow-up to s008. The substrate now commissions deterministically and
the methodology end-to-end loop has been demonstrated for a Python
toy. Next structural gap: the substrate's role images are
single-toolchain. The current `coder-daemon` image carries node + npm
+ build-essential + python3, baked at image build time, and `auditor`
is even sparser. A project that targets Go, Rust, C/C++, or an
embedded platform needs the toolchain inside both images, and the
choice has to be made by whoever builds the substrate, before any
project work begins.

s009 introduces a **platform plugin model**. Each target platform is
defined by a small YAML file in `methodology/platforms/<name>.yaml`.
At substrate setup, the human selects one or more platforms via
`./setup-linux.sh --platform=<name>` (or `--platform=<a>,<b>` for
polyglot). The setup script renders role Dockerfiles by combining a
static template with the selected platform layers, then builds the
images. SHARED-STATE.md gains a Platform invariant that the architect
records when initializing a project.

The model also covers **runtime device passthrough**, because for
embedded targets (the ESP32 case in particular) the dominant test
methodology is hardware-in-the-loop with serial output capture —
the device runs the test code and reports results back over UART.
Without serial access, the auditor can't run real tests on embedded
firmware (only static analysis), and the coder can't TDD the way
embedded coders actually work. Platform YAMLs declare device
requirements; the setup script accepts `--device=<host-path>` and
wires it into coder-daemon and auditor via Compose's `devices:`
directive. From the substrate's POV, what's behind the host path —
real USB, virtual PTY pointing at a tunneled remote port —
is opaque. The remote-bridge tooling (run a small daemon on a Pi or
Chromebook with the device plugged in, tunnel its serial port to
the VPS where Docker runs) is the **immediate planned next section**
after s009 lands; s009's `--device` mechanism is built in
anticipation of consuming virtual paths from that bridge.

This brief packages the schema (with both build-time toolchain and
runtime device blocks), the seven ship-with platforms, the
setup-script integration, the Dockerfile renderer, the build wiring,
runtime device passthrough, re-platform support on running substrates,
configuration exposure to the architect, test extension, and
documentation as one section, **s009-platform-plugin**.

This is the largest section to date (8 tasks, with device passthrough
threading through several of them). Worth careful brief-reading
before starting.

---

## Recommendations baked in (override before dispatch)

Four design calls. Each flagged below; edit before dispatch to override.

1. **Generated Dockerfiles, not build args.** The setup script
   renders `infra/coder-daemon/Dockerfile.generated` and
   `infra/auditor/Dockerfile.generated` from a static template plus
   the selected platform YAMLs. Generated files are `.gitignore`d.
   Compose builds against the generated files.

   Considered alternative: keep static Dockerfiles with `ARG` build
   args and conditional logic inside. Cleaner from a "what's in git"
   standpoint, but pushes complexity into Dockerfile syntax, which
   is harder to debug and review. The generated approach trades a
   small build artifact for full visibility into what actually got
   built.
   **Override:** specify the ARG-driven Dockerfile if you want a
   single static Dockerfile per role.

2. **Polyglot defaults disabled.** `--platform=go,python-extras` is
   valid (both toolchains land in the role images), but the
   `defaults` block (`test_runner`, `build_command`, `allowed_tools`)
   from each platform is not merged. Architect/planner must specify
   per-task in polyglot mode. Single-platform mode uses the
   defaults as starting points.

   Considered alternative: first-platform-wins. Less magical but
   silently picks one platform's defaults, which can hide
   intent. Or merge if compatible. Disabling defaults in polyglot
   mode is the most explicit and forces the human/architect to
   make the choice deliberately at brief time.
   **Override:** specify first-wins or merge if you'd rather have
   defaults always apply.

3. **`--allowedTools` template model.** The platform's
   `defaults.allowed_tools` is copied by the planner into each task
   brief as a starting point and may be edited per task. Platform is
   a starting-point convenience, not a runtime injection.

   Considered alternatives: *override* (platform's allowlist replaces
   task brief's at runtime — strongest enforcement but trades away
   per-task precision); *augment* (union of platform and task brief —
   silent expansion of the surface, hard to reason about).
   The template model preserves the task-brief-as-source-of-truth
   property the spec already depends on.
   **Override:** specify override or augment if you want runtime
   enforcement of platform tool sets.

4. **`--add-platform` refuses on in-flight work.** When invoked on a
   running substrate, `--add-platform=<name>` checks for: (a) any
   running ephemeral containers (planner / auditor / coder pairs);
   (b) any section branches on origin with un-merged task briefs.
   Refuses with a clear message if either is present, unless
   `--force` is passed.

   Considered alternative: just check (a) — running containers.
   Simpler but lets the human silently change the toolchain
   underneath an in-progress section, invalidating its assumptions.
   The brief-level check is more conservative; `--force` exists for
   operators who know what they're doing.
   **Override:** specify weak check (containers only) if you want
   `--add-platform` to be more permissive.

5. **`device_required: true` warns rather than fails when no
   `--device` is given.** A platform that declares devices required
   (platformio-esp32 in the ship-with set) will warn at setup if no
   `--device` is mapped, but proceeds — the human may legitimately
   want compile-only initially, intending to add the bridge later.
   The warning explains what won't work (HIL test, flash, monitor)
   and how to add a device with `--add-device` (running substrate)
   or by re-running setup with `--device=<path>`.

   Considered alternative: fail hard. Cleaner contract but trips
   over the common "I just want to compile this firmware" workflow
   and forces the operator to either supply a fake device path or
   override the platform.
   **Override:** specify hard-fail if you want strict device
   contract enforcement.

---

## Top-level plan

**Goal.** Substrate selects target platforms at setup time; role
images carry the corresponding toolchain; runtime device passthrough
(`--device=<host-path>`) wires host devices into role containers when
platforms declare device requirements; configuration is exposed to
the architect for inclusion in SHARED-STATE.md; re-platform is
supported on running substrates.

**Scope.** One section, eight tasks. No parallelism — task ordering
is structural (schema before generator before tests).

**Sequencing.** Execute after s008 lands in `main`. (s008 is now
merged at `aa969ed`.)

**Branch.** `section/s009-platform-plugin` off `main`.

---

## Section s009 — platform-plugin

### Section ID and slug

`s009-platform-plugin`

### Objective

Add a platform plugin system to turtle-core. At setup, the human
chooses one or more platforms via `--platform=<name>[,<name2>,...]`.
The substrate renders Dockerfiles per role by composing a static
template with the platform's install layers, builds the images,
wires host devices into role containers when platforms declare
runtime device requirements (via `--device=<host-path>`), exposes
the platform configuration to the architect, and writes the
configuration to a known location for SHARED-STATE.md authoring.
On a running substrate, `--add-platform=<name>` extends the
toolchain in place (refusing if there's in-flight work); when the
new platform requires a device, the human can supply it via
`--add-device=<host-path>`.

### Available context

The current state:

- `infra/coder-daemon/Dockerfile` and `infra/auditor/Dockerfile` are
  static. Both have a `# Project build toolchain — extend HERE for
  downstream projects` comment marking the conventional extension
  point. The renderer can use this as the platform-insert sentinel
  (or replace the comment with an explicit `# PLATFORM_INSERT_HERE`
  marker).
- `setup-common.sh` §5 (the build step) currently runs
  `docker build -t agent-base:latest infra/base` followed by
  `docker compose --profile ephemeral build`. This is the integration
  point for the renderer — it must run before compose build.
- `docker-compose.yml` references the role Dockerfiles by their
  default names (`Dockerfile`). Compose supports `dockerfile:
  Dockerfile.generated` as a per-service override, which is how the
  generated files get picked up.
- Findings 5 / 28 (handover) recommend the auditor's report path be
  `briefs/<section>/audit.report.md` on main; this is independent of
  s009 but the auditor's verify step in the platform YAML
  (cppcheck etc.) supports the auditor's adversarial role.
- Finding 27 (planner image lacks coder toolchain) is **out of
  scope** for s009 — s009 extends `coder-daemon` and `auditor`, not
  `planner`. The architectural question of whether the planner
  should re-execute coder tests is deferred.
- The architect-guide currently does not mention platforms.
  s009 makes a light-touch update; full methodology integration
  (architect-guide reads platform list from `/substrate/platforms.txt`
  when initializing SHARED-STATE.md, etc.) is deferred to a
  follow-up section.
- **Embedded HIL testing is serial-driven.** For ESP32 (and most
  microcontroller targets), the dominant test pattern is: compile
  test firmware, flash to device, device runs the test code and
  reports pass/fail back over UART. esptool talks UART (the on-board
  USB-to-serial chip is just a bridge). PlatformIO's `pio test`
  defaults to hardware-in-the-loop with results captured from the
  serial port. Native tests (`pio test -e native`) are useful for
  pure-logic code but can't validate timing, peripheral interaction,
  or actual device behaviour. So the platformio-esp32 platform
  must provide serial access to be useful at all; the platform
  model has to support runtime device mapping as a first-class
  concern, not as a future enhancement.
- Docker on Linux passes USB devices through with `devices:` entries
  (or `--device` on `docker run`). The agent user inside the
  container needs to be in the `dialout` group to read/write
  `/dev/ttyUSB*`; the role Dockerfiles already create the agent
  user, so the renderer just needs to ensure dialout group
  membership when devices are mapped.
- The remote serial bridge (Pi/Chromebook with the ESP32 plugged
  in, tunneled to the VPS) is the planned next section after s009.
  The bridge produces a virtual serial device on the Docker host;
  s009's `--device` mechanism consumes it transparently. So the
  platform model's contract — "supply a host device path" — is
  forward-compatible with the bridge tooling without changes.

The platforms shipping in s009:

| Platform            | Use case                          | Install method     | Approx size add |
| ------------------- | --------------------------------- | ------------------ | --------------- |
| `default`           | Baseline; current behaviour       | (no platform)      | 0               |
| `go`                | Go projects                       | apt                | ~150MB          |
| `rust`              | Rust projects                     | rustup curl-script | ~400MB          |
| `python-extras`     | Python with uv / poetry / pytest  | apt + pip          | ~100MB          |
| `node-extras`       | Node with pnpm / yarn / typescript | npm globals       | ~50MB           |
| `c-cpp`             | C / C++ with cmake / valgrind     | apt                | ~300MB          |
| `platformio-esp32`  | Embedded ESP32 via PlatformIO     | apt + venv + pip + `pio platform install` | ~500MB |

The `default` platform is implicit when no `--platform` flag is
given. It's a no-op layer — current image content is preserved.

### Tasks (informal decomposition)

The agent may decompose differently, but this is the suggested
ordering. Tasks 9.a through 9.d build the mechanism; 9.e adds the
running-substrate path; 9.f exposes configuration; 9.g tests; 9.h
documents.

**9.a — Platform YAML schema and ship-with platform files.**

Define the schema (in this brief, then inline as a comment at the
top of each platform file, plus a short `methodology/platforms/README.md`).
Required fields: `name`, `description`, `roles`. Optional:
`defaults`. The `roles` block contains entries for `coder-daemon`
and/or `auditor`; each entry has optional `apt`, `install`, `env`,
`verify`. Schema:

```yaml
name: <slug>           # required, must match filename (without .yaml)
description: <string>  # required
roles:                 # required, at least one role entry
  coder-daemon:        # optional
    apt: [<pkg>...]    # optional, list of apt packages
    install: [<cmd>...] # optional, list of shell commands
    env:               # optional, map of env vars
      <NAME>: <value>  # values may include ${EXISTING_VAR}
    verify: [<cmd>...] # optional, list of verification commands
  auditor:             # optional, same structure as coder-daemon
runtime:               # optional, present iff platform needs runtime config
  device_required: <bool>  # if true, --device should be supplied at setup
  device_hint: <string>    # human-readable description of expected device
  groups: [<grp>...]       # supplementary groups for the agent user
                           # (e.g., 'dialout' for serial)
defaults:              # optional, used in single-platform mode only
  test_runner: <string>
  build_command: <string>
  allowed_tools: [<tool>...]
```

Implementation notes for the schema:

- `apt` commands run under `USER root` in the rendered Dockerfile
  with the standard `apt-get update && apt-get install -y
  --no-install-recommends ... && rm -rf /var/lib/apt/lists/*`
  pattern. The renderer wraps the package list, not the operator.
- `install` commands run under `USER agent` (the non-root user).
  These typically pull from the network or run language-specific
  installers (rustup, npm globals, pip, cargo install, etc.).
- `env` entries become `ENV` instructions in the Dockerfile.
  Values containing `${VAR}` are passed through verbatim — Docker
  resolves them at image-build time against the existing layer's
  ENV. Document this clearly in the schema comment so platform
  authors know `${PATH}` means "the existing PATH at this point in
  the build."
- `verify` commands run twice: once at the end of the Dockerfile
  build (build-time check; if any verify fails, the image build
  fails with a clear diagnostic), and once at setup completion via
  `docker compose run --rm <role> bash -c '<cmd>'` (setup-time
  check; gives the human a green tick).
- `runtime.device_required` is consumed at setup-arg-parse time
  (warning if `--device` is absent) and at compose-up time (the
  warning is repeated alongside an "as configured, HIL workflows
  unavailable" note). It does NOT affect the Dockerfile.
- `runtime.groups` is consumed by the renderer: the role Dockerfile
  gets a `RUN usermod -a -G <grp1>,<grp2> agent` line under the
  USER root section. For platformio-esp32, this is `[dialout]` —
  the agent user needs dialout to read/write `/dev/ttyUSB*` when
  it's passed in.

Write a small validator: `infra/scripts/lib/validate-platform.sh`
(bash + `yq`) or `infra/scripts/lib/validate-platform.py` (Python +
PyYAML — already available in agent-base). Validates structure on
every setup invocation. Fails fast with a clear error if a YAML is
malformed or references an unknown platform name.

Write the seven platform YAMLs: `default.yaml`, `go.yaml`,
`rust.yaml`, `python-extras.yaml`, `node-extras.yaml`, `c-cpp.yaml`,
`platformio-esp32.yaml`. Place under `methodology/platforms/`. The
`default.yaml` is essentially an empty roles block — it documents
itself but adds no layers.

Reference YAMLs (sketches; finalize during implementation):

```yaml
# go.yaml
name: go
description: Go 1.22+ via apt
roles:
  coder-daemon:
    apt: [golang-go]
    verify: ["go version"]
  auditor:
    apt: [golang-go]
    verify: ["go version"]
defaults:
  test_runner: "go test ./..."
  build_command: "go build ./..."
  allowed_tools: [Bash, Read, Write, Edit]
```

```yaml
# platformio-esp32.yaml
name: platformio-esp32
description: PlatformIO with ESP32 (espressif32) toolchain (~500MB toolchain). Serial-port HIL testing — supply the ESP32 board via --device.
roles:
  coder-daemon:
    apt: [python3-venv, python3-pip]
    install:
      - "python3 -m venv /home/agent/.platformio-venv"
      - "/home/agent/.platformio-venv/bin/pip install platformio"
      - "/home/agent/.platformio-venv/bin/pio platform install espressif32"
    env:
      PATH: "/home/agent/.platformio-venv/bin:${PATH}"
    verify:
      - "pio --version"
      - "pio platform show espressif32 | head -1"
  auditor:
    apt: [python3-venv, python3-pip, cppcheck]
    install:
      - "python3 -m venv /home/agent/.platformio-venv"
      - "/home/agent/.platformio-venv/bin/pip install platformio"
      - "/home/agent/.platformio-venv/bin/pio platform install espressif32"
    env:
      PATH: "/home/agent/.platformio-venv/bin:${PATH}"
    verify:
      - "pio --version"
      - "cppcheck --version"
runtime:
  device_required: true
  device_hint: "ESP32 board on /dev/ttyUSB* or /dev/ttyACM*"
  groups: [dialout]
defaults:
  test_runner: "pio test"
  build_command: "pio run"
  allowed_tools: [Bash, Read, Write, Edit]
```

The other platforms follow the same shape; rust uses the rustup
curl-script in `install`, c-cpp is apt-only, etc.

**9.b — Setup-script `--platform` and `--device` argument parsing.**

Modify `setup-common.sh` (and the entrypoints `setup-linux.sh`,
`setup-mac.sh` if they parse args before delegating; check) to
accept:

- `--platform=<name>` and `--platform=<name1>,<name2>,...`
- `--device=<host-path>` and `--device=<host-path1>,<host-path2>,...`

Parsing rules for `--platform`:

- Multiple `--platform` flags concatenate (`--platform=go
  --platform=python-extras` is equivalent to
  `--platform=go,python-extras`).
- Empty/absent → `default`.
- `default` is implicit and may also be combined explicitly
  (`--platform=default,go` ≡ `--platform=go`).
- Each named platform must have a valid YAML at
  `methodology/platforms/<name>.yaml`. Validator runs on each.
- Final list exported as `SUBSTRATE_PLATFORMS` (comma-separated).

Parsing rules for `--device`:

- Multiple `--device` flags concatenate similarly.
- Each value must be an existing path on the host at parse time
  (validate with `test -e`); if absent, fail fast with the missing
  path named.
- Final list exported as `SUBSTRATE_DEVICES` (comma-separated).
- After parsing, cross-check: for each platform with
  `runtime.device_required: true`, if `SUBSTRATE_DEVICES` is
  empty, emit a warning naming the platform and its
  `device_hint`. Setup proceeds (per design call 5).

Document both flags in `--help` / usage. Update existing flag
descriptions (`--adopt-existing-substrate`, `--install-docker`) to
include the new flags.

**9.c — Dockerfile generator.**

New script: `infra/scripts/render-dockerfile.sh`. Inputs (env or
args): role name (`coder-daemon` | `auditor`), platform list
(comma-separated). Output: writes
`infra/<role>/Dockerfile.generated`.

Algorithm:

1. Read the static template `infra/<role>/Dockerfile`. Find the
   sentinel `# PLATFORM_INSERT_HERE` (or the existing extension-point
   comment, which 9.c replaces with the sentinel). The template has
   a head (everything before the sentinel) and a tail (everything
   after).
2. For each platform in order, parse its YAML's `roles.<role>`
   block. Generate a Dockerfile snippet:

   ```dockerfile
   # ---- Platform: <name> (<role>) ----
   USER root
   RUN apt-get update && apt-get install -y --no-install-recommends \
           <pkg1> <pkg2> ... \
       && rm -rf /var/lib/apt/lists/*
   USER agent
   RUN <install-cmd1> \
    && <install-cmd2> \
    && ...
   ENV <K1>=<V1>
   ENV <K2>=<V2>
   RUN <verify-cmd1> \
    && <verify-cmd2> \
    && ...
   ```

   Skip blocks that the platform doesn't define (no apt → no apt
   block; no install → no install block; etc.). If the role isn't
   present in the platform's `roles` (e.g., `default` has no
   roles), produce no snippet for that platform.

3. Concatenate: head + all snippets in order + tail.

4. Write to `infra/<role>/Dockerfile.generated`. Mark the file
   read-only and add a header comment: "GENERATED by
   `render-dockerfile.sh`. Do not edit; regenerate via setup."

5. Add `infra/*/Dockerfile.generated` to `.gitignore`.

The renderer must handle the user-switching cleanly: each platform
block ends with `USER agent` (so the next block starts in a
predictable state). The final state at end of insert is `USER
agent` regardless of how many platforms were inserted.

If `runtime.groups` is present in any selected platform, the
renderer emits an early `USER root` block (before the platform
loop) with `RUN usermod -a -G <comma-grps> agent`. Multiple
platforms requesting groups have their groups merged.

The `runtime.device_required` and `runtime.device_hint` fields do
**not** affect the Dockerfile output — they're consumed at setup
arg-parse time (warning) and at compose wiring time (devices: in
docker-compose). The renderer ignores them.

If no platforms have a role-specific block (all are `default` or
roles-less), the generated file is byte-identical to the static
template (with the sentinel removed). This preserves the current
behaviour for `--platform=default`.

**9.d — Compose wiring + setup integration.**

Update `docker-compose.yml`: change the `coder-daemon` and
`auditor` build sections to point at the generated file, and add
device passthrough:

```yaml
services:
  coder-daemon:
    build:
      context: ./infra/coder-daemon
      dockerfile: Dockerfile.generated
    devices:
      ${COMPOSE_DEVICE_LIST:-}
  auditor:
    build:
      context: ./infra/auditor
      dockerfile: Dockerfile.generated
    devices:
      ${COMPOSE_DEVICE_LIST:-}
```

Compose's `devices:` syntax accepts a list of strings like
`/dev/ttyUSB0:/dev/ttyUSB0` (or just `/dev/ttyUSB0` for
same-path mapping). Since the list is dynamic, setup-common.sh
generates a `.env`-style file consumed by Compose, or uses an
override file (`docker-compose.devices.yml` rendered at setup time
and included via `-f`). Pick whichever is cleanest with current
Compose version constraints. If using the override-file approach,
the override is generated under `infra/` and gitignored.

Update `setup-common.sh` §5 (the build step) to call the renderer
before compose build, and emit any device wiring:

```bash
log "Rendering Dockerfiles for platforms: $SUBSTRATE_PLATFORMS..."
infra/scripts/render-dockerfile.sh coder-daemon "$SUBSTRATE_PLATFORMS"
infra/scripts/render-dockerfile.sh auditor "$SUBSTRATE_PLATFORMS"

log "Building agent-base image..."
docker build -t agent-base:latest "${repo_root}/infra/base"

log "Building role images via docker compose..."
docker compose --profile ephemeral build

if [ -n "${SUBSTRATE_DEVICES:-}" ]; then
    log "Wiring devices into role compose: $SUBSTRATE_DEVICES..."
    infra/scripts/render-device-override.sh "$SUBSTRATE_DEVICES"
fi
```

After compose build succeeds, run setup-time verify per platform
per role:

```bash
log "Verifying platform toolchains..."
for platform in ${SUBSTRATE_PLATFORMS//,/ }; do
    for role in coder-daemon auditor; do
        # invoke each verify command in a one-shot container
        # accumulate failures; report them as a single block at end
    done
done
```

Setup fails (non-zero exit) if any verify fails. The user sees
which platform/role/command failed.

Cross-check at the end: for each selected platform with
`runtime.device_required: true`, if no devices are mapped, emit
the warning a second time so it's the last thing the human sees
before setup completes — easy to miss in scrollback otherwise.

**9.e — `--add-platform` and `--add-device` on running substrate.**

Add `--add-platform=<name>` and `--add-device=<host-path>` to
`setup-linux.sh` (and -mac). Behaviour for `--add-platform`:

1. Validate `<name>` (YAML exists, schema valid).
2. Pre-flight checks:
   - **(a)** Running ephemeral containers: `docker compose ps -q
     planner auditor coder-daemon` (or scan for any
     `turtle-core-*-{planner,auditor,coder-daemon}-*` containers
     across compose projects). If any are running, refuse with a
     message naming them.
   - **(b)** Section branches with un-merged work: `git ls-remote
     origin 'refs/heads/section/*'` and check whether each section
     branch has commits ahead of main. Conservative heuristic: if
     any section/* branch has commits not on main, refuse.
   - `--force` skips both.
3. Read the current `SUBSTRATE_PLATFORMS` (from a substrate-state
   file written at setup; see 9.f). New value =
   `<existing>,<name>`.
4. Re-render Dockerfiles for both roles with the new list.
5. Rebuild affected role images: `docker compose --profile
   ephemeral build coder-daemon auditor` (the architect and
   git-server are unaffected).
6. Run setup-time verify for the new platform.
7. If the new platform has `runtime.device_required: true` and no
   matching device is currently mapped, emit the warning (per
   design call 5) and suggest `--add-device=<path>`.
8. Update the substrate-state file to the new platform list.
9. Print a hint: "SHARED-STATE.md should be updated by the
   architect to record the new platform invariant."

Behaviour for `--add-device`:

1. Validate the path exists on the host.
2. Pre-flight check (a) only — running containers. (Adding a
   device doesn't invalidate in-progress sections; the device
   simply becomes available to subsequent commissions.)
3. Append to the substrate-state device list.
4. Regenerate the device override file (or .env) so subsequent
   `docker compose run` invocations pick up the new device.
5. No image rebuild required — devices are runtime, not build-time.

`--add-platform` and `--add-device` may be combined in one
invocation (e.g., `--add-platform=platformio-esp32
--add-device=/dev/ttyUSB0`). They run in order: platform first
(triggers rebuild), device second (no rebuild).

If any pre-flight fails, exit non-zero with diagnostic. If verify
fails post-rebuild, exit non-zero — but state is now in an
inconsistent state (images built for new platform list, state
file still old). Document the recovery path: re-run with the same
flags after fixing the underlying cause.

**9.f — Expose platform configuration to the architect.**

Two surfaces (substrate-side; architect-side reading is mostly
deferred to s010):

1. **Environment variables.** The architect container receives:
   - `SUBSTRATE_PLATFORMS=<comma-list>`
   - `SUBSTRATE_DEVICES=<comma-list>` (may be empty)

   Update `docker-compose.yml` architect service to inherit
   both from the host environment.

2. **State files.** Setup writes:
   - `/var/turtle-core-state/platforms.txt` (host) →
     mounted into the architect container at
     `/substrate/platforms.txt` (read-only). One platform name
     per line.
   - `/var/turtle-core-state/devices.txt` (host) →
     `/substrate/devices.txt` (read-only). One host device path
     per line.

   These are the durable record across substrate restarts.

Update `architect-guide.md` with a single short paragraph (light
touch — full integration is s010):

> When initializing or updating SHARED-STATE.md, read
> `/substrate/platforms.txt` and `/substrate/devices.txt`. Each line
> in `platforms.txt` is the name of a target platform configured at
> substrate setup; record each as a Project-wide decision in
> SHARED-STATE.md with the heading "Target platform" (single) or
> "Target platforms" (multiple, polyglot mode). Each line in
> `devices.txt` is a host device path that has been mapped through to
> the role containers; record these under "Hardware-in-the-loop
> devices" if any platform's testing depends on them. If
> `/substrate/platforms.txt` is absent, the substrate is on `default`
> only.

Resist temptation to do more here. The full architect/planner/
auditor integration (reading `defaults.test_runner` from platform
YAMLs, propagating into briefs, etc.) is the s010 scope.

**9.g — Test extension.**

Add to `infra/scripts/tests/test-substrate-end-to-end.sh` the
following phases (numbering continues from s008's Phase 8):

- **Phase 9 — single-platform setup.** Scaffold a scratch
  substrate with `--platform=go`. Assert: (i) `go version` runs
  in the coder-daemon image; (ii) `go version` runs in the
  auditor image; (iii) `SUBSTRATE_PLATFORMS=go` in architect
  env; (iv) `/substrate/platforms.txt` in architect contains
  `go`.
- **Phase 10 — polyglot setup.** Scaffold scratch substrate with
  `--platform=go,python-extras`. Assert both toolchains present
  in both role images; state file contains both names.
- **Phase 11 — `--add-platform` happy path.** Start at
  `--platform=go`; with no commissions running and no section
  branches, run `--add-platform=python-extras`. Assert
  `python-extras` toolchain now present; state file updated.
- **Phase 12 — `--add-platform` refusal: running container.**
  Start at `--platform=go`; bring up a stub planner. Run
  `--add-platform=python-extras`. Assert non-zero exit and an
  error message naming the running planner. State file
  unchanged.
- **Phase 13 — `--add-platform` refusal: pending section.**
  Start at `--platform=go`; create a section branch with
  un-merged commits. Run `--add-platform=python-extras`. Assert
  non-zero exit and an error naming the section branch. State
  file unchanged.
- **Phase 14 — device passthrough wiring.** Scaffold scratch
  substrate with `--platform=platformio-esp32
  --device=/dev/null` (using `/dev/null` as a stand-in for
  hardware that's safe in CI). Assert: (i) `/dev/null` is
  listed in `/substrate/devices.txt`; (ii) `SUBSTRATE_DEVICES`
  env present in architect; (iii) the compose
  override file (or .env) contains the device entry; (iv) when
  a coder-daemon is brought up via `docker compose run --rm
  coder-daemon ls -la /dev/null`, the device is visible (test
  proves the wiring works without depending on real hardware).
  Note that platformio-esp32's verify steps must succeed
  during setup — this exercises the toolchain-build pathway too.
- **Phase 15 — device_required warning.** Scaffold scratch
  substrate with `--platform=platformio-esp32` (no `--device`).
  Assert: (i) setup exits 0 (warning, not failure, per design
  call 5); (ii) stderr or log contains the device-required
  warning naming `platformio-esp32` and the device hint; (iii)
  `/substrate/devices.txt` is empty.
- **Phase 16 — `--add-device` happy path.** Start at
  `--platform=platformio-esp32` (no device). Run
  `--add-device=/dev/null`. Assert: state file updated; no
  rebuild triggered (timestamp on coder-daemon image
  unchanged); subsequent `docker compose run` sees the device.

Each phase scaffolds and tears down its own scratch substrate
(matching s007's pattern). Image rebuild is mandatory for
phases 9–14; document this in the test header. Setup time per
phase will be longer than prior phases.

Phase 14's choice of `/dev/null` deserves a comment: real ESP32
hardware can't be assumed in CI, but the wiring path
(arg-parse → state-file → compose-override → container-visible)
can be exercised against any host device. `/dev/null` always
exists, doesn't grant any meaningful access, and proves the
mechanism works. Real-hardware verification happens out-of-band
when the operator has a board connected.

**9.h — Documentation.**

Update:

- `methodology/deployment-docker.md` — new §10 "Platforms":
  describes the model, the seven ship-with platforms, the
  `--platform`, `--device`, `--add-platform`, and `--add-device`
  flags, the YAML schema (including the `runtime` block), the
  warning behaviour for `device_required`, and the SHARED-STATE.md
  propagation expectation. References
  `methodology/platforms/README.md` for the platform catalog.
  Includes a short subsection noting that remote serial bridging
  (Pi/Chromebook with USB attached, tunneled to VPS Docker host)
  is the planned next section, and `--device` is forward-compatible
  with virtual paths the bridge will produce.
- `methodology/platforms/README.md` — new file. Brief
  per-platform descriptions, the schema reference (build-time
  toolchain block + runtime device block), instructions for
  adding a new platform.
- `README.md` quickstart: add a platform-selection note to the
  setup step. One sentence at the right place. Mention `--device`
  for embedded.
- `architect-guide.md` — the single short paragraph from 9.f
  (covering both platforms.txt and devices.txt).
- Inline comment headers in `render-dockerfile.sh`,
  `render-device-override.sh` (or equivalent),
  `validate-platform.sh`, and the modified setup scripts.

### Constraints

- **`default` platform must remain functionally identical to
  pre-s009 behaviour.** A `--platform=default` (or no flag) build
  must produce role images byte-equivalent (or as close as the
  renderer mechanics allow) to the current static-Dockerfile
  build. Any divergence is a regression.
- **`coder-daemon` and `auditor` only.** This section does not
  modify the `architect`, `coder-daemon`'s daemon code, the
  `git-server`, or any role entrypoints. Finding 27 (planner
  toolchain) is explicitly out of scope.
- **Device passthrough is integral, not optional.** For platforms
  that declare `runtime.device_required: true`, the `--device`
  flag must be wired through to the role containers when supplied.
  The platform model is incomplete without it for embedded targets.
- **Methodology docs minimal change.** Architect-guide gets one
  paragraph. Spec, planner-guide, auditor-guide are untouched.
  Full methodology integration is s010.
- **No project-methodology run required during this section.**
  This is substrate-iteration. The agent does not commission
  planner/coder/auditor pairs; it modifies files directly.
- **Generated files are .gitignored.** `Dockerfile.generated`
  and any device-override file must not be committed.
- **YAML format only.** No alternate config format. Platform
  files are YAML, parsed by `yq` (preferred, already a
  reasonable dependency) or PyYAML. Validator failure is a
  setup-blocking error.
- **Build-time verify failures abort the build.** Setup-time
  verify failures abort setup. Both must produce a clear
  diagnostic identifying platform / role / command.
- **`/dev/null` as test stand-in is acceptable.** Real-hardware
  device tests are out-of-band; CI verifies the wiring path
  with a benign device.

### Definition of done

- `methodology/platforms/{default,go,rust,python-extras,
  node-extras,c-cpp,platformio-esp32}.yaml` written and validate.
  `platformio-esp32.yaml` includes the `runtime` block.
- `infra/scripts/render-dockerfile.sh` produces correct
  `Dockerfile.generated` for any combination of platforms,
  including `runtime.groups` handling.
- `infra/scripts/render-device-override.sh` (or equivalent
  mechanism) wires devices into Compose at setup and re-renders
  on `--add-device`.
- `infra/scripts/lib/validate-platform.sh` (or .py) validates
  schema and is called from setup.
- `setup-linux.sh` / `setup-mac.sh` / `setup-common.sh` accept
  `--platform=<name>[,<name2>,...]`, `--device=<host-path>[,<...>]`,
  `--add-platform=<name>`, and `--add-device=<host-path>`.
- `docker-compose.yml` updated to use `Dockerfile.generated` and
  to pick up device entries from the override file (or .env).
- Architect container receives `SUBSTRATE_PLATFORMS` and
  `SUBSTRATE_DEVICES` env, and has both `/substrate/platforms.txt`
  and `/substrate/devices.txt` mounted.
- Substrate end-to-end test extended with phases 9–16;
  passes 39/39 (assuming s008's 31 + 8 new).
- Setup with `--platform=default` (or no flag) produces a
  substrate that's functionally identical to pre-s009.
- Setup with `--platform=go` produces a substrate where
  `go version` runs inside both `coder-daemon` and `auditor`.
- Setup with `--platform=platformio-esp32 --device=/dev/null`
  succeeds, exposes `/dev/null` to coder-daemon and auditor,
  and lists it in `/substrate/devices.txt`.
- Setup with `--platform=platformio-esp32` (no device) succeeds
  with a warning naming the missing device.
- `--add-platform` on running substrate works in the happy path
  and refuses cleanly in both refusal scenarios.
- `--add-device` on running substrate works without rebuild.
- `methodology/deployment-docker.md` has §10 (including the
  remote-bridge forward reference). README quickstart updated.
  Architect-guide has the platform paragraph (covering both
  platforms.txt and devices.txt).
  `methodology/platforms/README.md` exists.
- Section report at
  `briefs/s009-platform-plugin/section.report.md` including:
  brief echo, per-task summary, the rendered
  `Dockerfile.generated` for `--platform=go,python-extras` and
  `--platform=platformio-esp32` (illustrative — both roles,
  captured verbatim), the rendered device-override file (or .env)
  for `--device=/dev/null`, the test transcript, the state of all
  five design calls (whether they were kept or overridden),
  residual hazards.

### Out of scope

- **Remote serial bridge.** The mechanism for running a small
  daemon on a Pi/Orange Pi/Chromebook with a USB device attached,
  tunneling its serial port to the VPS where Docker runs, and
  presenting a virtual `/dev/tty*` device to the substrate. This
  is the **planned next section** after s009 lands. s009's
  `--device` mechanism is built to consume virtual paths from
  that bridge transparently.
- Full methodology integration (architect-guide, planner-guide,
  auditor-guide updated to read platform defaults and propagate
  into task briefs). That's the section after the bridge (or
  before — Jonathan's call on ordering).
- The `methodology/substrate-iteration.md` standing document
  (Finding 32). Candidate for a later substrate-iteration section.
- Codifying the audit-report-on-main convention
  (Findings 5/28). Future small section.
- Extending `planner` image with a coder toolchain (Finding 27).
  Future section if pursued.
- Additional platforms beyond the seven listed. New platforms
  are added by writing a YAML; that path is open.
- Per-task platform overrides (a task brief specifying a
  different toolchain than the substrate). Out of scope; revisit
  if the use case emerges.
- Real ESP32 hardware in CI tests. Phase 14 uses `/dev/null` as
  a stand-in to exercise the wiring path; real-hardware
  verification happens out-of-band.

### Repo coordinates

- Base branch: `main` (at s008 merge `aa969ed` or later).
- Section branch: `section/s009-platform-plugin`.
- Commits per task (matching s008 convention; the 8.d/8.e
  combined-commit precedent is fine for tightly-coupled tasks
  here too).

### Reporting requirements

Section report at `briefs/s009-platform-plugin/section.report.md`
on the section branch. Must include:

- Brief echo.
- Per-task summary with commit hashes.
- The full rendered `Dockerfile.generated` for both
  `coder-daemon` and `auditor` under
  `--platform=go,python-extras` and under
  `--platform=platformio-esp32` — these become the canonical
  reference for how platform layers compose, with and without
  the `runtime.groups` extension.
- The full rendered device override file (or .env contents) for
  `--device=/dev/null,/dev/zero` — illustrates the device
  wiring shape.
- The validator's behaviour on a deliberately-malformed YAML
  (a one-shot test result is sufficient).
- Test transcript from phases 9–16.
- Resolution of each of the five design calls (kept as written,
  or overridden — and how).
- Any residual hazards.

---

## Execution

Single agent on the host, working in the `turtle-core` clone
directly. Same pattern as s007, s008. Work through 9.a–9.h in
order, committing per task (or per tightly-coupled task pair,
e.g., the renderer + compose-wiring may make sense as one
commit if they're inseparable in practice). After 9.a, the
schema and reference YAMLs become the spec for everything
downstream — pause briefly if there's ambiguity, since 9.b
through 9.h all depend on these being right.

If genuine brief-insufficient ambiguity surfaces, discharge with
a "brief insufficient" report. Same discipline as s007/s008.

This section is large. The image rebuilds in the test (phases
9–13) will be slow; expect the test suite to take significantly
longer than s008's 31-test pass. That's expected; document
runtime in the section report.
