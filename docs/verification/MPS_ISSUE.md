# MPS (Apple Silicon GPU) Issue - CRITICAL

**Date**: 2026-04-04  
**Status**: ⚠️ MPS NOT WORKING - Use CPU instead

---

## Problem

When running OmniVoice server with `--device mps` (Apple Silicon GPU acceleration), all generated audio is unintelligible - sounds like "eh eh eh eh eh" instead of clear speech.

## Root Cause

**PyTorch MPS backend has incomplete/buggy implementation** for some operations used by the OmniVoice diffusion model. This is a known issue with PyTorch MPS support - not all operations are fully implemented or correct.

## Evidence

### MPS (Broken)
```bash
omnivoice-server --device mps --num-step 32
```
- Model loads: ✅ (8.1s, +168MB RAM)
- Audio generates: ✅ (15s per voice)
- Audio quality: ❌ Unintelligible "eh eh eh"
- File size: 180KB (looks normal)
- Waveform data: Valid (94% non-zero samples, proper dynamic range)

### CPU (Working)
```bash
omnivoice-server --device cpu --num-step 32
```
- Model loads: ✅ (15.1s, +1.7GB RAM)
- Audio generates: ✅ (57s per voice)
- Audio quality: ✅ Clear, intelligible speech
- File size: 271KB
- Waveform data: Valid

## Impact

- **MPS is 3.8x faster** (15s vs 57s per voice) but produces garbage audio
- **CPU is slow** but produces correct audio
- **No GPU acceleration available** on Apple Silicon for this model

## Workaround

**Always use CPU device:**

```bash
omnivoice-server --device cpu --num-step 32
```

Update `omnivoice_server/config.py`:
```python
class Config(BaseModel):
    device: str = Field(default="cpu")  # Changed from "mps" to "cpu"
    num_step: int = Field(default=32, ge=1, le=64)
```

## Performance Comparison

| Device | Load Time | Generation Time | RAM Usage | Audio Quality |
|--------|-----------|-----------------|-----------|---------------|
| MPS    | 8.1s      | 15s/voice       | +168MB    | ❌ Broken     |
| CPU    | 15.1s     | 57s/voice       | +1.7GB    | ✅ Working    |

## Future Resolution

This issue may be fixed in future PyTorch versions. To test if MPS is fixed:

1. Update PyTorch: `pip install --upgrade torch`
2. Test with MPS: `omnivoice-server --device mps --num-step 32`
3. Generate test audio and verify it's intelligible
4. If working, update default device back to MPS

## Related Issues

- PyTorch MPS backend: https://github.com/pytorch/pytorch/issues?q=is%3Aissue+mps
- OmniVoice may need to add MPS-specific workarounds or disable certain operations

## Recommendation

**For production: Use CPU device until MPS support is fixed in PyTorch.**

Accept the 3.8x slower generation time in exchange for correct audio output.
