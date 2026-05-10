# turtle-core update brief — s010 remote host integration

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

Follow-up to s009. The substrate now selects build-time platforms and
runtime devices at setup, with `--device=<host-path>` providing
hardware-in-the-loop (HIL) access to local USB devices. s009's
out-of-scope statement nominated a "remote serial bridge" as the
**immediate next section**: a Pi/Orange Pi/Chromebook with the
embedded board attached, tunnelling its serial port to the Docker
host so the substrate could consume it via `--device=`.

s010 ships a **broader and operationally simpler** mechanism than the
serial-bridge framing: **remote-host integration**. The substrate
registers one or more named remote hosts; each gets per-host SSH
credentials and known-hosts entries; role containers receive the
credentials at start time; an SSH config inside each container maps
the registered name to the right key. Once registered, an agent in
any role container can `ssh tdongle-pi 'esptool ...'` (or any other
command) without further configuration.

Embedded HIL falls out as the canonical use case: instead of bridging
a serial port up to the Docker host and pretending a remote device is
local, the agent SSH's to the device-host and runs `esptool` /
`pio` / `cat /dev/ttyACM0` *there* — where USB is local and "just
works" the way it always does. The trade-off is honest: the substrate
no longer pretends remote devices are local (s009's `--device=` still
serves locally-attached devices), but the operational surface is
dramatically smaller — no ser2net, no socat-PTY, no kernel-level
plumbing, no risk of USB-CDC control-line semantics getting mangled
across a TCP-bridged serial channel. Each piece is a known
single-purpose tool (SSH, scp, esptool); failure modes are crisp.

The capability is general beyond embedded HIL: cross-arch builds (a Pi
is ARM, useful for testing ARM-targeted projects from an x86_64 host),
GPIO/sensor work, "test needs a second box" scenarios, ad-hoc
remote-execution. The section ships embedded HIL as a worked example
in the docs but doesn't prescribe it as the only path.

**Trust posture is explicit.** A registered remote host is *given* to
the agent. The substrate generates an SSH key and installs it on the
target; the user grants the agent whatever privileges that target's
account has (in the typical case, passwordless sudo). The substrate
does not impose command filtering or a constrained API — agents have
shell access. Operators who want a tighter posture wrap their own
constraints around the registration; that's out of scope. The README
documents this clearly.

This brief packages the schema, argument parsing, bootstrap
automation, container wiring, runtime addition, end-to-end testing,
and documentation as one section, **s010-remote-host-integration**.

Smaller than s009 (seven tasks vs eight, simpler per-task surface).

---

## Recommendations baked in (override before dispatch)

Five design calls. Each flagged below; edit before dispatch to override.

1. **Bootstrap uses the user's existing SSH credentials.** When
   `--remote-host=<name>=<user>@<host>` is supplied, setup invokes
   `bootstrap-remote-host.sh`, which uses the operator's already-loaded
   SSH agent or `~/.ssh/id_*` to SSH to the target as `<user>` and
   install the substrate's freshly-generated public key into that
   user's `~/.ssh/authorized_keys`. The operator's credentials are
   used once; the substrate's own keys are used thereafter. The
   prerequisite is a one-liner in the README: "passwordless SSH+sudo
   from your shell to the target before registering it."

   Considered alternatives: (a) interactive password prompt at
   register time (forces operator-presence at every registration,
   awkward for re-runs); (b) out-of-band key install where the user
   manually copies the substrate's public key (cleanest in
   theory but kills automation — every registration has a manual
   step); (c) fully unattended bootstrap with no prior credentials
   (chicken-and-egg, not solvable without a side channel).
   **Override:** specify (a) if you want a uniform interactive
   bootstrap regardless of agent state, or (b) if your security
   posture forbids the substrate touching `authorized_keys`.

2. **No speculative tool installation on the remote.** Setup verifies
   only that SSH works, sudo works non-interactively, and `python3`
   is available (a near-universal baseline; needed by esptool and
   most other agent-relevant tools). The substrate does not pre-install
   esptool, pio, picocom, etc. The agent installs whatever a task
   needs at the moment of need
   (`ssh tdongle-pi 'pip install --user esptool'`).

   Considered alternative: a `tools:` block in the registration
   spec listing apt/pip packages to install on register. More
   reproducible but couples remote-host setup to the eventual use
   case; also re-imposes a "what should be installed" question the
   substrate has been deliberately deferring to the agent since s009.
   **Override:** specify the spec-with-tools form if you want
   register-time tool install for CI-time predictability.

3. **Per-host SSH keypair, not substrate-wide.** Each registered
   remote-host gets its own keypair under
   `infra/keys/remote-hosts/<name>/{id_ed25519,id_ed25519.pub}`.
   Revocation is granular (remove the public key from one target's
   `authorized_keys`); compromise of one target's credentials
   doesn't cross-contaminate.

   Considered alternative: one substrate-wide keypair, shared across
   all registered remote hosts. Simpler to manage; coarser to revoke.
   **Override:** specify substrate-wide if you'd rather have one key
   to manage.

4. **Audit-logging wrapper as default.** A small wrapper on the
   container's PATH (`/usr/local/bin/ssh-audited`, or by replacing
   the agent user's `~/bin/ssh` symlink — the simpler form wins) tees
   each `ssh <host> '<command>'` invocation's command-line to a
   per-pair log under `${WORKDIR}/.substrate-ssh.log` and to stderr.
   This is hygiene, not a guardrail — it doesn't block anything; it
   just leaves a trail. Both stderr and the per-pair file capture it
   so the human reading the section report can see what was done on
   the remote without reconstructing it from the conversation.

   Considered alternative: no logging. Argument: the trust posture
   is "remote is given to the agent"; logging just adds clutter.
   The agent's own transcript already shows commands run.
   **Override:** specify "no logging" if you'd prefer to rely on the
   agent transcript alone.

