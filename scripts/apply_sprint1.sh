#!/usr/bin/env bash
# ============================================================================
# Sprint 1 — DeepFilterNet3 hot-swap для booker-gpu-server
# Создаёт: locks.py, services/denoise.py, routers/denoise.py, tests/test_denoise.py
# Патчит:  app.py (роутер), services/inference.py (MODEL_LOCK)
# ============================================================================
set -euo pipefail

PROJECT="${HOME}/dev/booker-gpu-server"
PKG="${PROJECT}/omnivoice_server"

[ -d "$PKG" ] || { echo "❌ $PKG не найден"; exit 1; }
cd "$PROJECT"

echo "📁 Project: $PROJECT"

# ────────────────────────────────────────────────────────────────────────────
# 1. omnivoice_server/locks.py — глобальный MODEL_LOCK
# ────────────────────────────────────────────────────────────────────────────
cat > "$PKG/locks.py" <<'PY'
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
PY
echo "✅ Created omnivoice_server/locks.py"

# ────────────────────────────────────────────────────────────────────────────
# 2. omnivoice_server/services/denoise.py — DFNet singleton + lazy init + idle release
# ────────────────────────────────────────────────────────────────────────────
cat > "$PKG/services/denoise.py" <<'PY'
"""
DeepFilterNet3 service — lazy-loaded singleton with 5-min idle VRAM release.

Presets (calibrated by ear on RTX A4000, 2026-04-24):
  - light:  atten_lim_db=10  (минимальная чистка)
  - med:    atten_lim_db=15  (заметная чистка, без искажений)
  - strong: atten_lim_db=30  (идеально чисто, для клонирования голоса)

Output: WAV PCM 16-bit mono at requested sample_rate (default 48000).
"""
from __future__ import annotations

import asyncio
import io
import logging
import time
import wave
from dataclasses import dataclass

import numpy as np
import torch

logger = logging.getLogger(__name__)

# ── Presets ──────────────────────────────────────────────────────────────────
PRESETS: dict[str, dict] = {
    "light":  {"atten_lim_db": 10},
    "med":    {"atten_lim_db": 15},
    "strong": {"atten_lim_db": 30},
}
DEFAULT_PRESET = "med"
IDLE_RELEASE_S = 300  # 5 min


@dataclass
class DenoiseResult:
    audio_bytes: bytes        # WAV PCM 16-bit mono
    sample_rate: int
    snr_improvement_db: float
    processing_ms: int
    preset_used: str


