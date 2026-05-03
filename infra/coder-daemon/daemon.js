// Coder commission daemon.
//
// Implements deployment-docker.md §4. The planner posts task-brief commissions;
// this daemon spawns one claude-code subshell at a time inside its own
// container, captures the work, verifies the resulting task-branch tip
// contains the expected report, and records the outcome in sqlite.
//
// Auth is two-layered:
//   1. Network — bound to the container's own non-loopback IPv4 address on
//      the agent-net bridge. The compose-project namespace isolates each
//      planner/daemon pair from every other pair on the host.
//   2. Bearer token — every request must carry Authorization: Bearer
//      $COMMISSION_TOKEN, set per pair by commission-pair.sh.
//
// A third source-IP guard lived here in s001–s006 (resolved via
// `getent hosts planner`) but was removed in s007: the planner service
// has no container_name and no network alias (deliberate, to keep
// multi-pair parallelism open), so reverse-DNS on the source IP returned
// the container ID rather than `planner`, the check closed-failed, and
// every commission was 503'd. Compose-project network isolation plus the
// bearer token are the real boundaries; the IP guard added no defensive
// value commensurate with its breakage rate.

'use strict';

const express      = require('express');
const Database     = require('better-sqlite3');
const { v4: uuid } = require('uuid');
const childProc    = require('child_process');
const fs           = require('fs');
const path         = require('path');
const os           = require('os');
const { parseToolSurface } = require('./parse-tool-surface');

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const PORT  = parseInt(process.env.COMMISSION_PORT  || '', 10);
const TOKEN = process.env.COMMISSION_TOKEN || '';

if (!Number.isInteger(PORT) || PORT < 1 || PORT > 65535) {
    console.error('FATAL: COMMISSION_PORT must be a valid port number');
    process.exit(2);
}
if (!TOKEN || TOKEN.length < 16) {
    console.error('FATAL: COMMISSION_TOKEN must be set (>=16 chars)');
    process.exit(2);
}

const DB_PATH     = '/data/commissions.db';
const WORK_ROOT   = '/work';
const LOG_ROOT    = '/data/logs';
const MAIN_REMOTE = 'git@git-server:/srv/git/main.git';

fs.mkdirSync(WORK_ROOT, { recursive: true });
fs.mkdirSync(LOG_ROOT,  { recursive: true });

// ---------------------------------------------------------------------------
// Bind address — the container's own non-loopback IPv4. Avoids 0.0.0.0
// per brief §4.5.
// ---------------------------------------------------------------------------

function bindAddress() {
    const ifaces = os.networkInterfaces();
    for (const name of Object.keys(ifaces)) {
        for (const a of ifaces[name] || []) {
            if (a.family === 'IPv4' && !a.internal) return a.address;
        }
    }
    throw new Error('no non-loopback IPv4 interface found');
}

// ---------------------------------------------------------------------------
// sqlite — schema per deployment-doc §4.4
// ---------------------------------------------------------------------------

const db = new Database(DB_PATH);
db.pragma('journal_mode = WAL');
db.exec(`
    CREATE TABLE IF NOT EXISTS commissions (
        commission_id   TEXT PRIMARY KEY,
        brief_path      TEXT NOT NULL,
        section_branch  TEXT NOT NULL,
        task_branch     TEXT NOT NULL,
        allowed_tools   TEXT,
        status          TEXT NOT NULL,
        started_at      TEXT,
        finished_at     TEXT,
        exit_code       INTEGER,
        report_path     TEXT,
        error           TEXT,
        log_path        TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_status   ON commissions(status);
    CREATE INDEX IF NOT EXISTS idx_started  ON commissions(started_at);
`);