5. **Bridge networking (Docker host NAT) is sufficient for LAN
   reachability.** Container-side outbound to LAN IPs (the typical
   home/office Pi setup) works through Docker's default `bridge`
   network via host-level NAT. The brief verifies this with a smoke
   test (`ssh -o BatchMode=yes <name> true` from inside coder-daemon
   in t04); if it fails on the deploying host's Docker config, the
   brief surfaces the diagnostic and the operator may need to switch
   to `network_mode: host` or adjust their `daemon.json`.

   Considered alternative: prescribe `network_mode: host` for role
   containers. Simpler for LAN reachability; loses Docker-network
   isolation between containers and breaks the existing `agent-net`
   topology.
   **Override:** specify host networking if your environment can't
   reach LAN IPs through bridge NAT.

---

## Top-level plan

**Goal.** Substrate registers named remote hosts at setup time;
generates per-host SSH credentials; bootstraps key-based access into
each target using the operator's existing SSH credentials; mounts the
keys + a populated known-hosts file into role containers along with a
generated `~/.ssh/config`; supports runtime addition of new remote
hosts on a running substrate; ships an end-to-end test fixture
exercising the full real-hardware workflow (Orange Pi + T-Dongle-S3
LED example) and a hardware-less loopback CI fallback.

**Scope.** One section, seven tasks. No parallelism — task ordering
is structural (state plumbing before bootstrap before container
wiring; tests last).

**Sequencing.** Execute after s009 lands in `main`. (s009 is now
merged at `ea7268e`.)

**Branch.** `section/s010-remote-host-integration` off `main`.

---

## Section s010 — remote-host-integration

### Section ID and slug

`s010-remote-host-integration`

### Objective

Add a remote-host registration system to turtle-core. At setup, the
human registers one or more remote hosts via
`--remote-host=<name>=<user>@<host>[,<name2>=<user2>@<host2>...]`.
The substrate generates a per-host SSH keypair, uses the operator's
existing SSH credentials (agent or key) to install the substrate's
public key on the target, captures the target's host key into a known-
hosts file, verifies passwordless SSH + sudo work via the substrate's
key alone, and writes the registration to durable state. Role
containers (architect, coder-daemon, auditor) mount the per-host
keys, the cumulative known-hosts file, and a generated `~/.ssh/config`
that maps each registered name to its key + known-hosts entry. An
optional thin wrapper logs SSH command lines for post-hoc visibility.
On a running substrate, `--add-remote-host=<spec>` registers a new
host without rebuild.

### Available context

The current state:

- s009 introduced `infra/scripts/lib/platform-args.sh` as the
  argument-parsing convention (`platform_args_init` /
  `_consume` / `_finalize` / `_help_block`). s010 follows the same
  pattern in a parallel file `infra/scripts/lib/remote-host-args.sh`,
  sourced from each setup entrypoint alongside platform-args. Each
  entrypoint loops argv with both `_consume` callbacks before falling
  through to its own switch.
- `setup-common.sh` §5.7 writes
  `.substrate-state/{platforms,devices}.txt` after `_finalize` runs.
  s010 adds `remote-hosts.txt` (and the cumulative `known-hosts`)
  alongside, written before role containers come up.
- `docker-compose.yml` already mounts `.substrate-state/` at
  `/substrate:ro` for the architect. coder-daemon and auditor do
  *not* currently mount the state directory; s010 adds the mount.
- s009 uses `docker-compose.override.yml` for device passthrough
  (rendered by `infra/scripts/render-device-override.sh`). s010 does
  *not* use the override file — its mounts are static (the directory
  *paths* are stable; their *contents* are dynamic), so the static
  `docker-compose.yml` carries them.
- `.substrate-state/` and `infra/keys/<role>/*` are already
  `.gitignore`d. s010 adds `infra/keys/remote-hosts/*/*` to the
  gitignore (the per-host key directories themselves are persisted
  via `.gitkeep` for first-clone hygiene).
- `setup-linux.sh` and `setup-mac.sh` both source `platform-args.sh`
  and call `platform_args_finalize` before sourcing `setup-common.sh`.
  s010 mirrors this for `remote-host-args.sh`.
