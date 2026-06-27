"""Shared data models for routes and roadbooks."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass
class RouteSummary:
    route_id: str
    name: str
    raw: dict[str, Any]


@dataclass
class RoadBookSummary:
    roadbook_id: int
    title: str
