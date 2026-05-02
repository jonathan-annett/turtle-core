// Parser for the "Required tool surface" field in task briefs (spec §7.3).
//
// The field appears in a brief as either a bullet:
//
//     - **Required tool surface.**
//       ```yaml
//       - Read
//       - Edit
//       - Bash(git *)
//       ```
//
// or as its own (sub)heading:
//
//     ### Required tool surface
//     ```json
//     ["Read", "Edit", "Bash(git *)"]
//     ```
//
// The first fenced code block following the field marker is parsed.
// JSON arrays and simple YAML lists (one `- item` per line) are both
// accepted; the lang tag on the fence is informational and not
// authoritative — the parser tries JSON.parse first, falls back to the
// YAML form.
//
// On any failure (no marker, no following code block, unparseable
// content, empty list) the parser throws with a message suitable for
// surfacing as a commission failure.

'use strict';

const MARKER_RE = new RegExp(
    '^\\s*(?:' +
        // bullet form, with terminating dot or colon: - **Required tool surface.**
        '-\\s+\\*\\*Required tool surface[.:]?\\*\\*' +
        '|' +
        // heading form: ## Required tool surface (any h2..h6)
        '#{2,6}\\s+Required tool surface\\s*$' +
    ')',
    'i'
);

const FENCE_OPEN_RE  = /^\s*```([A-Za-z0-9_-]*)\s*$/;
const FENCE_CLOSE_RE = /^\s*```\s*$/;
const YAML_ITEM_RE   = /^\s*-\s+(.+?)\s*$/;

function parseToolSurface(briefText) {
    if (typeof briefText !== 'string' || briefText.length === 0) {
        throw new Error('task brief is empty');
    }

    const lines = briefText.split(/\r?\n/);

    let markerIdx = -1;
    for (let i = 0; i < lines.length; i++) {
        if (MARKER_RE.test(lines[i])) {
            markerIdx = i;
            break;
        }
    }
    if (markerIdx === -1) {
        throw new Error(
            'task brief lacks required-tool-surface declaration: ' +
            'no "Required tool surface" field found'
        );
    }

    // Find the first fenced code block strictly after the marker, before
    // the next field marker / top-level heading. We scan up to 80 lines
    // forward, which generously covers a normal brief field.
    const SCAN_LIMIT = Math.min(lines.length, markerIdx + 1 + 80);
    let fenceStart = -1;
    let fenceEnd   = -1;
    for (let i = markerIdx + 1; i < SCAN_LIMIT; i++) {
        const line = lines[i];
        // Bail if we hit another field marker or h1/h2 — the field has
        // ended without a code block.
        if (/^\s*-\s+\*\*[A-Z][^*]*\*\*/.test(line) && i !== markerIdx) {
            break;
        }
        if (/^#{1,2}\s+/.test(line) && i !== markerIdx) {
            break;
        }
        if (FENCE_OPEN_RE.test(line)) {
            fenceStart = i + 1;
            for (let j = fenceStart; j < lines.length; j++) {
                if (FENCE_CLOSE_RE.test(lines[j])) {
                    fenceEnd = j;
                    break;
                }
            }
            break;
        }
    }
    if (fenceStart === -1) {
        throw new Error(
            'task brief lacks required-tool-surface declaration: ' +
            'no fenced code block follows the field heading'
        );
    }
    if (fenceEnd === -1) {
        throw new Error(
            'task brief required-tool-surface code block is unterminated'
        );
    }

    const body = lines.slice(fenceStart, fenceEnd).join('\n').trim();
    if (body.length === 0) {
        throw new Error(
            'task brief required-tool-surface code block is empty'
        );
    }

    let tools = null;

    // Try JSON first.
    if (body.startsWith('[')) {
        try {
            const parsed = JSON.parse(body);
            if (Array.isArray(parsed)) {
                tools = parsed;
            }
        } catch (_) {
            throw new Error(
                'task brief required-tool-surface code block is not valid JSON'
            );
        }
    }

    // Fall back to YAML simple-list form.
    if (tools === null) {
        const items = [];
        for (const raw of body.split('\n')) {
            const line = raw.trimEnd();
            if (line === '' || line.startsWith('#')) continue;
            const m = YAML_ITEM_RE.exec(line);
            if (!m) {
                throw new Error(
                    'task brief required-tool-surface entry is not in `- item` form: ' +
                    JSON.stringify(line)
                );
            }
            items.push(m[1]);
        }
        tools = items;
    }

    if (!Array.isArray(tools) || tools.length === 0) {
        throw new Error(
            'task brief required-tool-surface list is empty'
        );
    }
    for (const t of tools) {
        if (typeof t !== 'string' || t.trim().length === 0) {
            throw new Error(
                'task brief required-tool-surface entry is not a non-empty string: ' +
                JSON.stringify(t)
            );
        }
    }

    return tools.map(t => t.trim());
}

module.exports = { parseToolSurface };