- `add-platform-device.sh` is the running-substrate-extension
  pathway. s010 adds `--add-remote-host` handling to it (or to a new
  `add-remote-host.sh` invoked the same way; agent's call).
- The role base image (`infra/base/Dockerfile`) already installs
  `openssh-client`. No image change is required for SSH client
  availability. Verify this in t04; if it isn't present in the
  rendered `coder-daemon` / `auditor` images, the renderer's static
  template gets one apt-line.
- The "audit-logged ssh" wrapper convention is new in s010. The
  simplest realisation is a shell function `ssh()` exported in the
  agent user's `.bashrc` (or `~/.profile`) inside the container that
  tees `"$@"` to the log before exec'ing `/usr/bin/ssh`. The
  rendered Dockerfile or the entrypoint script can place the .bashrc
  fragment.
- The trust-posture statement in the README must be unambiguous.
  Wording is up to the agent but the substance is: "registering a
  remote host gives the agent unrestricted SSH access to that host
  with whatever privileges the registered user holds. The substrate
  does not sandbox the remote. If you don't want the agent to have
  full shell on a machine, don't register it."
- The Orange Pi test fixture is at `192.168.16.179`, user `jon`,
  passwordless sudo. A LilyGo T-Dongle-S3 (ESP32-S3, native USB-CDC,
  shows up as `/dev/ttyACM0`) is on the spare USB port. The LilyGo
  reference LED example (FastLED on the onboard APA102) at
  `https://github.com/Xinyuan-LilyGO/T-Dongle-S3/tree/main/examples/led`
  is the test firmware. Note: the example's source comment instructs
  Arduino IDE users to set "USB CDC On boot: Disable" (which routes
  `Serial` to UART0 rather than USB-CDC); for the substrate's test
  fixture we want USB CDC On Boot **Enabled** so the boot banner comes
  back through the same USB link the agent is reading. In PlatformIO
  that's `build_flags = -DARDUINO_USB_CDC_ON_BOOT=1`. The boot banner
  to assert on is the literal string
  `"Start T-Dongle-S3 LED example"` from the example's `setup()`.

### Tasks (informal decomposition)

The agent may decompose differently, but this is the suggested
ordering. Tasks 10.a–10.b build the parsing surface; 10.c is the
substantive bootstrap automation; 10.d wires containers; 10.e is
runtime addition; 10.f is the test (real-hardware procedure +
loopback CI); 10.g is documentation.

**10.a — Spec, schema, validator.**

Define the registration spec format:

```
<name>=<user>@<host>[:<port>]
```

- `<name>`: lowercase alphanumeric, `-`, `_`. Regex
  `^[a-z][a-z0-9_-]{0,62}$`. No whitespace. Must be unique within
  one substrate.
- `<user>`: any POSIX-valid username (let SSH error on bad ones).
- `<host>`: hostname or IP. Substrate doesn't pre-resolve.
- `<port>`: optional, integer 1..65535. Defaults to 22.

Multiple registrations in one flag use comma separation:
`--remote-host=tdongle-pi=jon@192.168.16.179,gpio-pi=pi@10.0.0.5`.

Write `infra/scripts/lib/validate-remote-host.sh`:

```sh
# validate_remote_host_spec <spec>
#   echoes parsed name|user|host|port on success, exits non-zero on failure
```

Validator rejects: empty name; name starting with digit or `-`;
unknown characters in name; missing `=`; missing `@`; port out of range;
duplicate name in the substrate's current registration set (read
from `.substrate-state/remote-hosts.txt` if it exists).

State-file format (`.substrate-state/remote-hosts.txt`):

```
<name>\t<user>\t<host>\t<port>
```

Tab-separated, one host per line, trailing newline. Emitted in the
order the host was registered. The cumulative known-hosts file
(`.substrate-state/known-hosts`) is standard SSH known-hosts format,
appended on every registration.

Add `infra/keys/remote-hosts/.gitkeep` and update `.gitignore`:

```
# s010: per-remote-host SSH keys, generated at registration time.
infra/keys/remote-hosts/*/*
!infra/keys/remote-hosts/.gitkeep

# s010: cumulative known-hosts file for registered remote hosts.
.substrate-state/known-hosts
```

(The `.substrate-state/` directory is already fully gitignored from
s009; the explicit known-hosts entry is for clarity.)

**10.b — Argument parsing and entrypoint integration.**

Write `infra/scripts/lib/remote-host-args.sh`, paralleling
`platform-args.sh`. Functions:

- `remote_host_args_init` — reset parsing state.
- `remote_host_args_consume <arg>` — recognise `--remote-host=<csv>`
  and `--add-remote-host=<spec>`. Returns 0 if consumed, 1 otherwise.
- `remote_host_args_finalize` — for each parsed spec, run
  `validate_remote_host_spec`. On failure, emit the diagnostic and
  exit 2. Export:
    - `SUBSTRATE_REMOTE_HOSTS=<comma-csv-of-name=user@host:port>`
    - `SUBSTRATE_ADD_REMOTE_HOST=<single-spec-or-empty>`
    - `SUBSTRATE_REMOTE_HOST_SUPPLIED=<0|1>`
- `remote_host_args_help_block` — emit the `--help` text for the two
  flags, called from each setup entrypoint's `--help` handler.

`--remote-host` may appear multiple times on argv (each occurrence
appends). `--add-remote-host` accepts at most one spec per
invocation (mirrors `--add-platform`).

Update `setup-linux.sh` and `setup-mac.sh`:

- Source `remote-host-args.sh` after `platform-args.sh`.
- Call `remote_host_args_init` after `platform_args_init`.
- In the argv loop, try `platform_args_consume` first, then
  `remote_host_args_consume`, then fall through to local switch.
- Call `remote_host_args_finalize` alongside `platform_args_finalize`.
- Extend `--help` to emit both arg help blocks.
- Add the `SUBSTRATE_ADD_REMOTE_HOST` check to the dispatch block
  that currently handles `SUBSTRATE_ADD_PLATFORM` /
  `SUBSTRATE_ADD_DEVICES`. Either the existing
  `add-platform-device.sh` grows a remote-host clause or a sibling
  `add-remote-host.sh` is invoked. The agent's call; if the existing
  script grows, rename it to `add-substrate-extensions.sh` for
  clarity. Either way the dispatch is in setup-linux.sh.

**10.c — Bootstrap automation.**

Write `infra/scripts/bootstrap-remote-host.sh`. Invoked by
`setup-common.sh` after `platform_args_finalize` and
`remote_host_args_finalize` have exported state, before role
containers come up. Loops over `SUBSTRATE_REMOTE_HOSTS` and
bootstraps each host.

