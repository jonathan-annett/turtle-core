#!/bin/bash
# Tests for the shell port of the "Required tool surface" parser
# (infra/scripts/lib/parse-tool-surface.sh). Mirrors the JS test cases
# under infra/coder-daemon/test/parse-tool-surface.test.js to keep the
# two implementations in lockstep.
#
# Run:
#   bash infra/scripts/tests/test-parse-tool-surface.sh
#
# Requires jq (present in agent-base; on the host install via
# `sudo apt-get install -y jq` if missing).

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
parser="${repo_root}/infra/scripts/lib/parse-tool-surface.sh"
test_pid=$$
test_dir="/tmp/turtle-core-test-pts-${test_pid}"
mkdir -p "${test_dir}"
trap 'rm -rf "${test_dir}"' EXIT

if [ -t 1 ]; then
    GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
else
    GREEN=''; RED=''; NC=''
fi
pass_count=0
fail_count=0
pass() { printf "${GREEN}PASS${NC}: %s\n" "$*"; pass_count=$((pass_count + 1)); }
fail() { printf "${RED}FAIL${NC}: %s\n" "$*"; fail_count=$((fail_count + 1)); }

# Helpers: expect_ok <name> <brief-content> <expected-csv>
#          expect_err <name> <brief-content> <stderr-regex>
expect_ok() {
    local name="$1" brief="$2" expected="$3"
    local file="${test_dir}/${name}.md"
    printf '%s' "${brief}" > "${file}"
    local out rc
    out=$(bash "${parser}" "${file}" 2>/dev/null) || rc=$?
    rc="${rc:-0}"
    if [ "${rc}" -ne 0 ]; then
        fail "${name}: expected success, got rc=${rc}"
        return
    fi
    if [ "${out}" != "${expected}" ]; then
        fail "${name}: expected '${expected}', got '${out}'"
        return
    fi
    pass "${name}"
}

expect_err() {
    local name="$1" brief="$2" pattern="$3"
    local file="${test_dir}/${name}.md"
    printf '%s' "${brief}" > "${file}"
    local stderr rc
    stderr=$(bash "${parser}" "${file}" 2>&1 >/dev/null) || rc=$?
    rc="${rc:-0}"
    if [ "${rc}" -eq 0 ]; then
        fail "${name}: expected non-zero exit"
        return
    fi
    if ! printf '%s' "${stderr}" | grep -qE "${pattern}"; then
        fail "${name}: stderr did not match /${pattern}/; got: ${stderr}"
        return
    fi
    pass "${name}"
}

# -----------------------------------------------------------------------
# Happy paths
# -----------------------------------------------------------------------

expect_ok "yaml-bullet" "$(cat <<'EOF'
# Task brief

- **Touch surface.** src/foo.js
- **Required tool surface.**
  ```yaml
  - Read
  - Edit
  - Bash(git *)
  ```
- **Constraints.** none
EOF
)" "Read,Edit,Bash(git *)"

expect_ok "json-heading" "$(cat <<'EOF'
## Required tool surface

```json
["Read", "Write", "Bash(npm test)"]
```
EOF
)" "Read,Write,Bash(npm test)"

expect_ok "h3-heading" "$(cat <<'EOF'
### Required tool surface
```
- Read
- Edit
```
EOF
)" "Read,Edit"

expect_ok "colon-variant" "$(cat <<'EOF'
- **Required tool surface:**
  ```yaml
  - Read
  ```
EOF
)" "Read"

expect_ok "prose-between-marker-and-fence" "$(cat <<'EOF'
## Required tool surface

A short prose blurb.

```yaml
- Read
- Bash(make test)
```
EOF
)" "Read,Bash(make test)"

expect_ok "multiline-json" "$(cat <<'EOF'
## Required tool surface

```json
[
  "Read",
  "Edit",
  "Bash(git status:*)"
]
```
EOF
)" "Read,Edit,Bash(git status:*)"

# -----------------------------------------------------------------------
# Failure paths
# -----------------------------------------------------------------------

expect_err "no-marker" "$(cat <<'EOF'
# Task brief
- **Touch surface.** src/foo.js
EOF
)" "no 'Required tool surface' field"

expect_err "no-fence" "$(cat <<'EOF'
- **Required tool surface.** Read, Edit, Write.
- **Constraints.** none
EOF
)" "no fenced code block follows"

expect_err "empty-fence" "$(cat <<'EOF'
- **Required tool surface.**
  ```yaml
  ```
EOF
)" "code block is empty"

expect_err "malformed-json" "$(cat <<'EOF'
## Required tool surface
```json
["Read", "Edit",
```
EOF
)" "not valid JSON"

expect_err "stops-at-next-field" "$(cat <<'EOF'
- **Required tool surface.**
- **Verification.**
  ```bash
  npm test
  ```
EOF
)" "no fenced code block follows"

expect_err "empty-list-yaml" "$(cat <<'EOF'
## Required tool surface
```yaml
# nothing
```
EOF
)" "list is empty after parsing"

expect_err "empty-list-json" "$(cat <<'EOF'
## Required tool surface
```json
[]
```
EOF
)" "not valid JSON or is empty"

expect_err "not-list-item-yaml" "$(cat <<'EOF'
- **Required tool surface.**
  ```yaml
  - Read
  not-a-list-item
  ```
EOF
)" "not in '- item' form"

# missing-file is tested directly (expect_err writes a file)
nonexistent="${test_dir}/does-not-exist.md"
if out=$(bash "${parser}" "${nonexistent}" 2>&1 >/dev/null) || true; then
    if printf '%s' "${out}" | grep -q "brief not found"; then
        pass "missing-file"
    else
        fail "missing-file: stderr did not match /brief not found/; got: ${out}"
    fi
fi

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------

echo
echo "Results: ${pass_count} passed, ${fail_count} failed."
[ "${fail_count}" -eq 0 ] && exit 0 || exit 1