const stmts = {
    insert: db.prepare(`
        INSERT INTO commissions
            (commission_id, brief_path, section_branch, task_branch,
             allowed_tools, status, started_at, log_path)
        VALUES (@commission_id, @brief_path, @section_branch, @task_branch,
                @allowed_tools, 'queued', @started_at, @log_path)
    `),
    setRunning: db.prepare(`
        UPDATE commissions SET status='running' WHERE commission_id=?
    `),
    setTerminal: db.prepare(`
        UPDATE commissions
           SET status=@status, finished_at=@finished_at, exit_code=@exit_code,
               report_path=@report_path, error=@error
         WHERE commission_id=@commission_id
    `),
    get: db.prepare(`SELECT * FROM commissions WHERE commission_id = ?`),
    list: db.prepare(`
        SELECT commission_id, brief_path, section_branch, task_branch,
               status, started_at, finished_at, exit_code, report_path, error
          FROM commissions
         WHERE (?1 IS NULL OR status = ?1)
         ORDER BY started_at DESC
         LIMIT ?2
    `),
};

// ---------------------------------------------------------------------------
// Concurrency lock — one coder at a time per deployment-doc §4.1.
// ---------------------------------------------------------------------------

let activeCoder = null;        // { commission_id, child, cancelled }
const waiters = new Map();     // commission_id -> [{ resolve, timer }, ...]

function notifyTerminal(commission_id) {
    const list = waiters.get(commission_id);
    if (!list) return;
    waiters.delete(commission_id);
    for (const w of list) {
        clearTimeout(w.timer);
        w.resolve();
    }
}

// ---------------------------------------------------------------------------
// Express app
// ---------------------------------------------------------------------------

const app = express();
app.use(express.json({ limit: '64kb' }));

// Bearer auth — runs first, before any logic.
app.use((req, res, next) => {
    const hdr = req.get('authorization') || '';
    if (!hdr.startsWith('Bearer ')) {
        return res.status(401).json({ error: 'missing bearer token' });
    }
    const presented = hdr.slice(7).trim();
    // Constant-time-ish compare to avoid trivial timing leaks.
    if (presented.length !== TOKEN.length) {
        return res.status(401).json({ error: 'invalid token' });
    }
    let mismatch = 0;
    for (let i = 0; i < TOKEN.length; i++) {
        mismatch |= TOKEN.charCodeAt(i) ^ presented.charCodeAt(i);
    }
    if (mismatch !== 0) {
        return res.status(401).json({ error: 'invalid token' });
    }
    next();
});

// POST /commission
app.post('/commission', (req, res) => {
    const body = req.body || {};
    const briefPath  = String(body.brief_path     || '').trim();
    const sectionBr  = String(body.section_branch || '').trim();
    const taskBr     = String(body.task_branch    || '').trim();

    if (!briefPath || !sectionBr || !taskBr) {
        return res.status(400).json({ error: 'brief_path, section_branch, and task_branch are required' });
    }
    if (briefPath.includes('..') || briefPath.startsWith('/')) {
        return res.status(400).json({ error: 'brief_path must be a relative repo path' });
    }
    if (!sectionBr.startsWith('section/')) {
        return res.status(400).json({ error: 'section_branch must start with "section/"' });
    }
    if (!taskBr.startsWith('task/')) {
        return res.status(400).json({ error: 'task_branch must start with "task/"' });
    }

    if (activeCoder) {
        return res.status(409).json({
            error: 'a coder is already running',
            active_commission_id: activeCoder.commission_id
        });
    }

    const id = uuid();
    const startedAt = new Date().toISOString();
    const logPath = path.join(LOG_ROOT, `coder-${id}.log`);

    // allowed_tools is resolved later from the brief's "Required tool
    // surface" field (deployment-doc §4.5, spec §7.3). Recorded as null
    // here; the coder runner fills it in once the brief has been parsed.
    stmts.insert.run({
        commission_id:  id,
        brief_path:     briefPath,
        section_branch: sectionBr,
        task_branch:    taskBr,
        allowed_tools:  null,
        started_at:     startedAt,
        log_path:       logPath,
    });

    runCoder({
        commission_id:  id,
        brief_path:     briefPath,
        section_branch: sectionBr,
        task_branch:    taskBr,
        log_path:       logPath,
    });

    res.status(200).json({ commission_id: id, status: 'queued' });
});