Per-host bootstrap, given parsed `name`, `user`, `host`, `port`:

1. **Idempotency check.** If
   `infra/keys/remote-hosts/<name>/id_ed25519` exists AND the host
   is already in `.substrate-state/known-hosts` AND a verification
   `ssh -F /dev/null -i <key> -o StrictHostKeyChecking=yes
   -o UserKnownHostsFile=<known-hosts> -o BatchMode=yes
   -o ConnectTimeout=5 <user>@<host> -p <port> 'sudo -n true'`
   succeeds, the host is fully registered already. Skip steps 2–6.
   Log "[bootstrap] <name>: already registered, skipping."

2. **Generate substrate keypair.**
   `mkdir -p infra/keys/remote-hosts/<name> && chmod 0700 …` then
   `ssh-keygen -t ed25519 -N "" -f
   infra/keys/remote-hosts/<name>/id_ed25519 -C
   "turtle-core-substrate@<name>"`. Permissions `0600` on the private
   key, `0644` on the public.

3. **Capture the target's host key.** `ssh-keyscan -p <port> -t
   ed25519,rsa <host>` and append the result (with the explicit
   bracketed `[<host>]:<port>` form when port ≠ 22) to
   `.substrate-state/known-hosts`. Deduplicate against existing
   entries to keep the file tidy on re-runs.

4. **Install the substrate's public key on the target.** This is
   the step that uses the operator's existing SSH credentials. Run:

   ```sh
   ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
       -o UserKnownHostsFile="${state_dir}/known-hosts" \
       -p <port> <user>@<host> '
       umask 077
       mkdir -p ~/.ssh
       touch ~/.ssh/authorized_keys
       chmod 0600 ~/.ssh/authorized_keys
       grep -q -F "<substrate-pubkey-line>" ~/.ssh/authorized_keys ||
           printf "%s\n" "<substrate-pubkey-line>" >> ~/.ssh/authorized_keys
   '
   ```

   The `<substrate-pubkey-line>` is the contents of the freshly-
   generated `id_ed25519.pub`. The remote-side `grep -q -F` makes the
   append idempotent (running setup twice doesn't duplicate the
   line).

   `BatchMode=yes` here means "don't prompt for password — fail
   instead." If the operator hasn't preconfigured passwordless SSH,
   this step fails fast with a clear message ("the substrate
   couldn't reach <user>@<host> without a password — please
   set up passwordless SSH and re-run setup, or pass
   `--remote-host-bootstrap=interactive` to allow a one-time prompt").

   Note: this command uses *the operator's* SSH credentials (agent,
   `~/.ssh/id_*`) — explicitly NOT the substrate's freshly-generated
   key, which can't be on the target yet. SSH agent forwarding is
   not used.

5. **Verify substrate-key-only access.** Re-test the connection
   using only the substrate's key, no agent forwarding:

   ```sh
   ssh -F /dev/null \
       -i infra/keys/remote-hosts/<name>/id_ed25519 \
       -o IdentitiesOnly=yes \
       -o BatchMode=yes \
       -o StrictHostKeyChecking=yes \
       -o UserKnownHostsFile="${state_dir}/known-hosts" \
       -p <port> <user>@<host> 'sudo -n true && python3 --version'
   ```

   `IdentitiesOnly=yes` and `-F /dev/null` defeat ssh-agent fallback
   so we know the substrate key alone works. `sudo -n true` confirms
   passwordless sudo. `python3 --version` confirms python3 is
   present (a near-universal baseline; agents that need esptool will
   pip-install it themselves at use time).

   On failure, emit the exact diagnostic (sudo missing → "remote
   user lacks passwordless sudo"; python3 missing → "python3 not
   found on remote, install it before registering") and exit non-
   zero. Do not roll back step 4 (the public key on the target is
   benign even if the rest of bootstrap fails; re-running setup will
   either succeed or error in the same way, and removal is a manual
   `ssh-keygen -R` plus `authorized_keys` edit anyway).

6. **Append to state file.** Append the line
   `<name>\t<user>\t<host>\t<port>` to
   `.substrate-state/remote-hosts.txt`. Setup creates the file
   fresh on each run (per s009's pattern of regenerating
   platforms.txt / devices.txt every time setup-common runs); the
   state-file logic centralises in setup-common.sh §5.7's expanded
   form.

Make `bootstrap-remote-host.sh` callable both from setup-common.sh
(during initial setup) and from `add-substrate-extensions.sh` (for
runtime addition in 10.e).

**10.d — Container wiring.**

Three role containers receive remote-host access: architect,
coder-daemon, auditor. (planner does not — it doesn't run agent code
that needs to reach a remote.)

For each, update `docker-compose.yml`:

1. Add volume mounts (read-only):
   ```yaml
   - ./infra/keys/remote-hosts:/home/agent/.ssh-remote-hosts:ro
   - ./.substrate-state/known-hosts:/home/agent/.ssh-known-hosts:ro
   - ./.substrate-state/remote-hosts.txt:/substrate/remote-hosts.txt:ro
   ```
   (architect already has `.substrate-state` mounted at `/substrate`;
   the explicit `remote-hosts.txt` mount on coder-daemon and auditor
   is the simpler form, since they don't need the whole state dir.)
2. Add env:
   ```yaml
   SUBSTRATE_REMOTE_HOSTS: ${SUBSTRATE_REMOTE_HOSTS:-}
   ```

Add the SSH config generation. Two implementation options:

- **Option (a): generate `~/.ssh/config` on the host.** Setup writes
  `.substrate-state/ssh-config` from `remote-hosts.txt`, and each
  role container mounts it read-only at
  `/home/agent/.ssh/config`. **Preferred.** Runtime addition
  (10.e) becomes a host-side regen + the file is bind-mounted, so
  running containers see new hosts without restart. (The only
  caveat: a long-lived ssh control-master inside the container could
  hold an old config in memory; not a real concern for the agent
  workflow.)
- **Option (b): generate at container entrypoint.** The entrypoint
  reads `/substrate/remote-hosts.txt` and writes
  `~/.ssh/config`. Runtime addition requires container restart.
  Simpler ssh-config-write logic; coupled lifecycle.

Choose (a). Write
`infra/scripts/render-ssh-config.sh` that emits a `~/.ssh/config`
fragment from `.substrate-state/remote-hosts.txt`. Each registered
host gets a stanza:

```
Host <name>
    HostName <host>
    User <user>
    Port <port>
    IdentityFile /home/agent/.ssh-remote-hosts/<name>/id_ed25519
    IdentitiesOnly yes
    UserKnownHostsFile /home/agent/.ssh-known-hosts
    StrictHostKeyChecking yes
    BatchMode yes
    ConnectTimeout 10
