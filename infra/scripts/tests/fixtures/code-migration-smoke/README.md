# code-migration-smoke fixture

Synthetic Python project used by:

- `infra/scripts/tests/test-code-migration.sh` (s014 B.8) — automated
  infrastructure plumbing test. The stub-claude verifies the dispatch
  helper composes the agent image correctly, the tool-surface
  validator passes, and the agent's report-commit-and-push path
  through the git-server's update hook works.
- The operator-driven phase-1 smoke (s014 B.9, post-merge) — operator
  runs `./onboard-project.sh infra/scripts/tests/fixtures/code-migration-smoke/`
  to exercise the full three-phase onboarding flow against real
  claude.

## Layout

```
code-migration-smoke/
├── README.md          (this file)
├── requirements.txt   declares `click` (legitimate) and `requestz` (deliberate typo)
├── pyproject.toml     minimal PEP 518 manifest
├── smoke/
│   ├── __init__.py
│   ├── main.py        imports `smoke.greeting` and calls it
│   ├── greeting.py    defines `greet()` — imported by main
│   └── orphan.py      DELIBERATE ORPHAN — no importers, no entry point
```

## What the agent should surface

A correctly-composed code migration agent running against this fixture
should produce a migration report with:

- **HIGH finding** for the `requestz` typo in `requirements.txt`
  (dependency resolution fails on a name that looks like `requests`).
- **LOW finding** for `smoke/orphan.py` (no importers, no `__main__`,
  no test references — structural orphan).
- A clean **per-component intent** entry for the `smoke/` package
  (Python package, active, single entry point at `main.py`).
- A clean **structural completeness** report aside from the two
  findings above (import graph closes for `main.py` ↔ `greeting.py`).

The fixture is deliberately small so the agent's run is fast and the
findings are unambiguous — the B.9 runbook checks that section 3 of
the resulting handover names both findings by location.

## Why this layout

- Three Python files (init + main + greeting + orphan = four under
  `smoke/`, plus two manifest files at the root) sits comfortably
  within the brief's "3-5 file" target while exercising
  package-import structure, typo-in-manifest, and orphan-file
  detection in one fixture.
- `requirements.txt` carries the typo because it's the canonical
  pip-readable manifest that `pip install --dry-run` will choke on
  with a clear error message — easy for the agent to surface as a
  HIGH finding with citable evidence.
- `pyproject.toml` is minimal — present so `python-extras` detection
  via `infer-platforms.sh` triggers on multiple signals (defence in
  depth against single-marker false negatives).
- The orphan module (`orphan.py`) has a function defined but no other
  module imports it; the agent's structural-completeness probe should
  catch it via grep-for-importers across the package.

## Do not check in additional files

The fixture is sized for the smoke. Adding files would inflate the
agent's survey time without exercising additional plumbing. If the
test suite outgrows what this fixture provides, prefer adding a
second fixture rather than expanding this one.
