"""
Audio encoding helpers.
All functions are pure (no side effects) and synchronous.
"""

from __future__ import annotations

import io

import numpy as np
import soundfile as sf
import torch

SAMPLE_RATE = 24_000


def tensor_to_wav_bytes(tensor: torch.Tensor | np.ndarray) -> bytes:
    """
    Convert (1, T) float32 tensor or numpy array to 16-bit PCM WAV bytes.
    """
    # Handle both torch.Tensor and numpy.ndarray (e.g., when running on CUDA)
    if isinstance(tensor, np.ndarray):
        tensor = torch.from_numpy(tensor)
    cpu_tensor = tensor.detach().cpu()
    if cpu_tensor.dim() == 1:
        cpu_tensor = cpu_tensor.unsqueeze(0)

    if cpu_tensor.dim() == 2:
        if cpu_tensor.shape[0] == 1:
            cpu_tensor = cpu_tensor.squeeze(0)  # (T,) mono
        else:
            cpu_tensor = cpu_tensor.T  # (C, T) -> (T, C)

    buf = io.BytesIO()
    sf.write(buf, cpu_tensor.numpy(), SAMPLE_RATE, format="WAV", subtype="PCM_16")
    buf.seek(0)
    return buf.read()


def tensors_to_wav_bytes(tensors: list[torch.Tensor | np.ndarray]) -> bytes:
    """
    Concatenate multiple (1, T) tensors into a single WAV.
    """
    if len(tensors) == 1:
        return tensor_to_wav_bytes(tensors[0])
    # Convert numpy arrays to tensors if needed, then concatenate
    tensor_list = []
    for t in tensors:
        if isinstance(t, np.ndarray):
            t = torch.from_numpy(t)
        tensor_list.append(t.cpu())
    combined = torch.cat(tensor_list, dim=-1)
    return tensor_to_wav_bytes(combined)


def tensor_to_pcm16_bytes(tensor: torch.Tensor | np.ndarray) -> bytes:
    """
    Convert (1, T) float32 tensor or numpy array to raw PCM int16 bytes.
    Used for streaming — no WAV header, continuous byte stream.
    """
    # Handle both torch.Tensor and numpy.ndarray (e.g., when running on CUDA)
    if isinstance(tensor, np.ndarray):
        tensor = torch.from_numpy(tensor)
    flat = tensor.squeeze(0).detach().cpu()  # (T,)
    return (flat * 32767).clamp(-32768, 32767).to(torch.int16).numpy().tobytes()


def read_upload_bounded(data: bytes, max_bytes: int, field_name: str = "ref_audio") -> bytes:
    """
    Validates upload size after reading.
    """
    if len(data) == 0:
        raise ValueError(f"{field_name} is empty")
    if len(data) > max_bytes:
        mb = len(data) / 1024 / 1024
        limit_mb = max_bytes / 1024 / 1024
        raise ValueError(f"{field_name} too large: {mb:.1f} MB (limit: {limit_mb:.0f} MB)")
    return data


def validate_audio_bytes(data: bytes, field_name: str = "ref_audio") -> None:
    """
    Lightweight validation: check that bytes are parseable as audio.
    Does NOT decode the full file — only reads metadata.
    """
    try:
        buf = io.BytesIO(data)
        info = sf.info(buf)
        if info.frames == 0:
            raise ValueError(f"{field_name}: audio file has 0 frames")
        if info.samplerate < 8000:
            raise ValueError(f"{field_name}: sample rate {info.samplerate}Hz too low (min 8000Hz)")
    except Exception as e:
        if isinstance(e, ValueError):
            raise
        raise ValueError(
            f"{field_name}: could not parse as audio file. "
            "Supported formats: WAV, MP3, FLAC, OGG. "
            f"Original error: {e}"
        ) from e
