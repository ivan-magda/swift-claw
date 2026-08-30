"""Owner-approved aggregate counters and pre-dispatch guards."""

from __future__ import annotations

from dataclasses import dataclass

from scheduled_learning_v1.evidence_contract import operation_usage
from scheduled_learning_v1.frozen_contract import AGGREGATE_BUDGETS


class BudgetExceededError(RuntimeError):
    """The next external operation would exceed an owner-approved aggregate."""


@dataclass
class AggregateBudget:
    """Mutable counters for one non-resumable scored lifecycle."""

    task_attempts: int = 0
    evaluator_calls: int = 0
    reflector_calls: int = 0
    responses_sends: int = 0
    accounted_tokens: int = 0

    def reserve(self, kind: str) -> None:
        """Reserve one model call only after current usage remains dispatchable."""

        self.guard_dispatch()
        field = {
            "task": "task_attempts",
            "evaluator": "evaluator_calls",
            "reflector": "reflector_calls",
        }.get(kind)
        if field is None:
            raise ValueError(f"unknown aggregate operation kind: {kind}")
        observed = getattr(self, field)
        limit = int(AGGREGATE_BUDGETS[field])
        if observed >= limit:
            raise BudgetExceededError(f"{field} aggregate exhausted")
        setattr(self, field, observed + 1)

    def guard_dispatch(self) -> None:
        """Reject external work when a send or token aggregate is already exhausted."""

        if self.responses_sends >= int(AGGREGATE_BUDGETS["responses_sends"]):
            raise BudgetExceededError("responses_sends aggregate exhausted")
        if self.accounted_tokens >= int(AGGREGATE_BUDGETS["accounted_tokens"]):
            raise BudgetExceededError("accounted_tokens aggregate exhausted")

    def record(self, terminal: dict[str, object]) -> None:
        """Account one returned terminal and fail immediately on an overshoot."""

        sends, tokens, _ = operation_usage(terminal)
        self.responses_sends += sends
        self.accounted_tokens += tokens
        if self.responses_sends > int(AGGREGATE_BUDGETS["responses_sends"]):
            raise BudgetExceededError("responses_sends aggregate exceeded")
        if self.accounted_tokens > int(AGGREGATE_BUDGETS["accounted_tokens"]):
            raise BudgetExceededError("accounted_tokens aggregate exceeded")

    def task_snapshot(self) -> dict[str, int]:
        """Return the legacy Swift task worker's admitted global/stage snapshot."""

        return {
            "stage_accounted_tokens": self.accounted_tokens,
            "global_accounted_tokens": self.accounted_tokens,
            "stage_responses_sends": self.responses_sends,
            "global_responses_sends": self.responses_sends,
            "stage_accounted_token_threshold": int(AGGREGATE_BUDGETS["accounted_tokens"]),
            "global_accounted_token_threshold": 4_350_000,
            "stage_responses_send_cap": int(AGGREGATE_BUDGETS["responses_sends"]),
            "global_responses_send_cap": 454,
        }
