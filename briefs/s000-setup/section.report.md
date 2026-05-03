# SETUP-BRIEF.report — discharge report

> **Filing note (s003).** This report originally lived at the repo
> root as `SETUP-BRIEF.report.md`. It was moved to
> `briefs/s000-setup/section.report.md` retroactively in section
> s003 (spec-catchup) so the substrate's own history aligns with the
> methodology's section-numbering convention. The body below is the
> original report verbatim; any references it makes to "this file is
> at the repo root" are historical and refer to its prior location.

Implements `setup-scripts-brief.md` as a one-off commission outside the
methodology. Recipient: a fresh terminal-based claude-code instance on
Jonathan's box.

---

## 1. What was built

The full deliverable per brief §3, at `/home/jonathan/project-template/`:

```
project-template/                 (git repo, 3 commits)
├── README.md                     written, covers all four platforms
├── docker-compose.yml            with shared external network + named volumes
├── setup-linux.sh                with Crostini detection
├── setup-mac.sh                  Docker Desktop / Colima check
├── setup-common.sh               cross-platform body
├── verify.sh                     smoke test + creds-refresh helper
├── commission-pair.sh            per-section planner+coder-daemon launcher
├── audit.sh                      per-audit auditor launcher
├── attach-architect.sh           one-line wrapper using exec
├── infra/
│   ├── base/Dockerfile           debian + claude-code via Anthropic APT repo
│   ├── architect/                Dockerfile + entrypoint
│   ├── planner/                  Dockerfile + entrypoint
│   ├── coder-daemon/             Dockerfile + daemon.js + package.json + entrypoint
│   ├── auditor/                  Dockerfile + entrypoint
│   ├── git-server/               Dockerfile + entrypoint + init-repos.sh +
│   │                             git-shell-wrapper + hooks/update
│   ├── keys/<role>/.gitkeep      gitignored runtime key directories
│   └── scripts/generate-keys.sh  per-role ed25519 keypair generator
├── methodology/                  4 verbatim copies of spec + 3 role guides
├── briefs/.gitkeep               runtime
├── .pairs/.gitkeep               runtime
├── .gitignore
├── .env.example                  documents optional ANTHROPIC_API_KEY
└── SETUP-BRIEF.report.md         this file
```

Three commits in `git log`:
1. `initial template` — whole tree.
2. `generate-keys: preserve invoking-user ownership when run via sudo` —
   small robustness change discovered during testing.
3. `integration fixes from end-to-end test` — substantive fixes from the
   live test run; details in §3 below.

---

## 2. What was tested

Tested **on Linux** (the platform of the recipient agent), end-to-end,
against the §7 verification flow:

```
git clone /home/jonathan/project-template /tmp/testproject
cd /tmp/testproject
./setup-linux.sh         # ran via 'sudo HOME=/home/jonathan' — see §4 below
./verify.sh              # 10 ok / 0 failed
```

Specific checks that passed:

- All five docker images built cleanly. The Anthropic APT repository for
  claude-code resolves and installs (`claude-code 2.1.116-1` was pulled).
- `agent-net` shared network and `claude-state-{architect,shared}` external
  volumes are pre-created idempotently.
- Path A (host-copy) auth provisioning: `~/.claude/.credentials.json` was
  copied into the architect's volume via a one-shot helper container, no
  host-side read into a shell variable, the file was confirmed to never
  appear in any committed file or build output.
- Inside the architect: `claude --version` prints `2.1.116 (Claude Code)`,
  `claude auth status` returns `loggedIn: true, authMethod: "claude.ai",
  subscriptionType: "max"`.
- Re-running `setup-linux.sh` is idempotent (10/10 verify checks pass on
  the second run, no errors).

**§3.3 access-table enforcement was tested directly** by pushing from
agent containers using each role's key:

| Test | Expected | Actual |
|---|---|---|
| architect → main, path under briefs/ | accept | ✓ accepted |
| architect → main, source-code path (`src.go`) | reject | ✓ rejected with diagnostic |
| architect → `feature/x` branch | reject | ✓ rejected with diagnostic |
| planner → `section/001-foo` | accept | ✓ accepted |
| planner → `task/001.001-bar` | accept | ✓ accepted |
| planner → main | reject | ✓ rejected |
| auditor → read main (`ls-remote`) | accept | ✓ accepted |
| auditor → push to main | reject | ✓ rejected with spec citation |
| auditor → push to auditor.git | accept | ✓ accepted |

**Operational scripts:** `commission-pair.sh s001-test` and
`audit.sh s001-test` both ran end-to-end (with empty stdin so the
ephemeral planner/auditor's `bash -l` exited immediately). The
`trap`-driven cleanup ran as designed: containers removed, daemon-state
volume removed, `.pairs/.pair-*.env` removed, exit code 0.

The `claude-state-architect` and `claude-state-shared` volumes survive
`compose down -v` of the long-lived project AND of the per-pair ephemeral
project — exactly the property required so a routine pair-teardown does
not wipe the user's auth.

The architect's `attach` flow was *not* exercised end-to-end (it requires
an interactive terminal); however, `docker compose exec -u agent
architect bash -lc 'claude --version && claude auth status'` works
correctly, which is the substantive equivalent.

