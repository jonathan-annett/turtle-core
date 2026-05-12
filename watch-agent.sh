#!/bin/bash
# watch-agent.sh — tail the active claude-code session JSONL inside a
# substrate role container, with pretty-printing and auto-follow when
# a new session (e.g. next task) starts.
#
# Usage:
#   watch-agent.sh                  # auto-detect (errors if multiple role containers running)
#   watch-agent.sh <role>           # planner | coder-daemon | auditor | architect | smoke
#   watch-agent.sh <container-name> # exact container name (no fuzzy match)
#
# Flags:
#   -r, --raw    Raw JSONL output (no pretty-print, no color).
#   -c, --color  Force colors even when stdout is not a TTY (useful with tee/less -R).
#                Without this, colors auto-enable on a TTY and auto-disable when piped.
#
# Examples:
#   watch-agent.sh                  # tail whatever single role container is running
#   watch-agent.sh planner          # tail the planner (will pick first match if multiple)
#   watch-agent.sh coder-daemon     # tail the active coder running inside coder-daemon
#                                   # (coders are sub-sessions; this follows the newest one)
#   watch-agent.sh -r               # raw JSONL output (no pretty-print)
#   watch-agent.sh -c planner | tee session.log
#                                   # save a colorized log; view later with `less -R session.log`
#
# Requires: docker, jq (for pretty-print; falls back to raw if jq missing on host).

set -euo pipefail

raw=0
force_color=0
while [ $# -gt 0 ]; do
    case "$1" in
        -r|--raw)   raw=1; shift ;;
        -c|--color) force_color=1; shift ;;
        --)         shift; break ;;
        -*)         echo "watch-agent: unknown flag $1" >&2; exit 2 ;;
        *)          break ;;
    esac
done

target="${1:-}"

# Decide whether to emit ANSI colors: forced, or auto on TTY.
color=0
if [ "$force_color" -eq 1 ] || [ -t 1 ]; then
    color=1
fi

# Resolve target container
if [ -z "$target" ]; then
    matches=$(docker ps --format '{{.Names}}' \
        | grep -E -- '(architect|planner|coder-daemon|coder|auditor)' || true)
elif docker ps --format '{{.Names}}' | grep -qFx -- "$target"; then
    matches="$target"
else
    matches=$(docker ps --format '{{.Names}}' | grep -- "$target" || true)
fi

if [ -z "$matches" ]; then
    echo "watch-agent: no matching running container." >&2
    echo "Running containers:" >&2
    docker ps --format '  {{.Names}}' >&2
    exit 1
fi

count=$(echo "$matches" | wc -l)
if [ "$count" -gt 1 ]; then
    echo "watch-agent: multiple matches; specify one:" >&2
    echo "$matches" | sed 's/^/  /' >&2
    exit 1
fi

container=$(echo "$matches" | head -1)

# Find the most-recently-modified JSONL session log inside the container.
get_newest() {
    docker exec "$container" bash -c '
        find /home/agent/.claude/projects -name "*.jsonl" \
             -printf "%T@ %p\n" 2>/dev/null \
            | sort -rn | head -1 | cut -d" " -f2-
    ' 2>/dev/null
}

# Pretty-printer: parse each JSONL line and emit one human-readable event,
# optionally colorized via ANSI escapes. Falls back to raw if jq is
# unavailable on the host.
pretty_print() {
    if [ "$raw" -eq 1 ]; then
        cat
        return
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "(jq not found on host; falling back to raw output)" >&2
        cat
        return
    fi
    jq --arg color "$color" -rc '
        def c(code): if $color == "1" then "\u001b[" + code + "m" + . + "\u001b[0m" else . end;
        def red:     c("31");
        def green:   c("32");
        def yellow:  c("33");
        def blue:    c("34");
        def magenta: c("35");
        def cyan:    c("36");
        def dim:     c("2");

        def trunc(n): if (. | length) > n then (.[0:n] + "…") else . end;

        if .type == "assistant" then
            (.message.content // []) as $blocks
            | $blocks | map(
                if   .type == "text"     then ("[" + (.text | tostring | trunc(500)) + "]") | cyan
                elif .type == "tool_use" then ("[TOOL " + (.name // "?") + "] " + ((.input // {}) | tostring | trunc(300))) | yellow
                elif .type == "thinking" then "[thinking]" | dim
                else ("[assistant:" + (.type // "?") + "]") | dim
                end
            ) | .[]
        elif .type == "user" then
            ((.message.content // [])[0]) as $first
            | if $first.type == "tool_result" then
                if $first.is_error == true
                then ("[result:ERROR] " + ($first.content | tostring | trunc(300))) | red
                else ("[result] "       + ($first.content | tostring | trunc(300))) | green
                end
              else ("[user] " + (.message.content | tostring | trunc(300))) | blue
              end
        elif .type == "last-prompt" then "[bootstrap-prompt-set]" | magenta
        else ("[" + (.type // "?") + "]") | dim
        end
    '
}

echo "watch-agent: watching $container"

# Wait for a JSONL to appear (claude session might not have started yet).
while true; do
    current=$(get_newest)
    if [ -n "$current" ]; then
        break
    fi
    echo "  (no session JSONL yet, waiting...)"
    sleep 3
done

# Tail loop. Periodically check whether a newer JSONL has appeared
# (= the agent moved on to a new task / a new coder was commissioned).
trap 'jobs -p | xargs -r kill 2>/dev/null; exit 0' INT TERM

while true; do
    echo ""
    echo "================================================================"
    echo "Tailing: $current"
    echo "================================================================"

    docker exec "$container" tail -f "$current" 2>/dev/null | pretty_print &
    tail_pid=$!

    # Watcher: every 5s, check for a newer JSONL; if found, kill the tail.
    while kill -0 "$tail_pid" 2>/dev/null; do
        sleep 5
        newer=$(get_newest) || newer=""
        if [ -n "$newer" ] && [ "$newer" != "$current" ]; then
            echo ""
            echo "================================================================"
            echo "New session detected; switching."
            echo "================================================================"
            kill "$tail_pid" 2>/dev/null || true
            wait "$tail_pid" 2>/dev/null || true
            current="$newer"
            break
        fi
    done
done
