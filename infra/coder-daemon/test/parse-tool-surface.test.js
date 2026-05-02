// Tests for the "Required tool surface" brief parser.
//
// Run with: node --test infra/coder-daemon/test/parse-tool-surface.test.js

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { parseToolSurface } = require('../parse-tool-surface');

test('parses YAML list under bullet marker', () => {
    const brief = [
        '# Task brief',
        '',
        '- **Touch surface.** src/foo.js',
        '- **Required tool surface.**',
        '  ```yaml',
        '  - Read',
        '  - Edit',
        '  - Bash(git *)',
        '  ```',
        '- **Constraints.** none',
    ].join('\n');
    const tools = parseToolSurface(brief);
    assert.deepEqual(tools, ['Read', 'Edit', 'Bash(git *)']);
});

test('parses JSON array under heading marker', () => {
    const brief = [
        '# Task brief',
        '',
        '## Required tool surface',
        '',
        '```json',
        '["Read", "Write", "Bash(npm test)"]',
        '```',
    ].join('\n');
    const tools = parseToolSurface(brief);
    assert.deepEqual(tools, ['Read', 'Write', 'Bash(npm test)']);
});

test('accepts h3 heading marker', () => {
    const brief = [
        '### Required tool surface',
        '```',
        '- Read',
        '- Edit',
        '```',
    ].join('\n');
    const tools = parseToolSurface(brief);
    assert.deepEqual(tools, ['Read', 'Edit']);
});

test('fails loudly when the field is absent', () => {
    const brief = [
        '# Task brief',
        '',
        '- **Touch surface.** src/foo.js',
        '- **Constraints.** none',
    ].join('\n');
    assert.throws(
        () => parseToolSurface(brief),
        /lacks required-tool-surface declaration/
    );
});

test('fails when no code block follows the field', () => {
    const brief = [
        '- **Required tool surface.** Read, Edit, Write.',
        '- **Constraints.** none',
    ].join('\n');
    assert.throws(
        () => parseToolSurface(brief),
        /no fenced code block follows the field heading/
    );
});

test('fails when code block is empty', () => {
    const brief = [
        '- **Required tool surface.**',
        '  ```yaml',
        '  ```',
    ].join('\n');
    assert.throws(
        () => parseToolSurface(brief),
        /code block is empty/
    );
});

test('fails when JSON in code block is malformed', () => {
    const brief = [
        '## Required tool surface',
        '```json',
        '["Read", "Edit",',
        '```',
    ].join('\n');
    assert.throws(
        () => parseToolSurface(brief),
        /not valid JSON/
    );
});

test('fails on empty list', () => {
    const brief = [
        '## Required tool surface',
        '```yaml',
        '# nothing',
        '```',
    ].join('\n');
    assert.throws(
        () => parseToolSurface(brief),
        /list is empty/
    );
});

test('fails on empty string entry in JSON', () => {
    const brief = [
        '## Required tool surface',
        '```json',
        '["Read", ""]',
        '```',
    ].join('\n');
    assert.throws(
        () => parseToolSurface(brief),
        /not a non-empty string/
    );
});

test('field bullet with colon variant is recognised', () => {
    const brief = [
        '- **Required tool surface:**',
        '  ```yaml',
        '  - Read',
        '  ```',
    ].join('\n');
    assert.deepEqual(parseToolSurface(brief), ['Read']);
});

test('skips intermediate text between marker and code block', () => {
    const brief = [
        '## Required tool surface',
        '',
        'A short prose blurb explaining the choice.',
        '',
        '```yaml',
        '- Read',
        '- Bash(make test)',
        '```',
    ].join('\n');
    assert.deepEqual(
        parseToolSurface(brief),
        ['Read', 'Bash(make test)']
    );
});

test('does not consume code blocks that belong to a later field', () => {
    const brief = [
        '- **Required tool surface.**',
        '- **Verification.**',
        '  ```bash',
        '  npm test',
        '  ```',
    ].join('\n');
    // The code block belongs to "Verification", not "Required tool surface" —
    // parser must stop at the next bullet field marker.
    assert.throws(
        () => parseToolSurface(brief),
        /no fenced code block follows the field heading/
    );
});