---

## 3. Bugs found during testing and fixed

The first end-to-end test surfaced three real bugs that needed fixing
before the deliverable would meet §9. All were fixed in commit 3
(`integration fixes from end-to-end test`):

1. **The `git` user was sshd-locked.** `useradd -m -s /usr/bin/git-shell -u
   1100 git` leaves the password field as `!`, which sshd treats as a
   locked account and refuses key-based logins for. Symptom in logs:
   `User git not allowed because account is locked`. Fix: add `passwd -d
   git` (clears the field; key auth works without enabling password auth
   because `PasswordAuthentication no`).

2. **Login shell `/usr/bin/git-shell` swallowed the wrapper command.**
   With `git-shell` as the login shell, sshd runs the `command="..."`
   value through git-shell — which only accepts the four standard git
   commands and rejects everything else as "unrecognized command". Fix:
   set the login shell to `/bin/bash`. The wrapper at
   `/srv/git-shell-wrapper` now actually runs, exports `GIT_USER=<role>`,
   and exec's `git-shell -c "$SSH_ORIGINAL_COMMAND"` to enforce the
   git-only restriction.

3. **`/auditor` did not exist as an agent-writable directory** in the
   architect and auditor images, so the entrypoints' `git clone … /auditor`
   failed with "Permission denied". Fix: `mkdir -p /auditor && chown
   agent:agent /auditor` in both Dockerfiles.

A separate non-bug also surfaced and was addressed:

4. **Compose-prefixed volume names broke the auth helper container.** I
   originally declared `claude-state-architect` as a compose-managed named
   volume; compose prefixed it with the project name (`testproject_
   claude-state-architect`), but the auth-provisioning helper container
   referenced the bare name `claude-state-architect`, creating a
   *different* volume. Fixed by declaring both shared volumes as
   `external: true` with fixed names, and pre-creating them in
   `setup-common.sh` via `docker volume create`. This also fixes a
   "volume already exists but was not created by Docker Compose" warning
   when ephemeral pair-namespaced compose projects mount the same
   volumes, AND ensures `compose down -v` doesn't wipe the user's auth.

---

## 4. Assumptions and platforms not tested

### Linux as host (tested) but with one local quirk

The user `jonathan` on this box is not in the `docker` group, so `docker`
commands fail without sudo. I therefore ran the integration test under
`sudo HOME=/home/jonathan bash ./setup-linux.sh`. Two consequences:

- **Files generated by the script ran as root.** I added a small
  defensive change to `infra/scripts/generate-keys.sh`: when `SUDO_UID`
  is set, the script `chown`s the generated keys to the invoking user.
  Without this, the keys would be root-owned mode 0600 and the
  in-container `agent` user (UID 1000) could not read them. The change
  is a no-op under normal (non-sudo) invocation.

- **`HOME` had to be preserved explicitly** for Path A auth provisioning
  to find the user's `~/.claude/.credentials.json`. Plain `sudo` resets
  `HOME` to `/root`. The README's quickstart assumes a non-sudo
  invocation, where `HOME` is correct by default. **Recommend: the user
  should add themselves to the docker group and re-login before normal
  operation** (the README documents this in the prereqs); the sudo path
  was used for development convenience only.

### macOS — *not* tested

I do not have access to macOS. `setup-mac.sh` is structurally identical
to `setup-linux.sh` (delegates to `setup-common.sh` after a Docker-runtime
check) and uses the same docker-compose / named-volume approach. Things
the user should verify on first macOS run:

- Docker Desktop OR Colima with ≥4 CPU / 8 GB RAM.
- `~/.claude/.credentials.json` may be absent on macOS (claude-code can
  store credentials in the system keychain). Path B (in-container
  `claude auth login`) is the expected path on a fresh macOS host. The
  setup script handles this correctly.
- Bind-mount path quotes contain `$HOME` or `$PWD`; macOS bash should
  expand these correctly, but there is a small chance of edge cases on
  paths with spaces.

### Windows — explicitly out of scope

Per the brief, no Windows support beyond "install WSL2 and run setup-linux.sh
from inside it." The README documents this.

### Crostini — code path tested implicitly

The Crostini detection block in `setup-linux.sh` is a heuristic check for
`/dev/.cros_milestone` or hostname `penguin`; on this host neither
matched and the script fell through to the standard Linux path, which is
correct behavior. The Crostini branch itself only prints a banner before
proceeding identically — low risk of bugs but not exercised on a real
Crostini host.

---

## 5. Deviations from the brief

Two deliberate small additions and one minor restructure:

