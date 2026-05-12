#!/bin/bash
# Tests for the s013 (F50) platform composition machinery:
#   - infra/scripts/lib/parse-platforms.sh
#   - infra/scripts/resolve-platforms.sh
#   - infra/scripts/compose-image.sh
#   - infra/scripts/validate-tool-surface.sh
#
# Run:
#   bash infra/scripts/tests/test-platform-composition.sh
#
# Requires: docker (for compose-image / validate-tool-surface tests),
# sha256sum, jq, mikefarah/yq:4 image (for parse-platforms JSON form
# — actually jq, since the parser uses jq). The parse-platforms and
# resolve-platforms tests do not require docker; only the composition
# / validation tests do. The harness skips the docker-dependent
# section with a clear message if agent-base is missing.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
parse_platforms="${repo_root}/infra/scripts/lib/parse-platforms.sh"
resolve_platforms="${repo_root}/infra/scripts/resolve-platforms.sh"
compose_image="${repo_root}/infra/scripts/compose-image.sh"
validate_tool_surface="${repo_root}/infra/scripts/validate-tool-surface.sh"

test_pid=$$
test_dir="/tmp/turtle-core-test-pc-${test_pid}"
mkdir -p "${test_dir}"
trap 'rm -rf "${test_dir}"' EXIT

if [ -t 1 ]; then
    GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; NC=''
fi
pass_count=0
fail_count=0
skip_count=0
pass() { printf "${GREEN}PASS${NC}: %s\n" "$*"; pass_count=$((pass_count + 1)); }
fail() { printf "${RED}FAIL${NC}: %s\n" "$*"; fail_count=$((fail_count + 1)); }
skip() { printf "${YELLOW}SKIP${NC}: %s\n" "$*"; skip_count=$((skip_count + 1)); }

# ===========================================================================
# parse-platforms.sh
# ===========================================================================

# expect_parse_ok <name> <file-content> <marker> <expected-csv>
expect_parse_ok() {
    local name="$1" content="$2" marker="$3" expected="$4"
    local file="${test_dir}/${name}.md"
    printf '%s' "${content}" > "${file}"
    local out rc
    out=$(bash "${parse_platforms}" "${file}" "${marker}" 2>/dev/null) || rc=$?
    rc="${rc:-0}"
    if [ "${rc}" -ne 0 ]; then
        fail "parse-platforms ${name}: expected rc=0, got rc=${rc}"
        return
    fi
    if [ "${out}" != "${expected}" ]; then
        fail "parse-platforms ${name}: expected '${expected}', got '${out}'"
        return
    fi
    pass "parse-platforms ${name}"
}

# expect_parse_rc <name> <file-content> <marker> <expected-rc>
expect_parse_rc() {
    local name="$1" content="$2" marker="$3" expected_rc="$4"
    local file="${test_dir}/${name}.md"
    printf '%s' "${content}" > "${file}"
    local rc
    bash "${parse_platforms}" "${file}" "${marker}" >/dev/null 2>&1 || rc=$?
    rc="${rc:-0}"
    if [ "${rc}" != "${expected_rc}" ]; then
        fail "parse-platforms ${name}: expected rc=${expected_rc}, got rc=${rc}"
        return
    fi
    pass "parse-platforms ${name} (rc=${rc})"
}

expect_parse_ok "heading-yaml" "$(cat <<'EOF'
## Required platforms

```yaml
- node-extras
- python-extras
```
EOF
)" "Required platforms" "node-extras,python-extras"

expect_parse_ok "bullet-yaml" "$(cat <<'EOF'
- **Required platforms.**
  ```yaml
  - go
  ```
EOF
)" "Required platforms" "go"

expect_parse_ok "json-array" "$(cat <<'EOF'
## Required platforms

```json
["node-extras", "python-extras"]
```
EOF
)" "Required platforms" "node-extras,python-extras"

expect_parse_ok "version-pin" "$(cat <<'EOF'
## Required platforms

