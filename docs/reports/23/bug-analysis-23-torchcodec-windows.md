# Bug Report: torchcodec Failure on Windows

- **Issue**: [#23 - Synthesis fails with 500 error: RuntimeError: Could not load libtorchcodec (Windows)](https://github.com/maemreyo/omnivoice-server/issues/23)
- **Author**: tombinary07
- **Status**: Open
- **Date**: 2026-04-18
- **Severity**: Medium — blocks voice cloning on Windows; design mode unaffected

---

## 1. Bug Description

When attempting to use the `/v1/audio/speech` endpoint to synthesize speech in **voice cloning mode** (i.e., when using a voice profile or uploading reference audio), the server returns a `500 Internal Server Error`.

The crash occurs during the ASR (Whisper) transcription phase when `torchcodec` fails to load its core libraries:

```
RuntimeError: Could not load libtorchcodec. Likely causes:
  1. FFmpeg is not properly installed in your environment. We support
     versions 4, 5, 6, 7, and 8, and we attempt to load libtorchcodec
     for each of those versions. On Windows, ensure you've installed the
     "full-shared" version which ships DLLs.
  2. The PyTorch version (2.8.0+cu128) is not compatible with
     this version of TorchCodec.
FileNotFoundError: Could not find module 'C:\path\to\env\Lib\site-packages\torchcodec\libtorchcodec_core8.dll'
```

> **Note on error format**: The actual error is a `RuntimeError` that **wraps multiple** `FileNotFoundError` entries (one per FFmpeg major version attempted: 8→7→6→5→4). The path uses backslashes on Windows (`\`), not forward slashes. The error does NOT appear as a standalone `FileNotFoundError` at the top level — it is nested as part of the `RuntimeError`'s context.

### Steps to Reproduce

1. Run `omnivoice-server` on Windows via Uvicorn
2. Send a POST request to `/v1/audio/speech` with a `speaker` or `voice` parameter pointing to an existing voice profile
3. Server begins loading `openai/whisper-large-v3-turbo` for ASR transcription
4. Synthesis fails with `RuntimeError: Could not load libtorchcodec`

---

## 2. Workarounds

### Workaround A: Provide `ref_text` Manually

If users provide the transcription of the reference audio explicitly, the ASR transcription step is **skipped entirely**, and the bug is avoided.

- **For `/v1/audio/speech/clone`**: Provide `ref_text` form field
- **For `/v1/audio/speech` with voice profile**: No workaround — the server generates `ref_text` internally via ASR

### Workaround B: Install FFmpeg "Full-Shared" on Windows

On Windows, `torchcodec` requires FFmpeg built with **shared libraries** (DLLs), not the typical static build. Users must install:
- [FFmpeg Builds](https://www.gyan.dev/ffmpeg/builds/) → select `full-shared` variant

This is fragile and not recommended for production — many Windows users report the DLL still fails to load even with the correct FFmpeg build.

### Workaround C: Use Design Mode Instead of Clone Mode

The `/v1/audio/speech` endpoint with explicit `instructions` (voice design) does **not** use ASR, so it is unaffected by this bug.

---

## 3. Root Cause Analysis

### 3.1 Code Flow

The bug is triggered by this call chain:

```
POST /v1/audio/speech (with voice profile)
  → _resolve_synthesis_mode() → mode="clone"
    → inference_svc.synthesize(req)
      → model.generate(**kwargs) [OmniVoice]
        → _preprocess_all() [intermediate step at line 546]
          → create_voice_clone_prompt(ref_audio, ref_text=None) [line 934-942]
            → ref_text is None → triggers auto-transcription [line 664-669]
              → self.load_asr_model() [lazy load Whisper]
                → hf_pipeline("automatic-speech-recognition", ...)
                  → import torchcodec ← CRASH
```

**Key code** — `OmniVoice/omnivoice/models/omnivoice.py:664-669`:
```python
# Auto-transcribe if ref_text not provided
if ref_text is None:
    if self._asr_pipe is None:
        logger.info("ASR model not loaded yet, loading on-the-fly ...")
        self.load_asr_model()
    ref_text = self.transcribe((ref_wav, self.sampling_rate))
```

### 3.2 Why Design Mode Works

Design mode (voice design via `instructions`) does **not** call `create_voice_clone_prompt()`. It only generates speech from text using the instruction embedding — no reference audio, no ASR transcription, no `torchcodec` import.

### 3.3 Why torchcodec Fails on Windows

`torchcodec==0.11` is a PyTorch-native audio decoder that wraps FFmpeg. On Windows:

1. `torchcodec` ships a DLL stub (`libtorchcodec_core8.dll`) that dynamically loads FFmpeg DLLs at import time
2. The standard Windows FFmpeg installation (via `choco`, `scoop`, or `apt`) provides the FFmpeg **static** build — not the shared DLL build
3. Even the `full-shared` FFmpeg build from gyan.dev may fail due to:
   - Missing Visual C++ runtime DLLs
   - Path issues with FFmpeg's DLL search order on Windows
   - Version mismatch between `torchcodec_core8.dll` and actual FFmpeg DLLs

The error is **not** that `torchcodec` package is missing — it is installed. The error is that `torchcodec`'s internal FFmpeg loader **cannot find the FFmpeg DLLs** it needs.

### 3.4 Why torchcodec is a Dependency

`torchcodec` enters the pipeline because:

1. The `transformers` library (v5.3.0+) uses `torchcodec` as one of its audio backends for the Whisper ASR pipeline
2. When `torchcodec` is installed in the environment, `transformers.utils.is_torchcodec_available()` returns `True`
3. When `transformers` processes an audio input during pipeline execution, it imports `torchcodec` to check if the input is a `torchcodec.decoders.AudioDecoder` instance; this import happens inside the `preprocess()` method, **not** at module load time
4. The `import torchcodec` statement triggers FFmpeg DLL loading, which fails on Windows without proper FFmpeg shared libraries

**Note**: The `omnivoice` library itself uses `soundfile` + `librosa` for audio loading (not `torchcodec`). The `torchcodec` dependency comes from the `transformers` library's Whisper ASR pipeline, which is loaded only when auto-transcription is needed.

### 3.5 Dependency Chain

```
omnivoice-server
├── omnivoice (Python library)
│   └── transformers>=5.3.0  [ASR pipeline]
│       └── torchcodec>=0.11 [audio decoding, optional but imported if present]
│           └── ffmpeg shared DLLs [required at runtime, missing on Windows standard installs]
└── torch==2.8.0+cu128
```

---

## 4. Possible Solutions

### 4.1 Uninstall torchcodec Before ASR Load (Recommended — Replaces Incorrect Monkey-Patch)

**Effort**: Low | **Risk**: Low | **Impact**: Fixes the symptom

> ⚠️ **Correction (2026-04-19)**: The original proposal to monkey-patch `import_utils._torchcodec_available = False` **does not work** because that variable does not exist in `transformers.utils.import_utils`. The `is_torchcodec_available()` function is defined as:
> ```python
> @lru_cache
> def is_torchcodec_available() -> bool:
>     return _is_package_available("torchcodec")[0]
> ```
> It has no module-level `_torchcodec_available` variable. The `@lru_cache` decorator also means any patch after first call would have no effect anyway.

**Working approach**: Uninstall `torchcodec` before the ASR pipeline loads, which forces `transformers` to use `torchaudio`/`soundfile` as fallback:

```python
# In load_asr_model() — add before the pipeline creation:
import subprocess
subprocess.run(["pip", "uninstall", "-y", "torchcodec"], capture_output=True)
```

Or more elegantly, ensure `torchcodec` is not installed in the first place. Since `torchcodec` is only needed for the ASR pipeline (not for OmniVoice's core TTS), you can install `omnivoice-server` without the dev dependencies that pull in `torchcodec`.

**Why this works**: `transformers.utils.is_torchcodec_available()` calls `importlib.util.find_spec("torchcodec")`. If the package is not installed, it returns `False`, and the ASR pipeline never attempts to import `torchcodec`.

**Pros**:
- Clean fix, no monkey-patching
- `torchaudio` and `soundfile` are already installed as OmniVoice dependencies
- No breaking changes for other users

**Cons**:
- Requires `pip uninstall` which may fail in some environments (use `try/except`)
- If other code in the same process legitimately needs `torchcodec`, it will be unavailable

**Files to modify**:
- `OmniVoice/omnivoice/models/omnivoice.py` — `load_asr_model()` method

### 4.2 Downgrade `datasets` to <4.0

**Effort**: Low | **Risk**: Low | **Impact**: Removes `torchcodec` from dependency chain

The `datasets` library v4.0+ switched to `torchcodec` for audio decoding. Downgrading to `datasets<4.0` restores the old `soundfile`/`librosa` backend:

```toml
# pyproject.toml
dependencies = [
    "datasets<4.0",
]
```

**Pros**: Removes `torchcodec` usage at the source
**Cons**: 
- May break other dependencies that require `datasets>=4.0`
- `omnivoice` does not directly depend on `datasets`, but `transformers` does transitively

### 4.3 Replace Whisper Pipeline with faster-whisper

**Effort**: High | **Risk**: Medium | **Impact**: Full fix, better performance

Replace the `transformers` Whisper pipeline with `faster-whisper` (CTranslate2-based, no `torchcodec` dependency):

```python
# In load_asr_model():
from faster_whisper import WhisperModel

self._asr_pipe = WhisperModel(
    model_name,  # e.g., "large-v3-turbo"
    device=self.device,
    compute_type="float16" if str(self.device).startswith("cuda") else "int8",
)
```

And update `transcribe()` to use `faster-whisper` API instead of `transformers.pipeline`.

**Pros**:
- No `torchcodec` dependency at all
- Faster inference (CTranslate2 optimization)
- No Windows-specific issues

**Cons**:
- Requires testing to ensure output parity with `transformers` Whisper
- API is different, requires code changes in multiple places
- `faster-whisper` uses different model files (must download separately)

**Files to modify**:
- `OmniVoice/omnivoice/models/omnivoice.py` — `load_asr_model()`, `transcribe()`
- Possibly `OmniVoice/omnivoice/cli/demo.py` if it uses ASR directly

### 4.4 Use FunASR Instead

**Effort**: High | **Risk**: Medium | **Impact**: Full fix

[FunASR](https://github.com/modelscope/FunASR) (Alibaba) is a well-supported ASR library that primarily uses `torchaudio` for audio loading. It also supports Paraformer and SenseVoice models alongside Whisper.

**Pros**: Production-grade, actively maintained
**Cons**: 
- Different API, requires code changes, possible output differences
- ⚠️ **Caveat**: Recent `torchaudio` versions (2.x) may internally fall back to `torchcodec` for audio decoding, which can trigger the same DLL loading failure on Windows (see [FunASR Issue #81](https://github.com/FunAudioLLM/Fun-ASR/issues/81)). FunASR is NOT guaranteed to be torchcodec-free if `torchaudio` 2.x is installed.

### 4.5 Fix FFmpeg Installation on Windows (Documentation Fix)

**Effort**: Low | **Risk**: N/A | **Impact**: Workaround, not a code fix

Improve documentation to clearly explain Windows FFmpeg requirements:

1. Add a **Windows-specific troubleshooting section** in `docs/readme/sections/14-troubleshooting.md`
2. Document the exact FFmpeg variant needed (`full-shared`, not `full`)
3. Provide step-by-step Windows installation instructions
4. Add a **diagnostic check** at server startup that verifies `torchcodec` can load

**Pros**: No code changes
**Cons**: Still requires users to install correct FFmpeg; does not fix the root issue

### 4.6 Make ASR Optional with Graceful Degradation

**Effort**: Medium | **Risk**: Low | **Impact**: User-friendly

Wrap the ASR loading in a try-except. If `torchcodec` fails:

1. Log a **warning** that auto-transcription is unavailable
2. If `ref_text` is not provided, raise a **helpful error** explaining the situation and suggesting `ref_text` as workaround
3. Allow synthesis to continue in design mode as fallback

```python
def load_asr_model(self, model_name: str = "openai/whisper-large-v3-turbo"):
    try:
        import subprocess
        subprocess.run(["pip", "uninstall", "-y", "torchcodec"], capture_output=True)
    except Exception:
        pass  # Best effort — if it fails, continue and let the pipeline fail naturally
    
    try:
        # ... existing pipeline creation ...
    except RuntimeError as e:
        if "torchcodec" in str(e):
            logger.warning(
                "torchcodec failed to load. "
                "Auto-transcription will be skipped. "
                "Please provide ref_text manually or install FFmpeg full-shared on Windows."
            )
            self._asr_pipe = None
            return
        raise
```

---

## 5. Recommendation

| Priority | Solution | Rationale |
|----------|----------|-----------|
| **1st (Quick Fix)** | **4.1 + 4.6** — Uninstall torchcodec + graceful degradation | Clean fix (not monkey-patch), immediate relief |
| **2nd (Proper Fix)** | **4.3** — Replace with faster-whisper | Eliminates `torchcodec` dependency entirely, better performance |
| **Ongoing** | **4.6** — Better error messages | Always helpful regardless of which fix is chosen |

### Immediate Action Items

1. Apply uninstall + try-except in `load_asr_model()` (5 lines)
2. Add diagnostic warning at model load time if `torchcodec` is unavailable
3. Update `docs/readme/sections/14-troubleshooting.md` with Windows FFmpeg instructions
4. (Future) Consider replacing `transformers` Whisper with `faster-whisper`

---

## 6. Files Referenced

| File | Relevance |
|------|-----------|
| `omnivoice_server/routers/speech.py` | HTTP endpoint, calls `inference_svc.synthesize()` |
| `omnivoice_server/services/inference.py` | Orchestrates synthesis |
| `omnivoice_server/services/model.py` | Loads OmniVoice model |
| `OmniVoice/omnivoice/models/omnivoice.py` | Core model: `load_asr_model()`, `transcribe()`, `create_voice_clone_prompt()` |
| `OmniVoice/omnivoice/utils/audio.py` | Audio loading: `load_audio()`, `load_waveform()` (uses soundfile/librosa, not torchcodec) |
| `OmniVoice/pyproject.toml` | `transformers>=5.3.0` dependency |
| `omnivoice_server/pyproject.toml` | `torchcodec>=0.11` in `[project.optional-dependencies]` (dev only) |
| `Dockerfile.cuda` | `torchcodec==0.11` installed as required dependency |

---

## 7. External References

- [torchcodec GitHub](https://github.com/pytorch/torchcodec)
- [torchcodec PR #1109 - Fix load_torchcodec_shared_libraries on Windows](https://github.com/pytorch/torchcodec/pull/1109) (Dec 2025)
- [torchcodec Issue #1233 - RuntimeError on Windows import](https://github.com/pytorch/torchcodec/issues/1233)
- [torchcodec Issue #1014 - Windows DLL loading](https://github.com/pytorch/torchcodec/issues/1014)
- [transformers#42499 - ASR pipeline torchcodec bug](https://github.com/huggingface/transformers/issues/42499)
- [HuggingFace Forums - torchcodec + Windows](https://discuss.huggingface.co/t/issue-with-torchcodec-when-fine-tuning-whisper-asr-model/169315)
- [FunASR Issue #81 - torchaudio load fails with TorchCodec](https://github.com/FunAudioLLM/Fun-ASR/issues/81)
- [Whisper pipeline docs](https://huggingface.co/docs/transformers/main/model_doc/whisper)
- [faster-whisper](https://github.com/guillaumekln/faster-whisper)
- [FunASR](https://github.com/modelscope/FunASR)
