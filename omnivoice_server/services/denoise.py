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
