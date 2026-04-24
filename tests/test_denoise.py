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