class DenoiseService:
    """Lazy-loaded DFNet3 singleton with idle release."""

    def __init__(self) -> None:
        self._model = None
        self._df_state = None
        self._last_used: float = 0.0
        self._lock = asyncio.Lock()
        self._idle_task: asyncio.Task | None = None

    async def _ensure_loaded(self) -> None:
        if self._model is not None:
            return
        from df.enhance import init_df  # heavy import — defer
        logger.info("[denoise] Loading DeepFilterNet3...")
        t0 = time.monotonic()
        # init_df runs synchronously and downloads weights on first call
        loop = asyncio.get_running_loop()
        self._model, self._df_state, _ = await loop.run_in_executor(None, init_df)
        logger.info(f"[denoise] Loaded in {time.monotonic() - t0:.1f}s")
        if self._idle_task is None:
            self._idle_task = asyncio.create_task(self._idle_watchdog())

    async def _idle_watchdog(self) -> None:
        while True:
            await asyncio.sleep(60)
            if self._model is None:
                continue
            if time.monotonic() - self._last_used > IDLE_RELEASE_S:
                async with self._lock:
                    if self._model is None:
                        continue
                    if time.monotonic() - self._last_used <= IDLE_RELEASE_S:
                        continue
                    logger.info("[denoise] Idle release — freeing VRAM")
                    self._model = None
                    self._df_state = None
                    try:
                        torch.cuda.empty_cache()
                    except Exception:
                        pass

    async def denoise(
        self,
        audio_bytes: bytes,
        preset: str = DEFAULT_PRESET,
        target_sample_rate: int = 48000,
        atten_lim_db_override: float | None = None,
    ) -> DenoiseResult:
        if preset not in PRESETS:
            raise ValueError(f"Unknown preset '{preset}'. Use: {list(PRESETS)}")

        params = PRESETS[preset].copy()
        if atten_lim_db_override is not None:
            params["atten_lim_db"] = atten_lim_db_override

        await self._ensure_loaded()

        loop = asyncio.get_running_loop()
        t0 = time.monotonic()
        result = await loop.run_in_executor(
            None,
            self._run_sync,
            audio_bytes,
            params,
            target_sample_rate,
        )
        self._last_used = time.monotonic()

        out_wav, snr_db = result
        return DenoiseResult(
            audio_bytes=out_wav,
            sample_rate=target_sample_rate,
            snr_improvement_db=snr_db,
            processing_ms=int((time.monotonic() - t0) * 1000),
            preset_used=preset,
        )

    def _run_sync(
        self,
        audio_bytes: bytes,
        params: dict,
        target_sr: int,
    ) -> tuple[bytes, float]:
        from df.enhance import enhance
        from df.io import load_audio, save_audio
        import tempfile
        import os

        # Write input to temp wav (DFNet's load_audio expects a path)
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f_in:
            f_in.write(audio_bytes)
            in_path = f_in.name

        try:
            audio, _ = load_audio(in_path, sr=self._df_state.sr())
            # input RMS (for SNR delta proxy)
            in_rms = float(torch.sqrt(torch.mean(audio ** 2)).item()) + 1e-9

            enhanced = enhance(self._model, self._df_state, audio, atten_lim_db=params["atten_lim_db"])

            # Resample to target_sr if needed
            src_sr = self._df_state.sr()  # 48000
            if target_sr != src_sr:
                import soxr
                np_audio = enhanced.squeeze(0).cpu().numpy()
                resampled = soxr.resample(np_audio, src_sr, target_sr)
                enhanced = torch.from_numpy(resampled).unsqueeze(0)

            out_rms = float(torch.sqrt(torch.mean(enhanced ** 2)).item()) + 1e-9
            # Approx SNR delta: not precise without reference, but useful sanity metric
            snr_db = 20.0 * float(np.log10(out_rms / in_rms))

            # Encode to WAV PCM 16-bit mono
            np_out = enhanced.squeeze(0).cpu().numpy()
            np_out = np.clip(np_out, -1.0, 1.0)
            pcm16 = (np_out * 32767.0).astype(np.int16)

            buf = io.BytesIO()
            with wave.open(buf, "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(target_sr)
                w.writeframes(pcm16.tobytes())
            return buf.getvalue(), snr_db
        finally:
            try:
                os.unlink(in_path)
            except Exception:
                pass


# Module-level singleton
_service: DenoiseService | None = None


def get_denoise_service() -> DenoiseService:
    global _service
    if _service is None:
        _service = DenoiseService()
    return _service
PY
echo "✅ Created omnivoice_server/services/denoise.py"

# ────────────────────────────────────────────────────────────────────────────
# 3. omnivoice_server/routers/denoise.py — POST /v1/audio/denoise
# ────────────────────────────────────────────────────────────────────────────
cat > "$PKG/routers/denoise.py" <<'PY'
"""
POST /v1/audio/denoise
  multipart/form-data: file=<wav|mp3|flac|...>
  Query:
    preset=light|med|strong (default: med)
    sample_rate=16000..48000 (default: 48000)
    atten_lim_db=<float>     (override preset, optional)
  Response: audio/wav (PCM 16-bit mono)
  Headers: X-Snr-Improvement-Db, X-Processing-Ms, X-Output-Sample-Rate, X-Preset-Used
"""
from __future__ import annotations

import logging

from fastapi import APIRouter, File, HTTPException, Query, UploadFile, status
from fastapi.responses import Response

from ..locks import MODEL_LOCK
from ..services.denoise import PRESETS, get_denoise_service

logger = logging.getLogger(__name__)
router = APIRouter()


@router.post("/audio/denoise")
async def create_denoise(
    file: UploadFile = File(...),
    preset: str = Query(default="med"),
    sample_rate: int = Query(default=48000, ge=16000, le=48000),
    atten_lim_db: float | None = Query(default=None, ge=0.0, le=60.0),
):
    if preset not in PRESETS:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail=f"Unknown preset '{preset}'. Allowed: {list(PRESETS)}",
        )

    raw = await file.read()
    if not raw:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="Empty upload",
        )

    svc = get_denoise_service()
    async with MODEL_LOCK:
        try:
            result = await svc.denoise(
                audio_bytes=raw,
                preset=preset,
                target_sample_rate=sample_rate,
                atten_lim_db_override=atten_lim_db,
            )
        except Exception as e:
            logger.exception("Denoise failed")
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=f"Denoise failed: {e}",
            )

    return Response(
        content=result.audio_bytes,
        media_type="audio/wav",
        headers={
            "X-Snr-Improvement-Db": f"{result.snr_improvement_db:.2f}",
            "X-Processing-Ms": str(result.processing_ms),
            "X-Output-Sample-Rate": str(result.sample_rate),
            "X-Preset-Used": result.preset_used,
        },
    )