```

The file lives at `.substrate-state/ssh-config` and is bind-mounted
at `/home/agent/.ssh/config:ro` in each container. Mount mode
`ro` is fine since the file is not edited inside the container.

`BatchMode yes` is intentional: agent-driven SSH should never
prompt; if auth fails, fail loudly rather than hanging. The
substrate's bootstrap step 5 verified non-interactive auth works
before this stanza was ever emitted, so BatchMode is safe.

**Audit-logging wrapper.** A small wrapper *script* (not a shell
function — non-interactive `bash -c '...'` invocations don't source
`.bashrc`, which would defeat function-based wrapping for the most
common agent call shape):

```sh
#!/bin/bash
# /usr/local/bin/ssh — wrapper that logs invocations before exec'ing
# the real ssh binary. Mounted read-only from
# infra/scripts/agent-ssh-audited.sh in the role's compose service.
ts=$(date -u +%FT%TZ)
log="${WORKDIR:-/work}/.substrate-ssh.log"
{
    printf '[%s] ssh' "$ts"
    for arg in "$@"; do printf ' %q' "$arg"; done
    printf '\n'
} | tee -a "$log" >&2
exec /usr/bin/ssh "$@"
```

The wrapper:
- Logs to stderr (so the agent transcript captures it).
- Logs to a per-pair file at `${WORKDIR}/.substrate-ssh.log` if
  `WORKDIR` is set (it is, in coder-daemon and auditor).
- `exec`'s `/usr/bin/ssh` so the real ssh inherits stdio cleanly.
- Preserves `$@` exactly (the `%q` quoting handles command
  arguments with spaces, which esptool / pio invocations sometimes
  have).

Place the script at `infra/scripts/agent-ssh-audited.sh` (chmod
0755) and bind-mount it read-only at `/usr/local/bin/ssh` in each
role container. Standard Linux `PATH=/usr/local/bin:/usr/bin:...`
ordering means it shadows `/usr/bin/ssh` for every invocation,
interactive or not. No `.bashrc` games.

Per design call 4, this is hygiene; the override path is to ship
without the mount if the trust posture makes it overkill.

**Smoke test for LAN reachability.** During setup, after
container wiring is in place, run:

```sh
docker compose run --rm coder-daemon bash -c \
    'for h in $(awk "NR>0 {print \$1}" /substrate/remote-hosts.txt); do
        ssh -o BatchMode=yes -o ConnectTimeout=5 "$h" true || exit 1
    done'
```

If this fails, emit a diagnostic naming the failing host and
suggesting `network_mode: host` or a Docker daemon network check.
Per design call 5, this is a warning, not a fatal error — the
operator may have registered a host that's only reachable from a
specific role container.

**10.e — Runtime addition.**

Extend the running-substrate-extension pathway to handle
`--add-remote-host=<spec>`.

If you keep `add-platform-device.sh` and grow it: add a clause that
runs after `--add-platform` / `--add-device` handling. If you split
into a sibling script (`add-remote-host.sh` or
`add-substrate-extensions.sh`), have setup-linux.sh dispatch to the
new script when only `SUBSTRATE_ADD_REMOTE_HOST` is set. Either is
acceptable; pick the cleaner factoring.

Behaviour for `--add-remote-host=<spec>`:

1. Validate the spec (`validate_remote_host_spec`).
2. Check that `<name>` is not already registered. If it is,
   refuse with a clear message and suggest `--remove-remote-host`
   (out of scope for s010, mention as future work).
3. Pre-flight: list any running role containers that mount the
   ssh-config file. If present and `--force` is not passed, refuse
   with a message naming the running containers. Reasoning: option
   (a) of 10.d means containers see the updated ssh-config without
   restart, but pre-existing SSH connections inside running
   containers may have cached state. Conservative refusal is the
   right default; `--force` skips it for operators who know.
4. Run `bootstrap-remote-host.sh` for the new host (idempotent;
   the same script handles steps 2–6 of 10.c).
5. Re-render `.substrate-state/ssh-config`.
6. Done. No image rebuild, no compose restart.

A successful `--add-remote-host` exits 0 with a one-line summary
naming the new host and confirming the bootstrap.

**10.f — End-to-end test.**

Two test surfaces: a real-hardware procedure that's documented and
runnable on demand, and a hardware-less loopback that runs in CI
alongside s007–s009's existing phases.

***Real-hardware procedure.*** Document in
`infra/scripts/tests/manual/remote-host-tdongle.md`:

1. **Preconditions.** Orange Pi (or other Linux device-host) at a
   known IP, passwordless SSH+sudo from the operator's shell, with
   a LilyGo T-Dongle-S3 plugged in (visible as `/dev/ttyACM0` on
   the Pi). Operator has built and is running the substrate with
   `--platform=platformio-esp32`.
2. **Register the host.**
   `./setup-linux.sh --add-remote-host=tdongle-pi=jon@192.168.16.179`
3. **Smoke check from coder-daemon.**
   `docker compose run --rm coder-daemon bash -c 'ssh tdongle-pi
   "lsusb | grep -i ESP"'` — should show the T-Dongle's USB
   descriptor.