```yaml
- python-extras@3.11
- node-extras
```
EOF
)" "Required platforms" "python-extras@3.11,node-extras"

expect_parse_ok "tlp-platforms-marker" "$(cat <<'EOF'
# TOP-LEVEL-PLAN

## Platforms

```yaml
- node-extras
```
EOF
)" "Platforms" "node-extras"

expect_parse_ok "empty-fence" "$(cat <<'EOF'
## Required platforms

```yaml
```
EOF
)" "Required platforms" ""

expect_parse_rc "marker-absent" "$(cat <<'EOF'
## Some other heading

stuff
EOF
)" "Required platforms" 10

expect_parse_rc "marker-no-fence" "$(cat <<'EOF'
## Required platforms

just prose, no fence

## Next heading
EOF
)" "Required platforms" 1

expect_parse_rc "unterminated-fence" "$(cat <<'EOF'
## Required platforms

```yaml
- foo
EOF
)" "Required platforms" 1

# ===========================================================================
# resolve-platforms.sh
# ===========================================================================

rp_root="${test_dir}/resolve-test"
mkdir -p "${rp_root}/.substrate-state" "${rp_root}/briefs/sX"

write_tlp() {
    if [ -z "$1" ]; then
        rm -f "${rp_root}/TOP-LEVEL-PLAN.md"
    else
        printf '%s' "$1" > "${rp_root}/TOP-LEVEL-PLAN.md"
    fi
}
write_state() {
    if [ -z "$1" ]; then
        rm -f "${rp_root}/.substrate-state/platforms.txt"
    else
        printf '%s' "$1" > "${rp_root}/.substrate-state/platforms.txt"
    fi
}
write_brief() {
    if [ -z "$2" ]; then
        rm -f "${rp_root}/briefs/sX/$1.md"
    else
        printf '%s' "$2" > "${rp_root}/briefs/sX/$1.md"
    fi
}

# expect_resolve_ok <name> <brief-path-or-empty> <expected-csv>
expect_resolve_ok() {
    local name="$1" brief="$2" expected="$3"
    local out rc
    out=$(bash "${resolve_platforms}" "${brief}" "${rp_root}/TOP-LEVEL-PLAN.md" "${rp_root}/.substrate-state" 2>/dev/null) || rc=$?
    rc="${rc:-0}"
    if [ "${rc}" -ne 0 ]; then
        fail "resolve-platforms ${name}: expected rc=0, got rc=${rc}"
        return
    fi
    if [ "${out}" != "${expected}" ]; then
        fail "resolve-platforms ${name}: expected '${expected}', got '${out}'"
        return
    fi
    pass "resolve-platforms ${name}"
}

# expect_resolve_fail <name> <brief-path-or-empty>
expect_resolve_fail() {
    local name="$1" brief="$2"
    local rc
    bash "${resolve_platforms}" "${brief}" "${rp_root}/TOP-LEVEL-PLAN.md" "${rp_root}/.substrate-state" >/dev/null 2>&1 || rc=$?
    rc="${rc:-0}"
    if [ "${rc}" -eq 0 ]; then
        fail "resolve-platforms ${name}: expected non-zero exit"
        return
    fi
    pass "resolve-platforms ${name} (rc=${rc})"
}

# Scenario 1: TOP-LEVEL-PLAN.md has Platforms, section subset OK
write_tlp "$(cat <<'EOF'
## Platforms

```yaml
- node-extras
- python-extras
```
EOF
)"
write_state ""
write_brief "subset-ok" "$(cat <<'EOF'
- **Required platforms.**
  ```yaml
  - node-extras
  ```
EOF
)"
expect_resolve_ok "section-subset-ok" "${rp_root}/briefs/sX/subset-ok.md" "node-extras"

# Scenario 2: section silent → inherit project superset
expect_resolve_ok "section-silent-inherits" "" "node-extras,python-extras"

# Scenario 3: subset violation
write_brief "violation" "$(cat <<'EOF'
- **Required platforms.**
  ```yaml
  - rust
  ```
EOF
)"
expect_resolve_fail "subset-violation" "${rp_root}/briefs/sX/violation.md"

# Scenario 4: s009 fallback (no TLP, has platforms.txt)
write_tlp ""
write_state "default
node-extras
"
expect_resolve_ok "s009-fallback-section-silent" "" "node-extras"

# Scenario 5: nothing anywhere
write_state ""
expect_resolve_ok "no-superset-no-section" "" ""

# Scenario 6: explicit empty section override (declares "I need no platforms")
write_tlp "$(cat <<'EOF'
## Platforms

```yaml
- node-extras
```
EOF
)"
write_brief "explicit-empty" "$(cat <<'EOF'
- **Required platforms.**
  ```yaml
  ```
EOF
)"
expect_resolve_ok "section-explicit-empty" "${rp_root}/briefs/sX/explicit-empty.md" ""

# Scenario 7: version-pin subset check (python-extras@3.11 ⊆ python-extras)
write_tlp "$(cat <<'EOF'
## Platforms

```yaml
- python-extras
```
EOF
)"
write_brief "version-pin-subset" "$(cat <<'EOF'
- **Required platforms.**
  ```yaml
  - python-extras@3.11
  ```
EOF
)"
expect_resolve_ok "version-pin-subset-ok" "${rp_root}/briefs/sX/version-pin-subset.md" "python-extras@3.11"

# ===========================================================================
# compose-image.sh & validate-tool-surface.sh — require docker + agent-base
# ===========================================================================

if ! command -v docker >/dev/null 2>&1; then
    skip "compose-image / validate-tool-surface — docker not available"
elif ! docker info >/dev/null 2>&1; then
    skip "compose-image / validate-tool-surface — docker daemon not reachable"
elif ! docker image inspect agent-base:latest >/dev/null 2>&1; then
    skip "compose-image / validate-tool-surface — agent-base:latest missing (run setup first)"
else
    # ----- compose-image hash semantics -----

    # Build a baseline image (onboarder + no platforms — cheapest).
    onboarder_tag=$(bash "${compose_image}" onboarder "" 2>/dev/null) || {
        fail "compose-image baseline build (onboarder empty)"
        onboarder_tag=""
    }
    if [ -n "${onboarder_tag}" ]; then
        pass "compose-image onboarder-empty produces tag (${onboarder_tag})"

        # Idempotence: a second call hits cache and returns the same tag.
        onboarder_tag2=$(bash "${compose_image}" onboarder "" 2>/dev/null)
        if [ "${onboarder_tag}" = "${onboarder_tag2}" ]; then
            pass "compose-image idempotence (onboarder empty: same tag)"
        else
            fail "compose-image idempotence: ${onboarder_tag} != ${onboarder_tag2}"
        fi
    fi

    # Order-invariance: planner+(node,python) == planner+(python,node).
    pa=$(bash "${compose_image}" planner "node-extras,python-extras" 2>/dev/null) || pa=""
    pb=$(bash "${compose_image}" planner "python-extras,node-extras" 2>/dev/null) || pb=""
    pc=$(bash "${compose_image}" planner "node-extras,default,python-extras,node-extras" 2>/dev/null) || pc=""
    if [ -n "${pa}" ] && [ "${pa}" = "${pb}" ] && [ "${pb}" = "${pc}" ]; then
        pass "compose-image order-and-dedupe invariance (planner: 3 forms → same tag ${pa})"
    else
        fail "compose-image order-and-dedupe: pa=${pa} pb=${pb} pc=${pc}"
    fi

    # Different platform sets produce different tags.
    pa_node=$(bash "${compose_image}" planner "node-extras" 2>/dev/null) || pa_node=""
    if [ -n "${pa}" ] && [ -n "${pa_node}" ] && [ "${pa}" != "${pa_node}" ]; then
        pass "compose-image different sets → different tags (${pa} vs ${pa_node})"
    else
        fail "compose-image different-sets: same tag for different platforms"
    fi

    # Registry-entry content-hash invalidation: tweak a YAML, hash changes.
    yaml="${repo_root}/methodology/platforms/node-extras.yaml"
    yaml_backup="${test_dir}/node-extras.yaml.bak"
    cp "${yaml}" "${yaml_backup}"
    # Append a harmless comment line — changes file bytes → hash should change.
    echo "# s013 test marker $(date +%s%N)" >> "${yaml}"
    pa_modified=$(bash "${compose_image}" planner "node-extras" 2>/dev/null) || pa_modified=""
    cp "${yaml_backup}" "${yaml}"
    if [ -n "${pa_modified}" ] && [ "${pa_node}" != "${pa_modified}" ]; then
        pass "compose-image registry-entry-change invalidates cache (${pa_node} → ${pa_modified})"
    else
        fail "compose-image registry-entry-change: hash did not change (pa_node=${pa_node} pa_modified=${pa_modified})"
    fi
    # Restore by re-composing — agnostic to whether the rebuild produced
    # pa_node again (it should, since we restored bytes).

    # ----- validate-tool-surface positive / negative / empty -----

    if [ -n "${onboarder_tag}" ]; then
        # Positive: bash and git should both be on the onboarder image.
        if bash "${validate_tool_surface}" "${onboarder_tag}" "Read,Edit,Bash(git status:*),Bash(bash:*)" "" >/dev/null 2>&1; then
            pass "validate-tool-surface positive (bash+git on onboarder)"
        else
            fail "validate-tool-surface positive: bash+git should be present"
        fi

        # Built-ins only: no Bash entries → nothing to check, exit 0.
        if bash "${validate_tool_surface}" "${onboarder_tag}" "Read,Edit,Write,Glob" "" >/dev/null 2>&1; then
            pass "validate-tool-surface built-ins-only (no Bash, pass)"
        else
            fail "validate-tool-surface built-ins-only: should pass"
        fi

        # F52 case: xxd not on the onboarder image.
        rc=0
        bash "${validate_tool_surface}" "${onboarder_tag}" "Bash(xxd:*)" "" >/dev/null 2>&1 || rc=$?
        if [ "${rc}" -eq 1 ]; then
            pass "validate-tool-surface F52 negative (xxd missing → rc=1)"
        else
            fail "validate-tool-surface F52: expected rc=1, got rc=${rc}"
        fi

        # Bash with colon-suffix scoping form: `Bash(git -C /work log:*)` → "git".
        if bash "${validate_tool_surface}" "${onboarder_tag}" "Bash(git -C /work log:*)" "" >/dev/null 2>&1; then
            pass "validate-tool-surface git -C scoping form (extracts 'git')"
        else
            fail "validate-tool-surface git -C scoping form: should extract 'git' as binary"
        fi
    else
        skip "validate-tool-surface tests — no baseline onboarder image"
    fi

    # ----- Image-tag namespace separation: setup-time tag untouched -----
    # The s009 setup-time image tag is agent-onboarder:latest. compose-image.sh
    # must NOT clobber it. (We don't assert :latest exists here — it may not on a
    # dev clone — but we assert the JIT tag is in a different namespace.)
    if [ -n "${onboarder_tag}" ]; then
        case "${onboarder_tag}" in
            agent-onboarder-platforms:*)
                pass "compose-image tag namespace is agent-onboarder-platforms:<hash>"
                ;;
            *)
                fail "compose-image tag namespace: expected agent-onboarder-platforms:*, got ${onboarder_tag}"
                ;;
        esac
    fi
fi

# ===========================================================================
# Summary
# ===========================================================================
echo
echo "================================================================"
echo "  Tests: ${pass_count} passed, ${fail_count} failed, ${skip_count} skipped"
echo "================================================================"
if [ "${fail_count}" -gt 0 ]; then
    exit 1
fi
exit 0
