# CLAUDE.md — Working on turtle-core

If you're reading this, you're working on **turtle-core** — the substrate that hosts a methodology for AI-driven software development. This document orients you to the work-mode you're in, the conventions that apply, and the boundary between substrate-internal concerns and the methodology that gets exported to user projects.

## You are at the outermost Matryoshka layer

The methodology that turtle-core implements is recursive: an architect drafts briefs for a planner, who drafts briefs for coders and auditors, who do focused implementation and verification work. Each layer encodes context for the layer below that doesn't have it.

**You are not in any of those layers.** You are designing or implementing the substrate that makes those layers possible. Concretely:

- You are not the architect for any project.
- You are not authoring methodology-project section briefs (briefs that get consumed by a planner or coder dispatched in a user project).
- You are not running inside a substrate container; you are working on the code that builds those containers.

When in doubt about which layer you're in, the test is: am I working on a user project (some `~/some-project/`), or am I working on turtle-core itself? If the latter, you're at the substrate-iteration layer.

## How substrate-iteration work happens

The methodology turtle-core exports has a specific shape: architect commissions planner via docker-compose, planner commissions coder/auditor, etc. **That is not how work on turtle-core itself happens.**

Work on turtle-core happens host-side, single-agent. The pattern is:

1. Design conversations happen in chat-Claude sessions (this one is an example). The output of those sessions is a substrate-iteration brief plus a handover that captures the design context.
2. An implementing agent (typically you, running Claude Code in `~/turtle-core/`) picks up the brief and works directly on a section branch. No `commission-pair.sh`, no planner, no coder dispatch.
3. The implementing agent writes a section report, pushes the section branch, and discharges. A human operator merges the section branch into main.

If you are a chat-Claude instance reading project knowledge, your role is the design half. If you are an implementing agent in `~/turtle-core/`, your role is the implementation half. Either way you are operating manually relative to the methodology — that is by design, not an oversight.

### Why manual, not self-hosted

The long-term endpoint is for turtle-core to be developed via its own methodology — commissioning an architect for the substrate project itself, who would then drive section work through planners and coders. **We aren't there yet.** The methodology has to be proven on real external projects (which is what the migration-onboarding work is building toward) before we can confidently turn it on its own development. The current manual pattern is deliberate; expect it to change once that confidence threshold is crossed.

## The `methodology/` boundary

`methodology/` contains documents that get exported to user projects — guides for the architect, planner, coder, auditor, and (soon) onboarder roles; the orchestration spec; deployment docs. These get mounted read-only into role containers when those roles are operating on user projects.

**Everything else under `turtle-core/` is substrate-internal** and never enters a role container's view.

When you create a new document, the test is: would a user-project agent (architect on hello-turtle, planner on some-other-project, etc.) ever need this? If yes, it belongs in `methodology/`. If no — if it's about how turtle-core gets built, how chat-Claude instances coordinate, or substrate-development findings — it lives elsewhere.

Concrete examples of the boundary:

- Role guides, spec, deployment docs → `methodology/`.
- Substrate-iteration section briefs → `briefs/` at the root of turtle-core (same path convention as methodology-project briefs, but the brief's preamble identifies it as substrate-iteration work).
- Findings register → root (`FINDINGS.md`), not `methodology/`.
- This file (`CLAUDE.md`) → root, not `methodology/`. Auto-loaded by Claude Code when you run `claude` from `turtle-core/`.

## Substrate-internal artifacts

The current set, all at or near the root:

- **`CLAUDE.md`** (this file) — orientation for chat-Claude instances and implementing agents.
- **`FINDINGS.md`** — register of findings raised during substrate-iteration work. Each entry: ID (`FNN`), title, severity, status (`open` / `deferred` / `fixed` / `retracted`), origin section, resolution section if any, short description. If you surface a finding during substrate work, add an entry with the next F-number. The next available F-number lives in the latest handover until the register is created and backfilled.
- **`briefs/sNNN-<slug>/`** — substrate-iteration section briefs and section reports. The brief's preamble identifies it as substrate-iteration work and points to this file. Once `CLAUDE.md` exists, brief preambles can be short ("read `CLAUDE.md` if you haven't, then proceed") rather than reinventing the work-mode explanation each time.
- **Handover documents** between chat-Claude sessions live in
  the **project knowledge** of the chat-Claude project, because
  chat-Claude is the audience for them — implementing agents
  don't read handovers, they read section briefs and
  `FINDINGS.md`. The repo is **optional secondary storage**: when
  a phase closes (e.g., "migration-onboarding shipped after C
  merges"), snapshot the handover chain into a `handovers/`
  directory at the repo root as a frozen archival record. **Do
  not routinely duplicate** — two live copies invite drift, and
  the project-knowledge copy is what chat-Claude auto-trusts, so
  a stale mirror could quietly mislead a future session.

## Working with this project

A few conventions to know:

- **Read this file first.** It saves the long preamble that every substrate-iteration brief would otherwise reinvent.
- **Check `FINDINGS.md` early.** Existing findings often inform current decisions, especially open and deferred ones.
- **Read the latest handover.** Handovers are the durable carrier between chat-Claude sessions. The latest one tells you where the work left off, what's pending, and what the next concrete move is.
- **"Recommendations baked in (override before dispatch)" is the substrate-iteration brief pattern.** Each design call states a position, the rationale, the considered alternative, and override-language. If a position is wrong for your read of the problem, raise it as an amendment **before** starting the work. Once dispatched, the design calls are committed; mid-section design changes need an explicit amendment. (Introduced with s013's F50 brief; the convention now applies to every substrate-iteration brief.)
- **If you are a chat-Claude instance designing a brief**, your output is the brief plus an updated handover capturing design context. You don't run code or attach to substrates.
- **If you are an implementing agent**, your output is the section report and pushed branch. You don't make design decisions outside the brief's scope without asking for an amendment.

## When this document is wrong

This file captures the current pattern, not an eternal truth. If the pattern changes — for example, turtle-core moves to self-hosted development — this file gets updated as part of that change. Treat it as authoritative for the current state, but expect revisions, and update it when you make a change that affects how future instances should work.
