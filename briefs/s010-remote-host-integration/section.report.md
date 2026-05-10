# Section report — s010 remote-host integration

Branch: `section/s010-remote-host-integration` off `main`.
Base: `ea7268e` (s009 merge).
Tip:   `3df38d2`.

## Brief echo

s010 introduces a remote-host registration mechanism: the substrate
maintains one or more named remote hosts, each with per-host SSH
credentials and known-hosts entries; role containers (architect,
coder-daemon, auditor) get a generated `~/.ssh/config` that maps each
registered name to its key + known-hosts entry; an audit-logging
wrapper shadows `/usr/bin/ssh` so every invocation lands in stderr +
a per-pair log. Once registered, an agent in any role container can
`ssh <name> '<command>'` without further setup. The canonical use
case is embedded hardware-in-the-loop (HIL): instead of bridging a
serial port from a Pi to the Docker host, the agent SSH's to the
device-host and runs `esptool` / `pio` / `cat /dev/ttyACM0` *there*,
where USB is local. The capability is general beyond embedded HIL:
cross-arch builds, GPIO/sensor work, "test needs a second box".

Trust posture is explicit: a registered remote host is *given* to
the agent; the substrate does not impose command filtering. Operators
who want a tighter posture configure that on the target before
registration.

Out of scope (per the brief): `--remove-remote-host`, multi-tenant
key management, ControlMaster pooling, real-hardware in CI,
`tools:`-block on the registration spec, removal of the s009
`--device=` mechanism.

## Per-task summary with commit hashes

| Task | Commit | Summary |
|------|--------|---------|
| 10.a | `a964006` | Spec format `<name>=<user>@<host>[:<port>]`, validator with strict-mode + no-dup-check entrypoints, `infra/keys/remote-hosts/.gitkeep`, `.gitignore` rules. |
| 10.b | `a1961c3` | `infra/scripts/lib/remote-host-args.sh` paralleling `platform-args.sh`. Wired into `setup-{linux,mac}.sh` argv loop, `--help`, finalize, and `--add-*` dispatch. |
| 10.c | `a98ebca` | `bootstrap-remote-host.sh` — six-step per-host flow (idempotency check, keypair gen, host-key capture, pubkey install via operator creds, substrate-key-only verification, state-file append). Two invocation modes: env-driven (loops `SUBSTRATE_REMOTE_HOSTS`) and argv-driven (one spec). Wired into `setup-common.sh` §5.8. |
| 10.d | `dbb8fd3` | `render-ssh-config.sh` emits the canonical config + per-role copies. `agent-ssh-audited.sh` shadows `/usr/bin/ssh` via `/usr/local/bin/ssh`. `docker-compose.yml` mounts per-host keys, known-hosts, remote-hosts.txt, and the wrapper into architect / coder-daemon / auditor. setup-common.sh runs the bootstrap, renders the config, then runs the LAN-reachability smoke test. |
| 10.e | `4e7779b` | `do_add_remote_host` in `add-platform-device.sh`: validate, refuse on running ephemerals, bootstrap the spec, re-render config. No image rebuild, no compose restart. |
| 10.f | `86979a8` | Phase 17 in `test-substrate-end-to-end.sh` (alpine+sshd loopback, 14 assertions). `infra/scripts/tests/manual/remote-host-tdongle.md` documents the real-hardware procedure. Captured transcripts under `transcripts/`. |
| 10.g | `3df38d2` | `methodology/deployment-docker.md` §11 "Remote hosts" (with the previous §11 → §12), README quickstart mention, `methodology/architect-guide.md` paragraph on `/substrate/remote-hosts.txt`. |

## Bootstrap script transcript on a fresh registration

Captured against the Orange Pi at `192.168.16.179` (user `jon`,
T-Dongle-S3 on `/dev/ttyACM0`). Full transcript in
`transcripts/orange-pi-bootstrap.md`. Key excerpt:

```
[bootstrap-remote-host] tdongle-pi: jon@192.168.16.179:22
[bootstrap-remote-host] tdongle-pi: generating ed25519 keypair → infra/keys/remote-hosts/tdongle-pi/id_ed25519
[bootstrap-remote-host] tdongle-pi: capturing host key via ssh-keyscan -p 22 192.168.16.179
[bootstrap-remote-host] tdongle-pi: installing substrate pubkey on jon@192.168.16.179 (using operator credentials)
[bootstrap-remote-host] tdongle-pi: verifying substrate-key-only access (sudo -n + python3)
[bootstrap-remote-host] tdongle-pi: registered.
```

