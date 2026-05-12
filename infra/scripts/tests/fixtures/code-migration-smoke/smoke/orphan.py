"""Deliberate orphan module for the code-migration-smoke fixture.

No importers in the rest of the package. No __main__ guard. No test
references. The code migration agent's structural-completeness probe
should surface this as a LOW finding with location and a suggested
next-step framing for the architect.
"""


def unused_helper(value: int) -> int:
    return value * 2