PY
echo "✅ Created omnivoice_server/routers/denoise.py"

# ────────────────────────────────────────────────────────────────────────────
# 4. Patch app.py — import + include_router
# ────────────────────────────────────────────────────────────────────────────
APP="$PKG/app.py"
if grep -q "from .routers import.*denoise" "$APP"; then
    echo "ℹ️  app.py: denoise router already imported"
else
    # Replace the routers import line
    python3 - "$APP" <<'PYE'
import sys, re
p = sys.argv[1]
s = open(p).read()
s = re.sub(
    r"from \.routers import (.*)",
    lambda m: f"from .routers import {m.group(1)}, denoise" if "denoise" not in m.group(1) else m.group(0),
    s, count=1
)
# Add include_router right after script.router include
if "denoise.router" not in s:
    s = s.replace(
        'app.include_router(script.router, prefix="/v1")',
        'app.include_router(script.router, prefix="/v1")\n    app.include_router(denoise.router, prefix="/v1")',
        1,
    )
open(p, "w").write(s)
print("  patched:", p)
PYE
fi
echo "✅ Patched app.py"

# ────────────────────────────────────────────────────────────────────────────
# 5. Patch services/inference.py — wrap synthesize() in MODEL_LOCK
# ────────────────────────────────────────────────────────────────────────────
INF="$PKG/services/inference.py"
if grep -q "from ..locks import MODEL_LOCK" "$INF"; then
    echo "ℹ️  inference.py: MODEL_LOCK already imported"
else
    python3 - "$INF" <<'PYE'
import sys
p = sys.argv[1]
s = open(p).read()
# Add import after `from .model import ModelService`
s = s.replace(
    "from .model import ModelService",
    "from .model import ModelService\nfrom ..locks import MODEL_LOCK",
    1,
)
# Wrap semaphore block in MODEL_LOCK
old = """        async with self._semaphore:
            result = await asyncio.wait_for(
                loop.run_in_executor(
                    self._executor,
                    self._run_sync,
                    req,
                ),
                timeout=timeout_s,
            )"""
new = """        async with MODEL_LOCK:
            async with self._semaphore:
                result = await asyncio.wait_for(
                    loop.run_in_executor(
                        self._executor,
                        self._run_sync,
                        req,
                    ),
                    timeout=timeout_s,
                )"""
if old not in s:
    print("  ❌ Не найден ожидаемый блок semaphore в inference.py — патч не применён")
    sys.exit(1)
s = s.replace(old, new, 1)
open(p, "w").write(s)
print("  patched:", p)
PYE
fi
echo "✅ Patched services/inference.py"

# ────────────────────────────────────────────────────────────────────────────
# 6. tests/test_denoise.py
# ────────────────────────────────────────────────────────────────────────────
mkdir -p tests
cat > tests/test_denoise.py <<'PY'
"""
Tests for /v1/audio/denoise endpoint and DenoiseService.

NOTE: Loading DeepFilterNet3 is heavy (~5s + downloads weights). These tests
are real integration tests, not mocks — they require GPU/CPU torch to actually
run. Mark as slow if needed: pytest -m "not slow" to skip.
"""
from __future__ import annotations

import io
import wave

import numpy as np
import pytest
from fastapi.testclient import TestClient

from omnivoice_server.app import create_app
from omnivoice_server.config import Settings
from omnivoice_server.services.denoise import PRESETS


@pytest.fixture(scope="module")
def client():
    cfg = Settings()
    app = create_app(cfg)
    with TestClient(app) as c:
        yield c


