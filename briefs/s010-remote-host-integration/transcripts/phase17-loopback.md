# Phase 17 — substrate-loopback test run

Captured by running the s010 Phase 17 logic against two
alpine+sshd sidecar containers. 14/14 assertions passed.

See `infra/scripts/tests/test-substrate-end-to-end.sh` Phase 17
for the integrated version of the same checks.

```
----------------------------------------------------------------------
Phase 17 — substrate-loopback test
----------------------------------------------------------------------
PASS: sshd sidecar image built
note: sidecars: 172.20.0.2 / 172.20.0.3
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
----------------------------------------------------------------------
Summary: 14 passed, 0 failed
```
