"""Owner-approved aggregate counters and pre-dispatch guards."""

from __future__ import annotations

from dataclasses import dataclass

from scheduled_learning_v1.evidence_contract import operation_usage
from scheduled_learning_v1.frozen_contract import AGGREGATE_BUDGETS, json_exactly_matches


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

    def reserve(
        self,
        kind: str,
        *,
        maximum_responses_sends: int,
        maximum_accounted_tokens: int,
    ) -> None:
        """Reserve one call only when its worst-case accounting fits authorization."""

        self.guard_dispatch(
            maximum_responses_sends=maximum_responses_sends,
            maximum_accounted_tokens=maximum_accounted_tokens,
        )
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

    def guard_dispatch(
        self,
        *,
        maximum_responses_sends: int = 1,
        maximum_accounted_tokens: int = 1,
    ) -> None:
        """Reject work unless the next operation's complete bound fits."""

        if maximum_responses_sends <= 0 or maximum_accounted_tokens <= 0:
            raise ValueError("dispatch maxima must be positive integers")
        if self.responses_sends + maximum_responses_sends > int(
            AGGREGATE_BUDGETS["responses_sends"]
        ):
            raise BudgetExceededError("responses_sends aggregate exhausted")
        if self.accounted_tokens + maximum_accounted_tokens > int(
            AGGREGATE_BUDGETS["accounted_tokens"]
        ):
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

    def task_snapshot(
        self,
        manifest: dict[str, object],
        approval: dict[str, object],
    ) -> dict[str, int]:
        """Return the task worker snapshot bound to both admitted budget objects."""

        manifest_budgets = manifest.get("budgets")
        approval_budgets = approval.get("budgets")
        if not json_exactly_matches(manifest_budgets, AGGREGATE_BUDGETS):
            raise ValueError("task snapshot manifest budgets differ from admitted M3 budgets")
        if not json_exactly_matches(approval_budgets, AGGREGATE_BUDGETS):
            raise ValueError("task snapshot approval budgets differ from admitted M3 budgets")
        accounted_tokens = int(AGGREGATE_BUDGETS["accounted_tokens"])
        responses_sends = int(AGGREGATE_BUDGETS["responses_sends"])

        return {
            "stage_accounted_tokens": self.accounted_tokens,
            "global_accounted_tokens": self.accounted_tokens,
            "stage_responses_sends": self.responses_sends,
            "global_responses_sends": self.responses_sends,
            "stage_accounted_token_threshold": accounted_tokens,
            "global_accounted_token_threshold": accounted_tokens,
            "stage_responses_send_cap": responses_sends,
            "global_responses_send_cap": responses_sends,
        }
