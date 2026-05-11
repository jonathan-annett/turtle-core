#!/bin/bash
# audit.sh [<section-slug>]
#
# Brings up an auditor for a section in its own compose project namespace.
# The auditor reads the audit brief at briefs/<section-slug>/audit.brief.md
# from main, builds tooling in the auditor.git repo, writes the audit report,
# and discharges. The auditor's container is removed on exit.
#
# After the auditor discharges, remind the human to tell the architect to
# fetch the auditor repo and ferry the audit report into main (spec §3.8).
#
# Dual-mode per s008:
#
#   audit.sh <section-slug>   (commissioning mode)
#     - Verifies briefs/<section>/audit.brief.md exists on main (via the
#       architect clone) and fails fast if it doesn't.
#     - Generates a deterministic bootstrap prompt and passes it to the
#       auditor container as BOOTSTRAP_PROMPT. The auditor entrypoint
#       invokes claude non-interactively with that prompt before dropping
#       to a shell, eliminating the human-paste step.
#
#   audit.sh   (no argument — shell-only mode)
#     - Skips the brief check; preserves the "drop straight to a shell"
#       path for manual inspection / debugging.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${repo_root}"

# shellcheck source=infra/scripts/lib/check-brief.sh
source "${repo_root}/infra/scripts/lib/check-brief.sh"

if [ "$#" -gt 1 ]; then
    cat >&2 <<'EOF'
Usage: ./audit.sh [<section-slug>]

With <section-slug>: verify the audit brief exists, then commission the
                     auditor non-interactively with a deterministic
                     bootstrap prompt.

Without argument:    drop straight to a shell in the auditor container for
                     manual inspection / debugging.

Example:
    ./audit.sh s001-hello-timestamps
EOF
    exit 1
fi

section="${1:-}"
project_base="$(basename "${repo_root}")"

if [ -n "${section}" ]; then
    project="${project_base}-audit-${section}"
else
    project="${project_base}-audit-shell-$$"
fi

# Argument-mode: verify audit brief exists before doing anything expensive.
brief_path=""
if [ -n "${section}" ]; then
    brief_path="briefs/${section}/audit.brief.md"
    check_brief_exists "${brief_path}" || exit $?
fi

cleanup() {
    echo
    echo "Tearing down auditor (project=${project})..."
    docker compose -p "${project}" --profile ephemeral down -v --remove-orphans 2>&1 | sed 's/^/  /' || true
}
trap cleanup EXIT INT TERM

if [ -n "${section}" ]; then
    # Argument mode: build the deterministic bootstrap prompt and pass it
    # via env to the auditor. The auditor entrypoint (s008 8.e) detects
    # BOOTSTRAP_PROMPT and invokes claude non-interactively.
    #
    # s011 11.f: BRIEF_PATH is passed alongside BOOTSTRAP_PROMPT so the
    # entrypoint can read the brief's "Required tool surface" field and
    # translate it into --allowed-tools.
    bootstrap_prompt="Read /work/${brief_path} and execute the audit per /methodology/auditor-guide.md (symlinked as /work/CLAUDE.md). Your private workspace is /auditor (writable). The main repo at /work is read-only. Write the audit report to the auditor repo at the path named in the brief, commit and push, then discharge."

    echo "Commissioning auditor against ${brief_path}"
    BOOTSTRAP_PROMPT="${bootstrap_prompt}" \
    BRIEF_PATH="/work/${brief_path}" \
        docker compose -p "${project}" --profile ephemeral run --rm \
            -e BOOTSTRAP_PROMPT \
            -e BRIEF_PATH \
            auditor
else
    # Shell-only mode: legacy path. Print a manual-mode banner and drop
    # into the auditor shell.
    cat <<'EOF'

================================================================================
  Auditor shell (no section slug supplied — manual mode)
================================================================================

  Run 'claude' inside the auditor. Suggested prompt skeleton:

      Read /work/briefs/<section>/audit.brief.md and execute the audit.
      Your private workspace is /auditor (writable). The main repo at
      /work is read-only. Write the audit report to the auditor repo
      at the path named in the brief, commit and push, then discharge.

================================================================================
EOF
    docker compose -p "${project}" --profile ephemeral run --rm auditor
fi

cat <<EOF

================================================================================
  Auditor discharged.

  Next step: tell the architect to fetch the auditor repo and copy the
  audit report into main:

      docker compose exec architect bash -lc "
          git -C /auditor fetch && git -C /auditor pull &&
          cp /auditor/reports/${section:-<section>}.audit.report.md \\
             /work/briefs/${section:-<section>}/audit.report.md &&
          cd /work && git add briefs/${section:-<section>}/audit.report.md &&
          git commit -m 'audit: ferry report for ${section:-<section>}' &&
          git push
      "

  (Or just attach to the architect via ./attach-architect.sh and ask
  claude-code to do it conversationally.)
================================================================================
EOF
