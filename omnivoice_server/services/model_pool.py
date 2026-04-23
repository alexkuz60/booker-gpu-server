"""Model pool — registry of loaded model slots (Sprint 0: single-slot wrapper)."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class ModelSlot:
    name: str
    engine: str
    model_id: str
    device: str
    dtype: str
    loaded_at: float
    ref: Any = field(repr=False)


class ModelPool:
    """In-memory registry of loaded model slots."""

    def __init__(self) -> None:
        self._slots: dict[str, ModelSlot] = {}

    def register(self, slot: ModelSlot) -> None:
        self._slots[slot.name] = slot

    def unregister(self, name: str) -> ModelSlot | None:
        return self._slots.pop(name, None)

    def get(self, name: str) -> ModelSlot | None:
        return self._slots.get(name)

    def list(self) -> list[ModelSlot]:
        return list(self._slots.values())
