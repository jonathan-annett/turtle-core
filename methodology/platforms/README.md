# Platform plugins

A platform is a small YAML file that tells the substrate's setup
machinery what extra toolchain to install into the **coder-daemon** and
**auditor** images at build time, plus optional declarations about
runtime device passthrough (for hardware-in-the-loop targets like
ESP32). One human-selected platform (or several, comma-separated)
becomes part of the substrate's identity for as long as it lives.

The mechanism is described in detail in
`methodology/deployment-docker.md` §10. This README is the schema
reference plus the ship-with platform catalog.

## Selecting a platform

```bash
./setup-linux.sh --platform=go
./setup-linux.sh --platform=go,python-extras
./setup-linux.sh --platform=platformio-esp32 --device=/dev/ttyUSB0
```

`--platform` may be repeated; values from multiple flags concatenate.
Absent or empty → `default` (no extra toolchain).

On a running substrate:

```bash
./setup-linux.sh --add-platform=rust
./setup-linux.sh --add-device=/dev/ttyUSB0
```

`--add-platform` refuses by default if any ephemeral container is
running OR any `section/*` branch on origin has un-merged commits;
override with `--force` if you know what you are doing.

## Schema

Each YAML lives at `methodology/platforms/<name>.yaml` where `<name>`
matches the YAML's `name` field exactly.

```yaml
name: <slug>           # required; must match the filename without .yaml
description: <string>  # required; one-line human description
roles:                 # required; map. May be empty ({}) for a no-op platform.
  coder-daemon:        # optional; same shape as auditor
    apt: [<pkg>...]    # optional; apt packages installed under USER root
                       # using the standard cache-cleaning pattern
    install: [<cmd>...] # optional; shell commands run under USER agent.
                        # Typical use: language installers (rustup, npm
                        # globals, pip into a venv).
    env:               # optional; ENV instructions emitted into the
      <NAME>: <value>  # Dockerfile. Values may include ${VAR} which
                       # Docker resolves against the existing layer ENV.
                       # Common idiom: PATH: "/new/bin:${PATH}"
    verify: [<cmd>...] # optional; commands run twice — at the end of
                       # the image build (build-time check; failure
                       # aborts the build) and once at the end of setup
                       # via `docker compose run --rm <role>` (setup-time
                       # green-tick).
  auditor:             # optional; same structure as coder-daemon

runtime:               # optional; present iff the platform needs runtime config
  device_required: <bool>   # if true, setup warns when --device is absent
  device_hint: <string>     # human-readable description of expected device
  groups: [<grp>...]        # supplementary groups for the agent user.
                            # Example: ['dialout'] so the agent can read
                            # /dev/ttyUSB* when a serial device is mapped.

defaults:              # optional; consumed by the architect/planner only
  test_runner: <string>          # in single-platform mode (per design call 2,
  build_command: <string>        # in polyglot mode the defaults are ignored
  allowed_tools: [<tool>...]     # and the human/architect must specify
                                  # per-task at brief time).
```

### Field semantics

- `apt` runs as `USER root` in the rendered Dockerfile, wrapped in
  `apt-get update && apt-get install -y --no-install-recommends ... &&
  rm -rf /var/lib/apt/lists/*`.
- `install` runs as `USER agent`. Each list entry becomes a command in
  a single `RUN` block joined with `&&`.
- `env` becomes a sequence of `ENV K=V` instructions. `${VAR}` in the
  value is resolved by Docker at build time against the existing
  layer's ENV.
- `verify` is run twice: at image-build time (failure aborts the
  build) and at setup-time via `docker compose run --rm <role>`
  (failure aborts setup). Each entry is one command.
- `runtime.groups` causes the renderer to emit an early
  `RUN usermod -a -G <grp1>,<grp2>... agent` block under `USER root`,
  so the agent user gains the supplementary group at image build time.
  Multiple platforms requesting groups have their groups merged.
- `runtime.device_required` and `runtime.device_hint` do not affect
  the Dockerfile. They are consumed at setup arg-parse time (warning
  if `--device` is absent) and at compose-up time (warning repeated).
- `defaults` is a starting-point convenience for the
  architect/planner: the planner copies `allowed_tools` into each
  task brief as a starting allowlist, the architect references
  `test_runner` / `build_command` when authoring tasks. Per design
  call 3, defaults are template only — they are not enforced at
  runtime, and per design call 2 they are ignored entirely in
  polyglot mode.

## Ship-with platforms

| Platform              | Use case                                | Approx size add |
| --------------------- | --------------------------------------- | --------------- |
| `default`             | Baseline; current behaviour             | 0               |
| `go`                  | Go projects                             | ~150MB          |
| `rust`                | Rust projects                           | ~400MB          |
| `python-extras`       | Python with uv / poetry / pytest        | ~100MB          |
| `node-extras`         | Node with pnpm / yarn / typescript      | ~50MB           |
| `c-cpp`               | C / C++ with cmake / valgrind / gdb     | ~300MB          |
| `platformio-esp32`    | Embedded ESP32 via PlatformIO; HIL serial | ~500MB        |

## Adding a new platform

1. Author `methodology/platforms/<name>.yaml` matching the schema
   above. The `name:` field MUST match the filename.
2. Re-run setup (or `--add-platform=<name>` on a running substrate)
   with `--platform=<name>` to render and build.
3. The validator runs at every setup invocation; fix any errors it
   reports before the renderer touches a Dockerfile.
4. If the platform needs hardware passthrough, add a `runtime:`
   block with `device_required: true` and `device_hint: <description>`
   and (if the device sits on a Linux device-node group like
   `dialout`) the relevant `groups:` list.

## Validation

`infra/scripts/lib/validate-platform.sh` is invoked from setup before
the renderer runs. It checks:

- File parses as YAML.
- `name` and `description` are present and non-empty.
- `name` matches the filename (less the `.yaml` extension).
- `roles` is a map; each present role is one of `coder-daemon` or
  `auditor`; each role's `apt`/`install`/`verify` (if present) are
  lists of strings; `env` (if present) is a string→string map.
- `runtime` (if present): `device_required` is a bool;
  `device_hint` is a string; `groups` is a list of strings.
- `defaults` (if present): `test_runner`/`build_command` are
  strings; `allowed_tools` is a list of strings.

A validation failure aborts setup with a clear diagnostic identifying
the file and the failing field.
