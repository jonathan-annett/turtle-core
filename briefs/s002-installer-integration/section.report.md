# s002-installer-integration — section report

## Brief echo

Commit `install-docker.sh` to the repo, integrate it into setup-linux.sh
as an opt-in flag, and add a `~/.docker` ownership preflight to
setup-linux.sh that fails fast with a remediation hint. Architect's
baked recommendation for integration: approach (b) — opt-in flag,
preserving the convention that the setup script does not provision
tools, only verifies them.

## Integration approach (human decision)

**Confirmed approach: (b) opt-in `--install-docker` flag.** Captured via
the brief's pause-point question; user accepted the architect's
recommendation. No additional integration work was diverted to (a)
auto-call or (c) standalone-only.

## Per-task summary

### Task 2.a — commit install-docker.sh

**Status:** done.

`install-docker.sh` committed verbatim from brief Appendix A at the repo
root, mode 0755. Detects Debian / Ubuntu / Crostini (apt + docker-ce +
buildx-plugin + compose-plugin), macOS (Homebrew + Colima with
`--cpu 4 --memory 8`), other Linux distros (bail out cleanly), and
unidentifiable platforms (bail out). Idempotent fast-path early-exit
when `docker info && docker compose version && docker buildx version`
already succeed.

Diff: see commit `5371653`.

### Task 2.b — `~/.docker` ownership preflight

**Status:** done.

Added near the top of `setup-linux.sh`, right after `cd "$repo_root"`.
If `~/.docker` exists and is not owned by `$USER`, the script exits 1
with a message that includes the literal `sudo chown -R "$USER:$USER"
~/.docker` remediation command. No auto-fix — surfacing the decision is
safer than silently chowning a directory that may be deliberately
shared.

Diff: see commit `db7d0a9`.

### Task 2.c — opt-in `--install-docker` flag

**Status:** done; landed in two commits because the first version had a
bug (see "Bug found and fixed" below).

`setup-linux.sh` and `setup-mac.sh` now accept `--install-docker`. With
the flag, both scripts `exec install-docker.sh` and exit (bootstrap-only
mode). Without the flag, behavior is unchanged — verify only, no
system-wide provisioning. The Docker-missing failure messages now point
at `--install-docker` for users who want the automatic path.

README's Prerequisites section gains a paragraph explaining the flag
and the two-shot bootstrap pattern. The Troubleshooting section's
"the script does not provision tools; it only verifies them" sentence
is preserved unchanged, per the brief constraint.

Diffs: see commits `12f7635` (initial) and `a033b0f` (fix — see below).

## Bug found and fixed

The first version of task 2.c (commit `12f7635`) ran
`install-docker.sh` and then **continued** into the verify/setup flow
in the same shell. This is a sharp footgun and was caught during
verification on the agent's host:

1. `install-docker.sh` on Linux adds `$USER` to the `docker` group via
   `usermod -aG`. The group change only takes effect in a new login
   shell, so the very next non-sudo docker invocation by the same
   script would fail with a permission error.