4. **Install esptool on the remote.** From a coder-daemon shell
   (commissioned via commission-pair.sh, or one-shot via `docker
   compose run --rm coder-daemon bash`):
   `ssh tdongle-pi 'pip install --user esptool'`. The agent
   would do this on first use; the test does it explicitly.
5. **Build the LED example.** Inside coder-daemon: clone the
   LilyGo repo (or just `examples/led`), wrap as a PlatformIO
   project. The wrapper `platformio.ini`:
   ```ini
   [env:t-dongle-s3]
   platform = espressif32
   framework = arduino
   board = lilygo-t-dongle-s3
     ; If lilygo-t-dongle-s3 isn't a recognised board, use
     ; board = esp32-s3-devkitc-1 with appropriate flags.
   lib_deps = fastled/FastLED@^3.6.0
   build_flags = -DARDUINO_USB_CDC_ON_BOOT=1
   ```
   Place `led.ino` at `src/main.cpp` (or via `pio` project init). Run
   `pio run` to produce `.pio/build/t-dongle-s3/firmware.bin`.
6. **Flash.** scp + esptool over ssh:
   ```sh
   scp .pio/build/t-dongle-s3/firmware.bin tdongle-pi:/tmp/
   ssh tdongle-pi 'esptool --chip esp32s3 --port /dev/ttyACM0
       --baud 921600 write_flash -z 0x0 /tmp/firmware.bin'
   ```
7. **Read boot banner.**
   ```sh
   ssh tdongle-pi 'stty -F /dev/ttyACM0 115200 raw -echo;
       timeout 10 cat /dev/ttyACM0' | tee /tmp/serial.log
   grep -F "Start T-Dongle-S3 LED example" /tmp/serial.log
   ```
   The grep is the assertion.
8. **Visual smoke check.** The LED cycles R/G/B/Off in setup, then
   random colors in loop. Operator confirms. Not automated.

Document the procedure with explicit copy-pastable commands and
expected output. The agent runs through the procedure on the Orange
Pi at 192.168.16.179 with the T-Dongle attached, captures the
transcript, and includes it verbatim in the section report.

***Loopback CI test.*** Add a phase to
`infra/scripts/tests/test-substrate-end-to-end.sh` (numbering
continues from s009's Phase 16):

- **Phase 17 — remote-host registration loopback.** The phase
  spins up an alpine+openssh-server sidecar container as the
  "remote target", on a known docker network reachable from the
  test driver. Pre-installs the test driver's bootstrap key into
  the sidecar's `authorized_keys` (out-of-band of the substrate's
  bootstrap step 4 — this simulates the operator's existing
  passwordless SSH access). Then:
  1. Run `./setup-linux.sh --remote-host=ci-target=root@<sidecar>:22
     --platform=default`.
  2. Assert `bootstrap-remote-host.sh` succeeded:
     `infra/keys/remote-hosts/ci-target/id_ed25519` exists;
     `.substrate-state/known-hosts` contains the sidecar's host key;
     `.substrate-state/remote-hosts.txt` lists `ci-target`;
     `.substrate-state/ssh-config` has a `Host ci-target` stanza.
  3. From a stub coder-daemon: `ssh ci-target true` returns 0.
  4. Audit log present: `${WORKDIR}/.substrate-ssh.log` records
     the `ssh ci-target true` invocation.
  5. `--add-remote-host=ci-target-2=root@<sidecar2>:22` adds a
     second host without rebuild. Both registrations remain
     functional after.
  6. Tear down sidecars and reset the substrate state.

The sidecar pattern is similar to existing test phases that spin up
scratch containers; reuse the conventions in
`test-substrate-end-to-end.sh`. Document the sidecar Dockerfile
inline (or in `infra/scripts/tests/fixtures/sshd-sidecar/Dockerfile`)
— alpine + openssh-server + bash + sudo, with a non-root user
configured for passwordless sudo.

**10.g — Documentation.**

Update:

- `methodology/deployment-docker.md` — new §11 "Remote hosts".
  Describes the model, the registration spec format, the bootstrap
  flow, the ssh-config / known-hosts / per-host-key layout, the
  audit-logging wrapper, the trust posture, and the runtime-add
  pathway. Includes a worked example (the T-Dongle-S3 procedure
  from 10.f, condensed to its essentials).
- `README.md` quickstart: add a `--remote-host` mention to the
  setup step. One sentence at the right place. Link to §11 of
  deployment-docker.md.
