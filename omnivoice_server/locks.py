"""
Global async lock guaranteeing exclusive GPU access across all model services.

WHY:
  TTS (OmniVoice), denoise (DeepFilterNet3), and future heavy models share
  ONE CUDA context / VRAM pool. Concurrent calls would either OOM or thrash
  context switches. Sequential is faster and more predictable.

Usage:
    from omnivoice_server.locks import MODEL_LOCK
    async with MODEL_LOCK:
        result = await heavy_gpu_call(...)
"""
from __future__ import annotations
import asyncio

# Module-level singleton — created once at import time on the running event loop.
# FastAPI uses a single event loop per worker, so this is safe.
MODEL_LOCK = asyncio.Lock()