2. Worse, after the (failing) verify, the script would source
   `setup-common.sh`, which calls `infra/scripts/generate-keys.sh`.
   That script is idempotent against existing keys, but on a host
   whose `infra/keys/<role>/` directories happen to be empty (e.g.
   because key files have been rotated, the user is testing setup, or
   the host is hosting a *different* substrate via a parallel checkout)
   it generates fresh per-role SSH keypairs. The host filesystem then
   has new keys; any running git-server / architect containers still
   hold the old keys via their bind mounts (which on Crostini's 9p
   layer don't always re-resolve after an unlink+create), so the host
   and the running substrate diverge silently.

   This was observed end-to-end on the agent's host: a test invocation
   of `./setup-linux.sh --install-docker` regenerated all five host
   keypairs while a long-running `agent-architect` and
   `agent-git-server` were live with the old keys. The substrate
   internally remained consistent (containers all saw old keys via
   stale mounts), but the host diverged.

The fix (commit `a033b0f`) makes `--install-docker` a bootstrap-only
mode: `exec install-docker.sh` and exit. The user re-runs setup
(without the flag) after the docker-group change has taken effect, in
a new login shell. System-package installation and substrate setup
are now cleanly separated phases.

The recovery on the agent's host was: delete the freshly-generated
host keys (untracked; `infra/keys/<role>/id_ed25519{,.pub}`), confirm
no other docker state had been mutated (images, volumes, network all
pre-existed; verified via timestamps), and proceed with the corrected
flag implementation. The running architect/git-server containers were
not interrupted.

A residual hazard remains in the **no-flag** path: `setup-common.sh`'s
key-generation step still runs on every invocation and will silently
regenerate keys if the host directories are empty for any reason. This
is out of scope for s002 as written, but worth flagging to the
architect for a future section: making generate-keys.sh fail-fast
(rather than silently regenerate) when a running substrate is detected,
or putting the host keys behind a sentinel rather than presence-only
detection, would make the no-flag path safer too.

## Verification

- `bash -n install-docker.sh setup-linux.sh setup-mac.sh` clean.
- `./install-docker.sh` on the agent's already-provisioned host hits
  the `already_installed` fast-path and exits 0 with the expected
  message: *"Docker, Compose and Buildx already installed and working.
  Nothing to do."*
- `./setup-linux.sh --help` and `./setup-mac.sh --help` (the latter
  exits early on Linux because of the platform guard, but `bash -n`
  confirms its arg parser is well-formed) print the documented usage.
- `./setup-linux.sh --bogus` rejects the unknown argument with exit 2
  and a usage hint.
- `./setup-linux.sh --install-docker` post-fix: exec's
  install-docker.sh, prints the fast-path message, exits 0. Critically:
  `git status` after the run shows only the in-progress edit set; no
  keys generated, no setup state mutated.

Test of install-docker.sh from a *fresh* environment (no Docker
installed) was deferred — the agent's host is the substrate's own
maintenance host and has Docker provisioned. The fast-path is the only
path safely exercisable here. The Debian/Ubuntu and macOS provisioning
paths are documented but not yet tested end-to-end on a clean host;
flagging this for the auditor.

## Aggregate surface area

Files touched:
- `install-docker.sh` — created (186 lines), mode 0755.
- `setup-linux.sh` — `~/.docker` preflight + `--install-docker` flag
  (bootstrap-only).
- `setup-mac.sh` — `--install-docker` flag (bootstrap-only).
- `README.md` — Prerequisites section gains the `--install-docker`
  paragraph.

Files NOT touched (per brief constraints):
- `infra/scripts/generate-keys.sh` — see residual hazard above.
- macOS Colima resource defaults (`--cpu 4 --memory 8`) — preserved.
- The Troubleshooting section's "does not provision tools; only
  verifies them" sentence — preserved verbatim.
- No native Windows entry point added — README still notes WSL2 as
  the Windows path.
- No other Linux distros (Fedora, Arch, etc.) added to the installer.

## Risks and open issues

- **Residual no-flag hazard (described above):** running plain
  `./setup-linux.sh` on a host with empty `infra/keys/<role>/`
  directories silently regenerates SSH keys, which can desync from a
  running substrate. Out of scope here; recommend a follow-up section
  to add a sentinel/lock in generate-keys.sh that fails fast when a
  running substrate is detected.
- **install-docker.sh untested on a clean host.** The fast-path was
  exercised on the agent's host; the actual provisioning paths
  (Debian apt repo + buildx-plugin install; macOS Homebrew + Colima
  start) ship verbatim from the brief but have not been observed
  green end-to-end since this section's branch.
- **macOS Colima `--cpu 4 --memory 8`** is hard-coded in
  install-docker.sh per brief constraint. Hosts with very different
  resource budgets (low-end Apple Silicon laptops, or hosts hosting
  multiple substrate projects) may need to override; users should
  prefer running `colima start --cpu N --memory M` themselves and let
  install-docker.sh's "already running" check skip its own start.

## Suggested next steps and dependencies for downstream sections

- s003 (spec-catchup) is independent of this section.
- A future section to address the residual no-flag hazard around
  generate-keys.sh is recommended (see above).
- Consider also a section that exercises install-docker.sh end-to-end
  on a Debian/Ubuntu Crostini VM and a macOS host, before declaring
  the installer production-grade.

## Pointers to commits (in lieu of separate task reports)

The brief's task decomposition was light; I executed s002 directly on
the section branch with one commit per task plus the bug-fix commit:

- `5371653` — install-docker.sh verbatim (task 2.a).
- `db7d0a9` — `~/.docker` ownership preflight (task 2.b).
- `12f7635` — initial `--install-docker` flag (task 2.c, with the bug).
- `a033b0f` — fix: `--install-docker` is bootstrap-only,
  `exec install-docker.sh` and exit.