- `methodology/architect-guide.md` — the existing "/substrate/
  platforms.txt and /substrate/devices.txt" paragraph (added in
  s009.f) gets a sibling sentence:

  > A `/substrate/remote-hosts.txt` file, if present, lists named
  > remote hosts available to role containers. Each line is
  > tab-separated `<name>\t<user>\t<host>\t<port>`. Inside any
  > role container, `ssh <name> '<command>'` reaches the remote
  > using substrate-managed credentials. Record relevant remote
  > hosts in SHARED-STATE.md under "Remote hosts" if the project's
  > work depends on them (typically: embedded HIL targets, GPIO
  > / sensor boards, cross-arch test machines).

- **Trust-posture note** — at the top of the Remote hosts section
  in `deployment-docker.md`, in a "⚠ Read this first" box:

  > Registering a remote host gives the agent unrestricted SSH
  > access to that host with whatever privileges the registered
  > user account holds (typically passwordless sudo, per the
  > setup precondition). The substrate does not sandbox the
  > remote — it is, deliberately, a *physical sandbox* the
  > operator hands to the agent. If you don't want the agent to
  > have full shell on a machine, do not register that machine.
  > Operators wanting a tighter posture (command filtering,
  > limited-shell users, etc.) configure that on the target
  > before registration.

- Inline comment headers in
  `infra/scripts/lib/remote-host-args.sh`,
  `infra/scripts/lib/validate-remote-host.sh`,
  `infra/scripts/bootstrap-remote-host.sh`,
  `infra/scripts/render-ssh-config.sh`,
  `infra/scripts/agent-ssh-audited.sh`,
  any modifications to `setup-linux.sh` /
  `setup-mac.sh` / `setup-common.sh` /
  `add-platform-device.sh` (or its successor).

### Constraints

- **No image rebuild for runtime addition.** `--add-remote-host`
  works on a running substrate without rebuilding any role image.
  All changes are mount-content updates.
- **No new dependencies in role images.** SSH client is already
  present via the base image. The wrapper is a shell function;
  no extra binaries.
- **Bootstrap uses operator credentials, not the substrate's.**
  Bootstrap step 4 explicitly uses the operator's loaded SSH
  identity (agent or `~/.ssh/id_*`). The substrate never asks the
  operator for a password and never uses agent forwarding for any
  step beyond bootstrap.
- **Per-host key isolation.** Each registered host gets its own
  keypair under `infra/keys/remote-hosts/<name>/`. Compromise of
  one target's `authorized_keys` does not expose other targets.
- **State files mounted live.** Same precedent as s009's
  `platforms.txt` / `devices.txt`: `remote-hosts.txt`,
  `known-hosts`, `ssh-config` are live bind mounts. Updates are
  visible to running containers without restart.