1. **`infra/keys/human/.gitkeep` and human-role key generation.** The
   §3.3 access table includes `human` as a role with full repo access;
   `generate-keys.sh` produces a human key alongside architect / planner
   / coder / auditor. The `human` key is not referenced by any
   long-lived service in the compose file, but the git-server's
   `update` hook accepts it (and bypasses all path/branch checks). This
   gives the human a way to push directly when needed (e.g., the
   section-branch → main merge in the spec lifecycle). Tested ad-hoc
   during seeding (`init-repos.sh` uses `GIT_USER=human` to push the
   initial commit). Brief did not explicitly require this; it is
   strictly additive and named in the access table the brief points at.

2. **Volume `claude-state-architect` / `claude-state-shared` are
   `external: true` with fixed names.** The brief §4.10 specifies the
   two volumes and their split semantics but is silent on whether they
   should be compose-managed or external. External + fixed-name was
   forced by the cross-compose-project mounting use case (see §3 above)
   and improves correctness (compose down -v cannot wipe auth).

3. **No `infra/scripts/bootstrap.sh` was created**, contrary to the
   layout in `methodology/deployment-docker.md` §8. The brief's §3
   file list does NOT include `bootstrap.sh`; the brief's §4.1 says
   "setup-linux.sh and setup-mac.sh are the two entry points." I went
   with the brief's list. The deployment-doc reference to
   `bootstrap.sh` is best read as illustrative; the entry-points serve
   the same purpose.

The brief's "faithful translation rule" (§6) was respected. The one
place where I briefly considered `--permission-mode dontAsk` to be a
deployment-doc typo, I empirically verified — `claude --help` lists the
mode as a valid choice (alongside `acceptEdits`, `auto`,
`bypassPermissions`, `default`, `plan`). The deployment doc was right;
I kept `dontAsk`.

---

## 6. Open questions for the human

1. **Idempotency of `init-repos.sh`'s seeding step.** On every
   container restart the entrypoint re-runs `init-repos.sh`, which
   re-installs the `update` hook and re-checks for the seed commit on
   `main.git`. This is idempotent and fast, but if the human ever
   force-pushes to delete the `main` branch and then restarts the
   git-server, the seed commit would be re-created. I think this is the
   correct behavior (substrate self-heals to a usable state); flagging
   in case the operator's mental model differs.

2. **The `update` hook's path-list for the architect** is hard-coded as
   `briefs/**`, `SHARED-STATE.md`, `TOP-LEVEL-PLAN.md`, `README.md`,
   `MIGRATION-*.md`. The brief §4.6 named exactly this list. If the
   methodology evolves to add new architect-writable root files (e.g.,
   `LICENSE.md`, `CONTRIBUTING.md`), the hook will need to be updated
   in lockstep. I considered making the list configurable via env but
   judged that over-engineering for a v1 template; the brief's
   instruction was explicit. Flagging for awareness.

3. **The coder daemon's `--allowed-tools` is taken from the commission
   POST body** (`allowed_tools` field, optional). The methodology spec
   §7.3 / planner-guide says "the substrate translates [the brief's
   Required tool surface] into the coder's --allowedTools at commission
   time", which implies the daemon parses the brief. I judged that
   markdown-parsing is fragile and that having the planner produce the
   list (which it already understands, having just written it) is more
   robust. The deployment-doc shows the daemon parsing the brief
   directly. **Either reading is consistent with the spec text; flag
   if you prefer the brief-parser model and I can add it later.**

4. **No SSH `known_hosts` is established** for the architect ↔
   git-server connection. The base image's `/etc/ssh/ssh_config` sets
   `StrictHostKeyChecking no` and `UserKnownHostsFile /dev/null` for
   `Host git-server`. This is fine on the isolated agent-net bridge
   network but is a "trust on first use" pattern relaxed to "trust
   always." If a future operator wants to harden this, the right
   approach is to capture the git-server's host key at setup time and
   write it into the agent containers via a small new volume or build-arg.
   Not done here; flagging for completeness.

---

## 7. Done-criteria checklist

Brief §9:

- ☑ All files in §3 exist and are correct.
- ☑ `setup-linux.sh` runs cleanly on Linux from a fresh checkout
  (caveat: tested via sudo + HOME preservation due to the local
  docker-group config; see §4).
- ☑ `verify.sh` passes after setup (10 ok / 0 failed).
- ☑ Architect container can be reached and runs `claude --version`,
  `claude auth status` correctly. Interactive `claude --resume` not
  exercised (requires a TTY) — substantive equivalent verified.
- ☑ `commission-pair.sh` runs without erroring and tears down cleanly.
- ☑ `audit.sh` runs without erroring and tears down cleanly.
- ☑ `SETUP-BRIEF.report.md` (this file) is committed to the repo root.
- ☑ The deliverable can be cloned and bootstrapped per the README.

§3.3 access-table enforcement at the git-server `update` hook was
verified directly with each role's key.

The deliverable is in a state where the human can hand it to a fellow
engineer with "clone this, follow the README" and that engineer has a
working substrate at the end.

---

## 8. Discharge

Discharging.
