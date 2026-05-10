#!/bin/bash
# infra/scripts/agent-ssh-audited.sh
#
# Audit-logging wrapper for ssh, mounted read-only at /usr/local/bin/ssh
# in each role container (s010 10.d). Standard PATH ordering
# (/usr/local/bin before /usr/bin) ensures this wrapper intercepts every
# `ssh ...` invocation — interactive or not, login shell or `bash -c`.
#
# Per s010 design call 4 this is hygiene, not a guardrail. It logs the
# command line to:
#   - stderr (so the agent transcript captures it)
#   - ${WORKDIR:-/work}/.substrate-ssh.log (so per-pair artifacts retain
#     a record outside the transcript)
# then exec's /usr/bin/ssh with $@ unchanged. Existing SSH behaviour —
# stdio, exit code, signal handling — is preserved by exec.
#
# %q quoting in the log line preserves arguments containing spaces or
# shell metacharacters (esptool / pio invocations sometimes have them),
# so the log can be re-read or replayed unambiguously.

ts=$(date -u +%FT%TZ)
log="${WORKDIR:-/work}/.substrate-ssh.log"
{
    printf '[%s] ssh' "${ts}"
    for arg in "$@"; do
        printf ' %q' "${arg}"
    done
    printf '\n'
} | tee -a "${log}" >&2

exec /usr/bin/ssh "$@"