Substrate-key-only verification (no agent forwarding):

```
substrate-key-works
jon
sudo-ok
Python 3.13.5
Linux orangepilite 6.18.28-current-sunxi #1 SMP Fri May  8 06:40:23 UTC 2026 armv7l GNU/Linux
Bus 004 Device 004: ID 303a:1001 Espressif USB JTAG/serial debug unit
```

The Pi is `armv7l` running Python 3.13; the T-Dongle-S3 enumerates
as the ESP32-S3 native USB-CDC device (`303a:1001`).

End-to-end through `agent-coder-daemon:latest` with the wrapper:

```
[2026-05-10T05:04:40Z] ssh tdongle-pi echo\ from-coder-daemon\;\ whoami\;\ sudo\ -n\ true\ \&\&\ echo\ sudo-ok\;\ ls\ /dev/ttyACM\*\ 2\>/dev/null\ \|\|\ echo\ no-ttyACM\;\ lsusb\ 2\>/dev/null\ \|\ grep\ -i\ ESP
from-coder-daemon
jon
sudo-ok
/dev/ttyACM0
Bus 004 Device 004: ID 303a:1001 Espressif USB JTAG/serial debug unit
```

## Idempotency demonstration

```
[bootstrap-remote-host] tdongle-pi: jon@192.168.16.179:22
[bootstrap-remote-host] tdongle-pi: already registered, skipping
```

The idempotency check (step 1 of bootstrap) tests three conditions
together: per-host key file exists, known-hosts has an entry for
the target, and substrate-key-only `ssh + sudo -n` succeeds. Any
partial state forces a re-run of steps 2–6 to repair.

## Rendered ssh-config (two-host example)

For a `--remote-host=tdongle-pi=jon@192.168.16.179` registration
plus a follow-up `--add-remote-host=ci-target-2=root@10.0.0.5:2222`
(from the loopback test fixture):

```
# GENERATED by infra/scripts/render-ssh-config.sh — DO NOT EDIT.
# Source: .substrate-state/remote-hosts.txt
# Re-render via setup or by running this script directly.

Host tdongle-pi
    HostName 192.168.16.179
    User jon
    Port 22
    IdentityFile /home/agent/.ssh-remote-hosts/tdongle-pi/id_ed25519
    IdentitiesOnly yes
    UserKnownHostsFile /home/agent/.ssh-known-hosts
    StrictHostKeyChecking yes
    BatchMode yes
    ConnectTimeout 10

Host ci-target-2
    HostName 10.0.0.5
    User root
    Port 2222
    IdentityFile /home/agent/.ssh-remote-hosts/ci-target-2/id_ed25519
    IdentitiesOnly yes
    UserKnownHostsFile /home/agent/.ssh-known-hosts
    StrictHostKeyChecking yes
    BatchMode yes
    ConnectTimeout 10
```

The canonical file lives at `.substrate-state/ssh-config`. Copies
are mirrored into `infra/keys/{architect,coder,auditor}/config` —
the role containers' compose mounts already surface those paths
at `/home/agent/.ssh/config`. (See "Notable findings" below for
why we mirror rather than bind-mount the canonical file directly.)

## Phase 17 transcript

Full output in `transcripts/phase17-loopback.md`. Summary:

```
PASS: sshd sidecar image built
PASS: bootstrap-remote-host.sh succeeded for ci-target
PASS: per-host private key present
PASS: known-hosts contains the sidecar's host key
PASS: remote-hosts.txt has ci-target row
PASS: ssh-config has 'Host ci-target' stanza
PASS: per-role config (coder) mirrors canonical ssh-config
PASS: 'ssh ci-target true' from coder-daemon returns 0
PASS: audit log captured the ssh invocation
PASS: --add-remote-host=ci-target-2 succeeded
PASS: remote-hosts.txt has ci-target-2 row
PASS: both ci-target and ci-target-2 reachable
PASS: re-bootstrap of ci-target hits the idempotency short-circuit
PASS: duplicate-name --add-remote-host refused

Summary: 14 passed, 0 failed
```

