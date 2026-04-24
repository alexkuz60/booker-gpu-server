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
