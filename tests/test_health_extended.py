"""Tests for /health/extended endpoint and ModelPool (Sprint 0)."""
import time

from omnivoice_server.routers.health_extended import router
from omnivoice_server.services.model_pool import ModelPool, ModelSlot


def _make_slot(name: str = "slot-1", model_id: str = "omnivoice-base") -> ModelSlot:
    return ModelSlot(
        name=name,
        engine="omnivoice",
        model_id=model_id,
        device="cuda:0",
        dtype="float16",
        loaded_at=time.monotonic(),
        ref=object(),
    )


def test_model_pool_register_and_get():
    pool = ModelPool()
    slot = _make_slot()
    pool.register(slot)
    assert pool.get(slot.name) is slot


def test_model_pool_list_returns_all_slots():
    pool = ModelPool()
    pool.register(_make_slot("slot-1", "omnivoice-base"))
    pool.register(_make_slot("slot-2", "omnivoice-large"))
    listed = pool.list()
    assert len(listed) == 2
    assert {s.name for s in listed} == {"slot-1", "slot-2"}


def test_model_pool_unregister_returns_removed_slot():
    pool = ModelPool()
    slot = _make_slot()
    pool.register(slot)
    removed = pool.unregister(slot.name)
    assert removed is slot
    assert pool.get(slot.name) is None
    assert pool.unregister(slot.name) is None


def test_model_pool_register_duplicate_overwrites():
    pool = ModelPool()
    pool.register(_make_slot("slot-1", "omnivoice-base"))
    pool.register(_make_slot("slot-1", "omnivoice-large"))
    got = pool.get("slot-1")
    assert got is not None
    assert got.model_id == "omnivoice-large"
    assert len(pool.list()) == 1


def test_health_extended_router_has_endpoint():
    paths = {r.path for r in router.routes}
    assert "/health/extended" in paths
