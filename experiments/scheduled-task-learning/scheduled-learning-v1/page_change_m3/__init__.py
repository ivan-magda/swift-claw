"""Fresh M3 page-change adapter: materialization, scoring, and receipts.

Task 1 reserved this source root so the package's Ruff/Mypy configuration and
lint gate covered it from the start. Task 3 adds the three public closed
carrier builders; later tasks add scoring and receipts.
"""

from __future__ import annotations

from .materialize import build_evaluator_carrier, build_reflector_carrier, materialize_task

__all__ = ["build_evaluator_carrier", "build_reflector_carrier", "materialize_task"]