def _make_test_wav(duration_s: float = 1.0, sr: int = 48000) -> bytes:
    """Generate a noisy sine wave at 440 Hz for testing."""
    t = np.linspace(0, duration_s, int(sr * duration_s), endpoint=False)
    sine = 0.3 * np.sin(2 * np.pi * 440 * t)
    noise = 0.05 * np.random.randn(len(t))
    audio = (sine + noise).astype(np.float32)
    pcm16 = np.clip(audio * 32767, -32768, 32767).astype(np.int16)

    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm16.tobytes())
    return buf.getvalue()


def test_denoise_preset_light(client):
    wav = _make_test_wav()
    r = client.post(
        "/v1/audio/denoise?preset=light&sample_rate=48000",
        files={"file": ("noise.wav", wav, "audio/wav")},
    )
    assert r.status_code == 200
    assert r.headers["content-type"] == "audio/wav"
    assert r.headers["x-preset-used"] == "light"
    assert int(r.headers["x-output-sample-rate"]) == 48000
    assert int(r.headers["x-processing-ms"]) > 0


def test_denoise_preset_med(client):
    wav = _make_test_wav()
    r = client.post(
        "/v1/audio/denoise?preset=med",
        files={"file": ("noise.wav", wav, "audio/wav")},
    )
    assert r.status_code == 200
    assert r.headers["x-preset-used"] == "med"


def test_denoise_preset_strong(client):
    wav = _make_test_wav()
    r = client.post(
        "/v1/audio/denoise?preset=strong",
        files={"file": ("noise.wav", wav, "audio/wav")},
    )
    assert r.status_code == 200
    assert r.headers["x-preset-used"] == "strong"


def test_denoise_unknown_preset_returns_422(client):
    wav = _make_test_wav()
    r = client.post(
        "/v1/audio/denoise?preset=nuclear",
        files={"file": ("noise.wav", wav, "audio/wav")},
    )
    assert r.status_code == 422


def test_denoise_resample_to_24khz(client):
    wav = _make_test_wav()
    r = client.post(
        "/v1/audio/denoise?preset=med&sample_rate=24000",
        files={"file": ("noise.wav", wav, "audio/wav")},
    )
    assert r.status_code == 200
    assert int(r.headers["x-output-sample-rate"]) == 24000


def test_denoise_atten_override(client):
    wav = _make_test_wav()
    r = client.post(
        "/v1/audio/denoise?preset=med&atten_lim_db=20",
        files={"file": ("noise.wav", wav, "audio/wav")},
    )
    assert r.status_code == 200


def test_denoise_empty_upload_returns_422(client):
    r = client.post(
        "/v1/audio/denoise?preset=med",
        files={"file": ("empty.wav", b"", "audio/wav")},
    )
    assert r.status_code == 422


def test_presets_constant_has_three_entries():
    assert set(PRESETS.keys()) == {"light", "med", "strong"}
    assert PRESETS["light"]["atten_lim_db"] == 10
    assert PRESETS["med"]["atten_lim_db"] == 15
    assert PRESETS["strong"]["atten_lim_db"] == 30
PY
echo "✅ Created tests/test_denoise.py"

# ────────────────────────────────────────────────────────────────────────────
# 7. Verify deps installed
# ────────────────────────────────────────────────────────────────────────────
echo ""
echo "🔍 Checking dependencies..."
python3 -c "from df.enhance import init_df; print('  ✅ deepfilternet OK')" || {
    echo "  ❌ deepfilternet not importable — run: pip install deepfilternet"
    exit 1
}
python3 -c "import soxr; print('  ✅ soxr OK')" || {
    echo "  ❌ soxr not importable — run: pip install soxr"
    exit 1
}

echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo "✅ Sprint 1 файлы созданы и патчи применены"
echo "═══════════════════════════════════════════════════════════════════════"
echo ""
echo "Дальше:"
echo "  1. pytest tests/test_denoise.py -v       # 8 новых тестов"
echo "  2. pytest -v                             # 212 + 8 = 220 тестов"
echo "  3. uvicorn omnivoice_server.cli:app ...  # запуск (cli, не app!)"
echo "     или python -m omnivoice_server"
echo ""
echo "  Live-проверка после старта сервера:"
echo "  curl -X POST 'http://localhost:8000/v1/audio/denoise?preset=strong&sample_rate=48000' \\"
echo "    -F 'file=@/tmp/test.wav' -D /tmp/headers.txt -o /tmp/out.wav"
echo "  grep -E 'X-Snr|X-Processing|X-Output|X-Preset' /tmp/headers.txt"
