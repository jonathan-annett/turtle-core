#!/bin/bash
# audit.sh <section-slug>
#
# Brings up an auditor for a section in its own compose project namespace.
# The auditor reads the audit brief at briefs/<section-slug>/audit.brief.md
# from main, builds tooling in the auditor.git repo, writes the audit report,
# and discharges. The auditor's container is removed on exit.
#
# After the auditor discharges, remind the human to tell the architect to
# fetch the auditor repo and ferry the audit report into main (spec §3.8).

set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "${1:-}" ]; then
    cat >&2 <<'EOF'
Usage: ./audit.sh <section-slug>

Example:
    ./audit.sh s001-hello-timestamps

The audit brief must already be committed by the architect at
briefs/<section-slug>/audit.brief.md on main.
EOF
    exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${repo_root}"

section="$1"
project_base="$(basename "${repo_root}")"
project="${project_base}-audit-${section}"

cleanup() {
    echo
    echo "Tearing down auditor (project=${project})..."
    docker compose -p "${project}" --profile ephemeral down -v --remove-orphans 2>&1 | sed 's/^/  /' || true
}
trap cleanup EXIT INT TERM

cat <<EOF

================================================================================
  Auditor commissioning  (relay to the auditor)
================================================================================

  Section:     ${section}
  Audit brief: briefs/${section}/audit.brief.md  (in /work after auditor starts)

  Paste this into the auditor at startup:

      Read /work/briefs/${section}/audit.brief.md and execute the audit.
      Your private workspace is /auditor (writable). The main repo at /work
      is read-only. Write the audit report to the auditor repo at the path
      named in the brief, commit and push, then discharge.

================================================================================
EOF

docker compose -p "${project}" --profile ephemeral run --rm auditor

cat <<EOF

================================================================================
  Auditor discharged.

  Next step: tell the architect to fetch the auditor repo and copy the
  audit report into main:

      docker compose exec architect bash -lc "
          git -C /auditor fetch && git -C /auditor pull &&
          cp /auditor/reports/${section}.audit.report.md \
             /work/briefs/${section}/audit.report.md &&
          cd /work && git add briefs/${section}/audit.report.md &&
          git commit -m 'audit: ferry report for ${section}' &&
          git push
      "

  (Or just attach to the architect via ./attach-architect.sh and ask
  claude-code to do it conversationally.)
================================================================================
EOF
