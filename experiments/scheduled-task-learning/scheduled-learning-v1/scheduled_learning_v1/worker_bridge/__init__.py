"""One-shot bridge to the manifest-bound Swift evaluation workers."""

from .bridge import WorkerBridge
from .learning_results import validate_learning_result
from .requests import LearningCall, TaskAttemptCall
from .task_results import validate_task_result

__all__ = [
    "LearningCall",
    "TaskAttemptCall",
    "WorkerBridge",
    "validate_learning_result",
    "validate_task_result",
]
