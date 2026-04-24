# Changelog

Формат: [Keep a Changelog](https://keepachangelog.com/), версионирование по спринтам (`spX.dayY`).

## [Unreleased] — Sprint 1 Day 6-7

### Planned
- Day 6: клиентская интеграция в AI-Booker (`useOmniVoiceServer.ts`, кнопки в `VoiceReferenceManager`, `VoiceConversionTab`, Atmo Studio, MicRecorder)
- Day 7: эндпоинт `/v1/health/extended` (GPU/VRAM через `pynvml` + `loaded_models[]`); полировка; доки

---

## [sp1.day2-5] — 2026-04-24 — DeepFilterNet3 production-ready

Commit: `d7d75cb` (push в `origin/main`).

### Added
- `omnivoice_server/locks.py` — глобальный `MODEL_LOCK = asyncio.Lock()` (монопольный GPU)
- `omnivoice_server/services/denoise.py` — singleton `DenoiseService`, lazy init, 5-мин idle release, 3 пресета (light/med/strong), server-side resample через `soxr`
- `omnivoice_server/routers/denoise.py` — `POST /v1/audio/denoise` (multipart + query: `preset`, `sample_rate`, `atten_lim_db`)
  - Response headers: `X-Snr-Improvement-Db`, `X-Processing-Ms`, `X-Output-Sample-Rate`, `X-Preset-Used`
- `tests/test_denoise.py` — 8/8 passed (3 пресета, unknown preset 422, resample 24kHz, atten override, empty upload, presets constant)
- `scripts/apply_sprint1.sh` — idempotent патч-скрипт
- `pyproject.toml` — `[tool.pytest.ini_options] asyncio_mode = "auto"`

### Changed
- `services/inference.py.synthesize()` — обёрнут в `async with MODEL_LOCK` (TTS speech/clone/script все защищены)
- `app.py` — зарегистрирован `denoise router`

### Architectural
- Зафиксирован принцип concurrency: денойз НЕ параллелится с TTS (все три сценария применения денойза в Booker — sequential pre/post-processing). Решено в пользу простоты и предсказуемых латенси.

---

## [sp1.day1] — 2026-04-24 — DeepFilterNet3 smoke-test

### Added
- Rust 1.95.0 (rustup) — нужен для сборки `deepfilterlib==0.5.6` (нет cp312 wheels на PyPI)
- `pip install deepfilternet soxr` — успешно
- Калибровка пресетов на слух:
  - `atmo_light` → `atten_lim_db=10`
  - `microphone_med` → `atten_lim_db=15`
  - `voice_reference_strong` → `atten_lim_db=30`

### Verified
- DFNet cold start: 5.7s
- DFNet VRAM idle: 9 MB
- DFNet realtime: 18.2× на A4000
- Auto-resample 24→48 kHz внутри DFNet работает

---

## [sp0] — 2026-04-24 — Базовый форк

Базовый форк `omnivoice-server` собран и проверен на RTX A4000 (16 GB).

### Added
- Endpoints: `/health`, `/metrics`, `/v1/audio/speech`, `/v1/audio/speech/clone`, `/v1/audio/script`, `/v1/voices`, `/v1/voices/profiles`, `/v1/models`, `/v1/models/{id}`

### Verified
- 212/212 тестов passed (1m43s)
- OmniVoice холодный старт: 7.3s (~2.2 GB VRAM)
- TTS латенси: ~1.1s на 5.76s аудио (5.2× realtime)
- VRAM в простое: ~2.97 GB; пик при синтезе: +16 MiB
- Output: WAV PCM 16-bit mono **24 kHz** (нативный для OmniVoice)

### Architectural decisions
- Sample-rate mismatch (24 vs 44.1 kHz) → server-side resample через `soxr`, query param `?sample_rate=` запланирован параллельно со Sprint 1.