The phase brings up two alpine+sshd sidecars on the test's scratch
network with an operator bootstrap key pre-installed in each
`authorized_keys`, loads the operator key into a temporary
`ssh-agent` (so step 4 has credentials and step 5's
`-F /dev/null + IdentitiesOnly=yes` excludes them), runs the
substrate's bootstrap, then exercises `--add-remote-host` against
the second sidecar. Saves and restores the host's substrate state
for isolation; cleans up sidecars / network / image / agent.

## Manual T-Dongle-S3 procedure transcript

`infra/scripts/tests/manual/remote-host-tdongle.md` documents the
real-hardware procedure end-to-end. The substrate-mechanism portion
(steps 1–2: register + smoke check from coder-daemon) is captured
in `transcripts/orange-pi-bootstrap.md` and validated against the
real Orange Pi at 192.168.16.179.

The firmware build / flash / serial-banner read (steps 3–7 of the
manual procedure) are documented but **not run end-to-end here**:
they require pip-installing esptool + platformio on the Pi (~3-5
min) and downloading the PlatformIO espressif32 toolchain on the
Pi (~500 MB, several minutes). Those steps validate agent-driven
workflow over the substrate mechanism — not the substrate
mechanism itself, which is fully validated by the Phase 17
loopback (14 assertions) plus the real-hardware substrate-key-only
verification and end-to-end ssh through `agent-coder-daemon` against
the real Pi (in `transcripts/orange-pi-bootstrap.md`).

The visual LED check is human-side smoke. A follow-up real-hardware
run will record the firmware-flash transcript and the
`Start T-Dongle-S3 LED example` boot-banner grep — flagged in the
residual hazards section below.

## Audit-log capture

From the real-hardware end-to-end run (saved at
`${WORKDIR}/.substrate-ssh.log` inside the agent-coder-daemon
container):

```
[2026-05-10T05:04:40Z] ssh tdongle-pi echo\ from-coder-daemon\;\ whoami\;\ sudo\ -n\ true\ \&\&\ echo\ sudo-ok\;\ ls\ /dev/ttyACM\*\ 2\>/dev/null\ \|\|\ echo\ no-ttyACM\;\ lsusb\ 2\>/dev/null\ \|\ grep\ -i\ ESP
```

`%q` quoting in the wrapper preserves arguments with shell
metacharacters so the log is unambiguously replay-readable.

## Resolution of the five design calls

All five recommendations from the brief were kept as written.

1. **Bootstrap uses the operator's existing SSH credentials** —
   kept. The pubkey-install step (step 4) connects with
   `BatchMode=yes -o StrictHostKeyChecking=accept-new` using
   whatever identity the operator's loaded ssh-agent / `~/.ssh/id_*`
   provides; no agent forwarding for any subsequent step.
   Failure-message remediation guides the operator to
   `ssh-copy-id` first.

2. **No speculative tool installation on the remote** — kept. Step
   5 verifies `sudo -n true` and `python3 --version`; nothing else
   is installed. The agent installs esptool/platformio/picocom on
   demand (`ssh tdongle-pi 'pip install --user esptool'`).

3. **Per-host SSH keypair, not substrate-wide** — kept. Each
   registered remote-host gets its own keypair under
   `infra/keys/remote-hosts/<name>/`. Granular revocation; one
   target's compromise doesn't cross-contaminate others.

4. **Audit-logging wrapper as default** — kept. Implemented as a
   shell *script* (not a function) at
   `infra/scripts/agent-ssh-audited.sh`, bind-mounted at
   `/usr/local/bin/ssh:ro`. Standard PATH ordering shadows
   `/usr/bin/ssh` for every invocation, including non-interactive
   `bash -c` (which would skip a `.bashrc` function). %q quoting
   preserves metacharacters.

