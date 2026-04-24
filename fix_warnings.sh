#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.." 2>/dev/null || cd ~/dev/booker-gpu-server

# 1. Установить pytest-asyncio (убирает "Unknown config option: asyncio_mode")
pip install -q pytest-asyncio

# 2. Убедиться, что pyproject.toml содержит правильную секцию
python3 - << 'PY'
import re, pathlib
p = pathlib.Path("pyproject.toml")
src = p.read_text()
if "[tool.pytest.ini_options]" not in src:
    src += '\n[tool.pytest.ini_options]\nasyncio_mode = "auto"\n'
elif "asyncio_mode" not in src:
    src = re.sub(r"(\[tool\.pytest\.ini_options\][^\[]*)",
                 r'\1asyncio_mode = "auto"\n', src, count=1)
p.write_text(src)
print("✅ pyproject.toml: asyncio_mode = auto")
PY

echo ""
echo "ℹ️  torchaudio warning — внутри библиотеки df/io.py (DeepFilterNet)."
echo "    Лечится только: pip install -U deepfilternet  (когда выйдет фикс upstream)"
echo "    Сейчас можно подавить через filterwarnings в pyproject.toml — добавить?"
