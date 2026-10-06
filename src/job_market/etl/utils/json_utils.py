import json
from pathlib import Path
from typing import Any


def save_json(data: Any, target_path: Path) -> None:
    """Write JSON-compatible data as UTF-8 JSON."""

    target_path.parent.mkdir(parents=True, exist_ok=True)

    with target_path.open("w", encoding="utf-8") as file:
        json.dump(
            data,
            file,
            ensure_ascii=False,
            indent=2,
        )


def load_json(source_path: Path) -> list[dict[str, Any]]:
    """Load raw job details from JSON."""

    with source_path.open("r", encoding="utf-8") as file:
        data = json.load(file)

    if not isinstance(data, list):
        raise TypeError("Expected job-details.json to contain a list")

    return data