- **Methodology docs minimal change.** Architect-guide gets one
  paragraph (parallel to s009.f's pattern). Spec, planner-guide,
  auditor-guide are untouched. Full propagation of remote-host
  awareness into briefs is out of scope (deferred to a follow-up
  alongside the s009 methodology integration that's also
  pending).
- **No project-methodology run during this section.** Substrate-
  iteration. The agent modifies files directly; no commission of
  planner/coder/auditor.
- **Audit log location is per-pair-workspace.** `${WORKDIR}/.
  substrate-ssh.log` lives with the pair's work; section reports
  for project-methodology runs that exercise remote hosts include
  the log contents (or a reference). For substrate-iteration runs
  the log is captured in the agent's transcript via the wrapper's
  stderr write.
- **YAML / TSV format only.** Spec format is the
  `<name>=<user>@<host>[:<port>]` string described in 10.a; state
  file is TSV; ssh-config is standard ssh_config(5). No alternate
  formats.

### Definition of done

- `infra/scripts/lib/remote-host-args.sh` mirrors
  `platform-args.sh` API surface and is sourced cleanly from
  `setup-linux.sh` and `setup-mac.sh`.
- `infra/scripts/lib/validate-remote-host.sh` validates the spec
  format and flags duplicate names. Failing validation aborts
  setup with a clear diagnostic.
- `infra/scripts/bootstrap-remote-host.sh` performs the six-step
  bootstrap (idempotency check, key gen, host-key capture, key
  install via operator creds, substrate-key-only verification,
  state-file append) for each `SUBSTRATE_REMOTE_HOSTS` entry.
  Idempotent across re-runs.
- `infra/scripts/render-ssh-config.sh` emits
  `.substrate-state/ssh-config` from
  `.substrate-state/remote-hosts.txt`. One stanza per registered
  host with the fields in 10.d.
- `infra/scripts/agent-ssh-audited.sh` is bind-mounted at
  `/usr/local/bin/ssh` (read-only) in each role container; standard
  PATH ordering makes it intercept all `ssh` invocations,
  interactive or not.
- `docker-compose.yml` mounts the per-host keys, known-hosts,
  ssh-config, and remote-hosts.txt into architect, coder-daemon,
  and auditor with appropriate read-only flags.
- `setup-linux.sh` / `setup-mac.sh` / `setup-common.sh` accept
  `--remote-host=<name>=<user>@<host>[:<port>][,<spec2>...]` and
  `--add-remote-host=<spec>`.
- `--add-remote-host` on running substrate succeeds in the happy
  path, refuses cleanly when ephemeral containers are running
  (without `--force`).
- `infra/scripts/tests/test-substrate-end-to-end.sh` Phase 17
  exercises the loopback flow against an alpine+openssh sidecar
  and asserts the registration, ssh-config, audit-log presence,
  and runtime-add behaviour. Test suite passes 17 phases (s009's
  16 + 1 new), or however many the agent ends up needing to fully
  cover.
- `infra/scripts/tests/manual/remote-host-tdongle.md` documents
  the real-hardware procedure with copy-pastable commands. The
  agent runs through it against the Orange Pi at
  `192.168.16.179` and captures the transcript in the section
  report.
- `methodology/deployment-docker.md` §11 written, including the
  trust-posture box and the worked T-Dongle example.
- `README.md` quickstart updated.
- `methodology/architect-guide.md` has the remote-hosts paragraph.
- `.gitignore` updated for
  `infra/keys/remote-hosts/*/*` and the
  `.substrate-state/known-hosts` clarification.
- Section report at
  `briefs/s010-remote-host-integration/section.report.md`
  including: brief echo, per-task summary with commit hashes, the
  bootstrap script's idempotency-check transcript, the rendered
  `.substrate-state/ssh-config` for a two-host registration, the
  Phase 17 transcript, the manual-procedure transcript from the
  Orange Pi run (with `Start T-Dongle-S3 LED example` highlighted
  in the captured serial output), the audit-log contents from the
  manual run, the state of all five design calls (kept or
  overridden — and how), and any residual hazards.

### Out of scope

- **Removing a registered remote host.** `--remove-remote-host` is
  not in s010. The manual workaround is: edit
  `.substrate-state/remote-hosts.txt`, regenerate ssh-config via
  `render-ssh-config.sh`, optionally `ssh <host> 'sed -i …'` to
  remove the substrate's public key from the target's
  `authorized_keys`. Future small section.
- **Methodology propagation of remote-hosts into task briefs.** The
  architect-guide gets one paragraph (per the s009 pattern); full
  methodology integration where planner-guide / auditor-guide
  reference remote-hosts in brief authoring is deferred. Same
  shape as the s009 methodology-integration deferral.
- **Remote-host-specific tool installation.** The `tools:` block
  alternative discussed in design call 2 is out of scope. Agent
  installs on demand.
- **Multi-tenant key management.** If a single remote host is
  shared across multiple turtle-core substrates (different
  operators), each substrate registers it independently and gets
  its own key in the target's `authorized_keys`. Coordination
  between substrates is not modelled.
- **Connection pooling / SSH ControlMaster.** Speedup via
  ControlMaster (avoiding TCP handshake on every `ssh` invocation)
  is a useful future tweak; not in s010. Per-invocation TCP cost
  is negligible for the agent workflow.
- **Real hardware in CI.** Phase 17 uses a sidecar sshd container
  to exercise the full mechanism. Real-hardware verification
  happens out-of-band via the manual procedure.
- **Remote-host-aware platform plugins.** The s009 platform model
  declares `runtime.device_required` and `runtime.groups`. A
  future extension might let platforms declare `remote_required`
  for "this platform's testing assumes a registered remote host
  of <kind>"; not in s010.
- **Removal of the s009 `--device` mechanism.** s009's local-
  device passthrough remains supported for locally-attached
  devices. s010 adds an alternative topology, not a replacement.

### Repo coordinates

- Base branch: `main` (at s009 merge `ea7268e` or later).
- Section branch: `section/s010-remote-host-integration`.
- Commits per task (matching s008/s009 convention; tightly-coupled
  task pairs may share a commit, e.g., 10.a + 10.b are split-or-
  combined at the agent's discretion).
- **Push the section branch to origin before discharging.**
  Finding 35 (handover) flagged the s009 case where the agent
  committed but didn't push; explicit reminder here. Discharge
  protocol includes `git push -u origin
  section/s010-remote-host-integration` and `git push` after every
  subsequent commit.

### Reporting requirements

Section report at
`briefs/s010-remote-host-integration/section.report.md` on the
section branch. Must include:

- Brief echo.
- Per-task summary with commit hashes.
- The bootstrap script's transcript on a fresh registration
  (real or loopback), showing the six steps and the verification.
- Idempotency demonstration: re-running setup with the same
  registration set should be a no-op (the idempotency-check
  branch).
- The rendered `.substrate-state/ssh-config` for a two-host
  registration — illustrates the per-stanza shape.
- The Phase 17 test transcript.
- The Orange Pi / T-Dongle-S3 manual procedure transcript,
  including the captured serial output around `Start T-Dongle-S3
  LED example`.
- The per-pair audit-log contents from the manual run.
- Resolution of each of the five design calls (kept as written,
  or overridden — and how).
- Any residual hazards.

---

## Execution

Single agent on the host, working in the `turtle-core` clone
directly. Same pattern as s007, s008, s009. Work through 10.a–10.g
in order, committing per task (or per tightly-coupled pair).

After 10.a + 10.b, the spec format and parsing surface are stable;
10.c–10.e all depend on these being right. Pause briefly if
ambiguity surfaces.

10.c (bootstrap) is the substantive new code; the rest is plumbing.
The bootstrap script's six-step flow deserves careful test coverage
in 10.f Phase 17.

10.f's manual procedure is run against the Orange Pi at
`192.168.16.179` (passwordless SSH+sudo for `jon`, T-Dongle-S3 on
`/dev/ttyACM0`, `setup-linux.sh --platform=platformio-esp32 --remote-host=tdongle-pi=jon@192.168.16.179`).
Capture the full transcript including the boot banner. The visual
LED check (R/G/B/Off in setup, then random in loop) is the
human-side smoke confirmation.

If genuine brief-insufficient ambiguity surfaces, discharge with a
"brief insufficient" report. Same discipline as s007–s009.

This section is moderate in size — smaller than s009, larger than
s008. The Phase 17 sidecar setup time will add to the test suite
runtime; document in the section report.