// GET /commission/:id
app.get('/commission/:id', (req, res) => {
    const row = stmts.get.get(req.params.id);
    if (!row) return res.status(404).json({ error: 'no such commission' });
    res.json(row);
});

// GET /commission/:id/wait?timeout=300
app.get('/commission/:id/wait', (req, res) => {
    const id = req.params.id;
    const row = stmts.get.get(id);
    if (!row) return res.status(404).json({ error: 'no such commission' });
    if (row.status === 'complete' || row.status === 'failed') {
        return res.json(row);
    }
    let timeoutSec = parseInt(req.query.timeout || '300', 10);
    if (!Number.isFinite(timeoutSec) || timeoutSec < 1)   timeoutSec = 1;
    if (timeoutSec > 600)                                 timeoutSec = 600;

    if (!waiters.has(id)) waiters.set(id, []);
    const waiter = {};
    waiter.resolve = () => {
        if (waiter.done) return;
        waiter.done = true;
        const fresh = stmts.get.get(id);
        res.json(fresh);
    };
    waiter.timer = setTimeout(() => {
        if (waiter.done) return;
        const list = waiters.get(id);
        if (list) {
            const idx = list.indexOf(waiter);
            if (idx >= 0) list.splice(idx, 1);
            if (list.length === 0) waiters.delete(id);
        }
        waiter.resolve();
    }, timeoutSec * 1000);
    waiters.get(id).push(waiter);
});

// POST /commission/:id/cancel
app.post('/commission/:id/cancel', (req, res) => {
    const row = stmts.get.get(req.params.id);
    if (!row) return res.status(404).json({ error: 'no such commission' });
    if (row.status === 'complete' || row.status === 'failed') {
        return res.status(409).json({ error: `commission already ${row.status}` });
    }
    if (!activeCoder || activeCoder.commission_id !== row.commission_id) {
        return res.status(409).json({ error: 'commission is not the active coder' });
    }
    activeCoder.cancelled = true;
    try { activeCoder.child.kill('SIGTERM'); } catch (_) {}
    setTimeout(() => {
        if (activeCoder && activeCoder.commission_id === row.commission_id) {
            try { activeCoder.child.kill('SIGKILL'); } catch (_) {}
        }
    }, 10_000);
    res.json({ commission_id: row.commission_id, cancelling: true });
});

// GET /commissions
app.get('/commissions', (req, res) => {
    const status = req.query.status ? String(req.query.status) : null;
    let limit = parseInt(req.query.limit || '50', 10);
    if (!Number.isFinite(limit) || limit < 1) limit = 50;
    if (limit > 1000)                          limit = 1000;
    const rows = stmts.list.all(status, limit);
    res.json(rows);
});

// ---------------------------------------------------------------------------
// Coder subshell mechanics — deployment-doc §4.3
// ---------------------------------------------------------------------------

function spawnCmd(cmd, args, opts) {
    return new Promise((resolve, reject) => {
        const p = childProc.spawn(cmd, args, opts);
        let stderr = '';
        if (p.stderr) p.stderr.on('data', d => { stderr += d.toString(); });
        p.on('error', reject);
        p.on('close', code => {
            if (code === 0) resolve();
            else reject(new Error(`${cmd} ${args.join(' ')} exited ${code}: ${stderr.trim()}`));
        });
    });
}