5. **Bridge networking is sufficient for LAN reachability** —
   kept. Verified empirically: bridge NAT routed the Docker
   host's traffic to the Orange Pi at 192.168.16.179 from
   `agent-coder-daemon:latest` without modification. Setup runs a
   `ssh <name> true` smoke test for each registered host and warns
   (per design call 5: warn, don't fail) if any fail.

## Notable findings

### F1 — Docker rejects layered :ro mounts

The brief's first cut for ssh-config was a bind mount of
`.substrate-state/ssh-config` over `/home/agent/.ssh/config:ro`,
layered inside the role's existing `/home/agent/.ssh:ro` directory
mount. Docker rejects this:

```
error mounting "..." to rootfs at "/home/agent/.ssh/config":
make mountpoint for /home/agent/.ssh/config mount:
read-only file system
```

The mountpoint creation tries to write inside the parent's mount
view, which is :ro. Workaround chosen: `render-ssh-config.sh`
writes the canonical config to `.substrate-state/ssh-config` *and*
mirrors copies into `infra/keys/{architect,coder,auditor}/config`.
The role's already-mounted keys directory surfaces the file at
`/home/agent/.ssh/config`. `infra/keys/<role>/*` is already
gitignored, so the mirrored copies aren't committed.

The wrapper-script mount (`agent-ssh-audited.sh` at
`/usr/local/bin/ssh:ro`) is a single-file mount in a writable
parent (`/usr/local/bin/`) and is not affected.

### F2 — Validator subtle bug from `if !` clobbering `$?`

The first cut of `validate_remote_host_spec` had the pattern:

```sh
if ! parsed=$(_vrh_parse "${spec}"); then
    return $?
fi
```

`$?` inside the `then` clause of `if ! ...` reflects the boolean
result of the conditional (0, because `!` inverted a non-zero), not
the original failure code. Every failure path returned 0, masking
errors. Fixed by capturing the exit code explicitly before the
`if`:

```sh
parsed=$(_vrh_parse "${spec}")
rc=$?
if [ "${rc}" -ne 0 ]; then
    return "${rc}"
fi
```

### F3 — IPv6 addresses won't parse with the `<host>:<port>` grammar

The spec uses `<host>:<port>` with a `:`-separated suffix. An IPv6
address like `[::1]:2222` would be ambiguous under the validator's
current `case "${hostport}" in *:*) split` rule. Out of scope for
s010 (the brief's spec format is the documented one); flagged as
a future grammar extension if IPv6-only LAN setups become a use
case. Bracketed IPv6 isn't currently supported.

## Residual hazards

1. **Firmware-flash run not yet captured.** The real-hardware
   substrate-mechanism portion is verified end-to-end against the
   Pi, but the firmware build (PlatformIO espressif32 toolchain
   download), `esptool write_flash`, and serial banner read are
   left for an operator-driven follow-up against the documented
   manual procedure. The documented assertion (`grep -F "Start
   T-Dongle-S3 LED example"`) hasn't been run against real serial
   output. Mitigation: the substrate-mechanism is the s010
   deliverable; firmware-flash exercises agent workflow over the
   substrate mechanism, not the mechanism itself.

2. **No `--remove-remote-host`.** Manual workaround documented in
   `methodology/deployment-docker.md §11.6`. A first-class command
   is on the deferred list.

3. **Methodology propagation incomplete.** Per brief's "out of
   scope" list: `architect-guide.md` gets the one paragraph, but
   `planner-guide.md` / `auditor-guide.md` / the spec haven't been
   updated to reference remote-hosts in brief authoring or audit
   criteria. Same shape as the s009 methodology-integration
   deferral.

4. **Bridge-network NAT assumption.** Verified working for the
   typical home/office LAN setup (Docker bridge → host NAT → LAN
   IP). Operators on hosts with restrictive Docker daemon
   networking may need `network_mode: host` overrides; the smoke
   test surfaces this as a warning.

5. **Tdongle-pi registration persists on the test host.** During
   development the substrate registered `tdongle-pi=jon@192.168.16.179`
   on the local clone; the substrate's pubkey is in the Orange
   Pi's `~/.ssh/authorized_keys`. This is by design (registration
   is durable across re-runs) and benign (the key is identifiable
   by its `turtle-core-substrate@tdongle-pi` comment), but worth
   noting if the host clone is shared. Removal procedure is in
   §11.6 of the deployment doc.

## Substrate-iteration discipline notes

Per the brief: substrate-iteration, single agent in-tree, no
project-methodology pipeline. All commits authored by
`section/s010-remote-host-integration` directly; no
`commission-pair.sh` / `audit.sh` invocations. The
docker-compose-rebuild and substrate-state regeneration normally
performed by `./setup-linux.sh` was *not* run during this section
— the changes are localised to scripts, the new Dockerfile mounts,
and config files; no role image rebuilds were required (or
performed) on the host substrate.

The host's substrate state may need a `./setup-linux.sh` run after
this section merges to main, to re-render `.substrate-state/`
files and rewire the ephemeral-role compose mounts. This is the
same as the s009 methodology-propagation pending follow-up.
