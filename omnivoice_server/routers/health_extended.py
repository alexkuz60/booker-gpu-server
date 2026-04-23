"""Extended health endpoint — model pool, VRAM, GPU info, versions."""
from __future__ import annotations

import platform
import time
from typing import Any

from fastapi import APIRouter, Request

router = APIRouter(tags=["health"])

_STARTED_AT = time.monotonic()


def _vram_info() -> dict[str, Any]:
    try:
        import torch
        if not torch.cuda.is_available():
            return {"available": False}
        free, total = torch.cuda.mem_get_info()
        return {
            "available": True,
            "total_mb": round(total / 1024 / 1024, 1),
            "free_mb": round(free / 1024 / 1024, 1),
            "used_mb": round((total - free) / 1024 / 1024, 1),
        }
    except Exception as e:
        return {"available": False, "error": str(e)}


def _gpu_info() -> dict[str, Any]:
    try:
        import torch
        if not torch.cuda.is_available():
            return {"available": False}
        idx = torch.cuda.current_device()
        return {
            "available": True,
            "name": torch.cuda.get_device_name(idx),
            "index": idx,
            "capability": ".".join(map(str, torch.cuda.get_device_capability(idx))),
        }
    except Exception as e:
        return {"available": False, "error": str(e)}


def _versions() -> dict[str, Any]:
    out: dict[str, Any] = {"python": platform.python_version()}
    try:
        import torch
        out["torch"] = torch.__version__
        out["cuda"] = torch.version.cuda
    except Exception:
        out["torch"] = None
        out["cuda"] = None
    try:
        from omnivoice_server import __version__ as srv_ver
        out["server"] = srv_ver
    except Exception:
        out["server"] = "unknown"
    return out


@router.get("/health/extended")
async def health_extended(request: Request) -> dict[str, Any]:
    pool = getattr(request.app.state, "model_pool", None)
    models = []
    if pool is not None:
        for slot in pool.list():
            models.append({
                "name": slot.name,
                "engine": slot.engine,
                "model_id": slot.model_id,
                "device": slot.device,
                "dtype": slot.dtype,
                "loaded_at": slot.loaded_at,
            })
    return {
        "status": "ok",
        "uptime_sec": round(time.monotonic() - _STARTED_AT, 1),
        "models": models,
        "vram": _vram_info(),
        "gpu": _gpu_info(),
        "versions": _versions(),
    }

