# booker-gpu-server

Универсальный локальный GPU-сервер для тяжёлых моделей экосистемы **Booker** (создание аудиокниг). Форк [`k2-fsa/omnivoice-server`](https://github.com/k2-fsa/OmniVoice) с архитектурой hot-swap моделей: один CUDA-контекст, один VRAM-пул, lazy load + idle release.

> ⚠️ **Этот репозиторий — НЕ веб-приложение.** Это Python/FastAPI сервер с CUDA, запускается на локальной машине пользователя. Lovable-проект используется как code editor + GitHub mirror; preview-панель Lovable не применима.

## Парный проект

Клиент этого сервера — веб-приложение **AI-Booker** (Букер-Студио Про), живёт в соседнем Lovable-проекте того же воркспейса.

## Целевые модели

| # | Модель | Назначение | Статус |
|---|---|---|---|
| 1 | OmniVoice | TTS (10+ пресетов, voice cloning, multi-speaker) | ✅ Sprint 0 |
| 2 | DeepFilterNet3 | Denoise (atmo / mic / voice reference) | ✅ Sprint 1 (Day 6-7 в работе) |
| 3 | MusicGen | Генерация музыки | Sprint 2 |
| 4 | AudioGen | Звуковые эффекты | Sprint 3 |
| 5 | RVC-batch | Voice conversion для длинных глав | Sprint 4 |
| 6 | Whisper-large | Транскрипция | Sprint 5 |
| 7 | Demucs / UVR5 | Разделение источников | Sprint 6 |

## Архитектура

- **Concurrency**: единый `MODEL_LOCK = asyncio.Lock()` — все модели сериализуются на GPU. Решение зафиксировано 2026-04-24: денойз и TTS НЕ параллельны во всех текущих сценариях Booker (pre/post-processing референса, атмосферных звуков, записи с микрофона). Пересмотр в Sprint 2 (MusicGen может работать параллельно с TTS).
- **Hot-swap**: модель грузится в VRAM при первом запросе и выгружается через **5 мин неактивности** (`torch.cuda.empty_cache()`).
- **Sample-rate**: server-side resample через `soxr`. Query param `?sample_rate=` (range 16000..48000) на всех аудио-эндпоинтах. OmniVoice нативно 24 kHz, DFNet — 48 kHz.

Подробнее — `mem://architecture` и `mem://api-contract` (memory этого Lovable-проекта).

## Стек

- Python 3.12, FastAPI, Uvicorn
- PyTorch + CUDA 12.x
- soxr, soundfile / torchaudio
- pytest + pytest-asyncio (`asyncio_mode = "auto"`)
- Rust (rustup) для сборки `deepfilterlib==0.5.6` (нет cp312 wheels)

## Целевая железка

**RTX A4000, 16 GB VRAM**. Все цифры латенси/VRAM в документации — относительно неё.

| Метрика | Значение |
|---|---|
| Sprint 0 тесты | 212/212 passed (1m43s) |
| OmniVoice cold start | 7.3s (~2.2 GB VRAM) |
| TTS латенси | ~1.1s на 5.76s аудио (5.2× realtime) |
| DFNet cold start | 5.7s |
| DFNet realtime | 18.2× |
| VRAM idle | ~2.97 GB |

## Локальный запуск

> Этот репозиторий — mirror для AI-доступа через Lovable. Реальный запуск — в локальной копии (`~/dev/booker-gpu-server`).

```bash
# Активировать venv
source .venv/bin/activate

# Установить зависимости (нужен rustup для DFNet)
pip install -e .
pip install deepfilternet soxr pynvml

# Запустить сервер
uvicorn omnivoice_server.app:app --host 0.0.0.0 --port 8000 --reload

# Тесты
pytest -v
pytest tests/test_denoise.py -v
```

## API endpoints (кратко)

| Метод | Путь | Назначение |
|---|---|---|
| GET | `/health` | Базовый health |
| GET | `/metrics` | Counters + latency |
| GET | `/v1/health/extended` | **Sprint 1 Day 7** — GPU/VRAM + loaded models |
| POST | `/v1/audio/speech` | OpenAI-compatible TTS |
| POST | `/v1/audio/speech/clone` | Voice cloning (multipart) |
| POST | `/v1/audio/script` | Multi-speaker диалоги |
| POST | `/v1/audio/denoise` | DeepFilterNet3 (preset / sample_rate / atten_lim_db) |
| GET | `/v1/voices`, `/v1/voices/profiles` | Голоса и профили |
| GET | `/v1/models`, `/v1/models/{id}` | Загруженные модели |

Полный контракт с headers и query — `mem://api-contract`.

## Связанные репо

- Локальный originator: `~/dev/booker-gpu-server` (push в `origin/main`)
- Lovable mirror: создаётся при подключении GitHub-интеграции в этом проекте

См. `CHANGELOG.md` для истории изменений.
