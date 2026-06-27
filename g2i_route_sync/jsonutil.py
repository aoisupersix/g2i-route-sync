"""Helpers for reading loosely-typed JSON from reverse-engineered APIs."""

from __future__ import annotations

from typing import Any


def normalize_key(value: str) -> str:
    """Lowercase a key and drop everything but alphanumerics."""
    return "".join(ch for ch in value.lower() if ch.isalnum())


def json_get_ci(container: Any, key: str, default: Any = None) -> Any:
    """Get a value from a JSON object by key, ignoring key case and separators."""
    if not isinstance(container, dict):
        return default

    target = normalize_key(key)
    for current_key, value in container.items():
        if isinstance(current_key, str) and normalize_key(current_key) == target:
            return value
    return default