async function runCoder(c) {
    const workdir = path.join(WORK_ROOT, `coder-${c.commission_id}`);
    activeCoder = { commission_id: c.commission_id, child: null, cancelled: false };

    const finish = (status, payload) => {
        stmts.setTerminal.run({
            commission_id: c.commission_id,
            status,
            finished_at: new Date().toISOString(),
            exit_code: payload.exit_code ?? null,
            report_path: payload.report_path ?? null,
            error: payload.error ?? null,
        });
        notifyTerminal(c.commission_id);
        activeCoder = null;
        try { fs.rmSync(workdir, { recursive: true, force: true }); } catch (_) {}
    };

    try {
        stmts.setRunning.run(c.commission_id);

        // 1. Fresh clone + checkout section branch + create task branch.
        await spawnCmd('git', ['clone', MAIN_REMOTE, workdir], {
            stdio: ['ignore', 'pipe', 'pipe']
        });
        await spawnCmd('git', ['-C', workdir, 'fetch', 'origin', c.section_branch], {
            stdio: ['ignore', 'pipe', 'pipe']
        });
        await spawnCmd('git', ['-C', workdir, 'checkout', '-B', c.section_branch, `origin/${c.section_branch}`], {
            stdio: ['ignore', 'pipe', 'pipe']
        });
        await spawnCmd('git', ['-C', workdir, 'checkout', '-b', c.task_branch], {
            stdio: ['ignore', 'pipe', 'pipe']
        });

        // 2. Verify the brief file exists in the cloned tree.
        const briefAbs = path.join(workdir, c.brief_path);
        if (!fs.existsSync(briefAbs)) {
            return finish('failed', { exit_code: null, error: `brief not found at ${c.brief_path} on ${c.section_branch}` });
        }

        // 2b. Write the coder CLAUDE.md role anchor (s007 7.c). Unlike the
        // other roles, coders have no canonical methodology guide — the
        // anchor is short and inline. Excluded from the working tree's
        // git index so it never lands in the task-branch tip.
        const coderClaudeMd = [
            '# You are the coder.',
            '',
            `Your task brief is at ${c.brief_path}. Read it. Do exactly what it says.`,
            'Commit your work and a task report to your task branch, open a PR',
            'back to the section branch, then exit.',
            '',
            'You operate on the brief alone. You do not commission other agents.',
            'Your tool surface is constrained by `--allowedTools` from the brief\'s',
            '"Required tool surface" field; out-of-list actions deny.',
            '',
            'Discharge when done.',
            '',
        ].join('\n');
        fs.writeFileSync(path.join(workdir, 'CLAUDE.md'), coderClaudeMd);
        const excludePath = path.join(workdir, '.git', 'info', 'exclude');
        let excludeContent = '';
        try { excludeContent = fs.readFileSync(excludePath, 'utf8'); } catch (_) {}
        if (!/^CLAUDE\.md$/m.test(excludeContent)) {
            fs.appendFileSync(excludePath, 'CLAUDE.md\n');
        }

        // 3. Parse the brief's "Required tool surface" field — spec §7.3,
        // deployment-doc §4.5. A missing or unparseable field fails the
        // commission rather than defaulting to a permissive list.
        let allowedTools;
        try {
            const briefText = fs.readFileSync(briefAbs, 'utf8');
            allowedTools = parseToolSurface(briefText);
        } catch (err) {
            return finish('failed', {
                exit_code: null,
                error: `required-tool-surface parse failed: ${err.message}`,
            });
        }
        try {
            db.prepare(
                'UPDATE commissions SET allowed_tools = ? WHERE commission_id = ?'
            ).run(JSON.stringify(allowedTools), c.commission_id);
        } catch (_) {
            // recording failure is non-fatal; the spawn still proceeds.
        }

        // 4. Spawn claude-code as the coder subshell.
        // --permission-mode dontAsk + --allowed-tools means out-of-allowlist
        // actions deny rather than prompt; the coder has no human in the
        // loop to unblock a permission dialogue (deployment-doc §4.5).
        const prompt = [
            `You are an ephemeral coder agent. Read the brief at ${c.brief_path}`,
            `(absolute: ${briefAbs}) and execute it.`,
            ``,
            `You are working in ${workdir}, on git branch ${c.task_branch} which`,
            `is based on ${c.section_branch}. When done, commit your code and`,
            `your task report and push the task branch back to origin, then exit.`,
            ``,
            `Do not ask follow-up questions. Discharge cleanly when the brief`,
            `is satisfied or write a "brief insufficient" report and discharge.`,
        ].join('\n');

        const claudeArgs = [
            '-p', prompt,
            '--permission-mode', 'dontAsk',
            '--allowed-tools', allowedTools.join(','),
        ];

        const logfd = fs.openSync(c.log_path, 'w');
        const claude = childProc.spawn('claude', claudeArgs, {
            cwd: workdir,
            stdio: ['ignore', logfd, logfd],
            env: { ...process.env, HOME: '/home/agent' },
        });
        activeCoder.child = claude;

        const exitCode = await new Promise(resolve => {
            claude.on('error', err => {
                fs.appendFileSync(c.log_path, `\n[daemon] spawn error: ${err.message}\n`);
                resolve(-1);
            });
            claude.on('close', code => resolve(code ?? -1));
        });
        try { fs.closeSync(logfd); } catch (_) {}

        if (activeCoder && activeCoder.cancelled) {
            return finish('failed', { exit_code: exitCode, error: 'cancelled' });
        }

        // 4. Verify the report file exists at the task-branch tip on origin.
        // The coder is expected to have pushed it. Refresh remote state and check.
        const expectedReport = c.brief_path.replace(/\.brief\.md$/, '.report.md');
        let reportPresent = false;
        try {
            await spawnCmd('git', ['-C', workdir, 'fetch', 'origin', c.task_branch], {
                stdio: ['ignore', 'pipe', 'pipe']
            });
            childProc.execFileSync(
                'git', ['-C', workdir, 'cat-file', '-e', `origin/${c.task_branch}:${expectedReport}`],
                { stdio: 'ignore' }
            );
            reportPresent = true;
        } catch (_) {
            reportPresent = false;
        }

        if (exitCode === 0 && reportPresent) {
            finish('complete', { exit_code: 0, report_path: expectedReport });
        } else if (!reportPresent) {
            finish('failed', {
                exit_code: exitCode,
                error: `coder exited ${exitCode} but report was not pushed to origin/${c.task_branch}:${expectedReport}`,
                report_path: null,
            });
        } else {
            finish('failed', { exit_code: exitCode, error: `coder exited with non-zero status ${exitCode}` });
        }
    } catch (err) {
        finish('failed', { exit_code: null, error: err.message || String(err) });
    }
}

// ---------------------------------------------------------------------------
// Server lifecycle
// ---------------------------------------------------------------------------

let httpServer = null;
let shuttingDown = false;

function startServer() {
    const addr = bindAddress();
    httpServer = app.listen(PORT, addr, () => {
        console.log(`coder-daemon listening on http://${addr}:${PORT} (pid ${process.pid})`);
    });
}

function gracefulShutdown(signal) {
    if (shuttingDown) return;
    shuttingDown = true;
    console.log(`received ${signal}; shutting down gracefully`);
    if (httpServer) httpServer.close();

    const drain = () => {
        try { db.close(); } catch (_) {}
        process.exit(0);
    };

    if (!activeCoder) return drain();
    console.log(`waiting for active coder ${activeCoder.commission_id} to finish`);
    const start = Date.now();
    const tick = setInterval(() => {
        if (!activeCoder) {
            clearInterval(tick);
            drain();
        } else if ((Date.now() - start) > 120_000) {
            clearInterval(tick);
            console.log('timeout waiting for coder; killing and exiting');
            try { activeCoder.child.kill('SIGKILL'); } catch (_) {}
            drain();
        }
    }, 500);
}

process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT',  () => gracefulShutdown('SIGINT'));

startServer();
