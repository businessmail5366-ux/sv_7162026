# WAN 2.2 I2V (GGUF) — Serverless на Vast.ai

Порт RunPod-воркера (`runpod-wan22-b200`) на Vast.ai Serverless. Тот же воркфлоу
(WAN 2.2 I2V GGUF Q8 high/low + LoRA + NAG + RIFE x2 + ColorMatch + Sharpen),
тот же API-смысл: `image_url` + `width`/`height` → mp4.

## Чем отличается от RunPod

| | RunPod | Vast.ai |
|---|---|---|
| Хранение моделей | Network volume, монтируется в каждый воркер | **Network volume нет.** Модели скачиваются на локальный NVMe воркера один раз при его создании (provisioning). Диск остаётся у остановленного воркера — холодный старт быстрый |
| Код воркера | Свой Docker-образ + handler.py | Готовый шаблон **ComfyUI (Serverless)** + pyworker `comfyui-json`. Свой образ не нужен |
| Логика handler.py | На сервере | В клиенте ([vast_request.py](vast_request.py)) — клиент собирает весь workflow JSON и шлёт на `/generate/sync` |
| Выдача видео | R2 (BUCKET_* env) или base64 | Тот же R2 (S3_* env), в ответе presigned-ссылка |
| SageAttention | Отключён (`SAGE_ATTENTION_MODE=disabled`) | Тоже отключён — в шаблонном образе sageattention нет, нода PathchSageAttentionKJ ставится в `disabled` |
| Защита от медленных машин | — (volume в том же ДЦ) | Фильтр скорости сети в worker group + **watchdog в [provisioning.sh](provisioning.sh)**: если модели не успевают скачаться за `DOWNLOAD_BUDGET_SEC` (600с), воркер убивается сразу по прогнозу ETA |

Ещё одна страховка: benchmark-workflow подменён на наши WAN-модели (пишется
provisioning-скриптом). Если модели/ноды не встали — воркер не проходит
benchmark, помечается errored и заменяется автоскейлером. «Тихо сломанных»
воркеров не бывает.

## Шаг 0. Залить эту папку на GitHub

**Публичный** репозиторий (секретов в файлах нет — все ключи через env):

```bash
cd vast-wan22-serverless
git init && git add . && git commit -m "wan22 vast serverless"
# создай пустой публичный репозиторий на github.com, затем:
git remote add origin https://github.com/<USER>/<REPO>.git
git push -u origin main
```

URL provisioning-скрипта (понадобится в шаге 2):
`https://raw.githubusercontent.com/<USER>/<REPO>/main/provisioning.sh`

## Шаг 1. Скопировать модели с RunPod volume в R2 (однократно)

1. RunPod → **Pods → Deploy**: самый дешёвый GPU/CPU pod в **US-NE-1**
   (ДЦ volume), подключи network volume `shaggy_orange_crab`.
2. В веб-терминале пода:
   ```bash
   wget https://raw.githubusercontent.com/<USER>/<REPO>/main/copy_models_to_r2.sh
   export R2_ENDPOINT="https://<account_id>.r2.cloudflarestorage.com"  # = BUCKET_ENDPOINT_URL из endpoint'а
   export R2_KEY_ID="..."      # = BUCKET_ACCESS_KEY_ID
   export R2_SECRET="..."      # = BUCKET_SECRET_ACCESS_KEY
   export R2_BUCKET="runpod"   # = BUCKET_NAME
   export R2_PREFIX="wan22"
   bash copy_models_to_r2.sh
   ```
   ~40 ГБ, обычно 10–20 минут. В конце `rclone check` должен показать 0 differences.
3. Удали под. Модели теперь в `r2://runpod/wan22/models/...`
   (egress у R2 бесплатный — воркеры Vast будут качать оттуда быстро и даром).

## Шаг 2. Шаблон на Vast.ai

Console → **Templates** → найти **ComfyUI (Serverless)** → Edit/копия.
В **Environment Variables** добавить:

| Ключ | Значение |
|---|---|
| `PROVISIONING_SCRIPT` | `https://raw.githubusercontent.com/<USER>/<REPO>/main/provisioning.sh` |
| `BENCHMARK_JSON_PATH` | `/workspace/wan22_benchmark.json` |
| `S3_ACCESS_KEY_ID` | ключ R2 (= BUCKET_ACCESS_KEY_ID на RunPod) |
| `S3_SECRET_ACCESS_KEY` | секрет R2 (= BUCKET_SECRET_ACCESS_KEY) |
| `S3_ENDPOINT_URL` | `https://<account_id>.r2.cloudflarestorage.com` |
| `S3_BUCKET_NAME` | `runpod` |
| `S3_REGION` | `auto` |
| `MODELS_S3_PREFIX` | `wan22/models` |
| `DOWNLOAD_BUDGET_SEC` | `600` |

Disk Space: **100 GB**.

## Шаг 3. Endpoint + Worker Group

Console → **Serverless** → New Endpoint (имя `wan22`), затем Worker Group:

- **Template**: шаблон из шага 2.
- **GPU**: отметить `RTX PRO 6000` / `RTX 6000 Ada` / `H100 SXM` / `H100 NVL` / `H200` / `B200`
  (⚠️ RTX 6000 Ada — 48 ГБ VRAM, впритык для двух Q8 GGUF; если будут OOM — убрать).
- **Фильтры машины**: Internet Download ≥ **800 Mbps** (первая линия защиты от
  медленных машин), Disk ≥ 100 GB, Verified.
- **Scaling**: Cold Workers 1–2, Max Workers 2–3, Cold Multiplier 2,
  Target Utilization 0.9 — аналог Max 2 / Active 0 на RunPod.

Первый воркер: ~5–15 мин (образ + ноды + модели + WAN-benchmark). Дальше
воркер хранит модели на своём диске — холодный старт это только загрузка в VRAM.

## Шаг 4. Запросы

```bash
pip install vastai requests pillow
export VAST_API_KEY=...          # ключ из Account Settings
export VAST_ENDPOINT_NAME=wan22
python vast_request.py https://example.com/photo.jpg 864 1040
```

Ответ: `{"video_url": "https://... (presigned R2, 7 дней)", "width": ..., "seed": ...}`

Все параметры RunPod-версии работают как флаги:

```bash
python vast_request.py URL 864 1040 --frames 81 --fps 45 --seed 123 \
  --steps 8 --switch-step 4 --crf 17 \
  --prompt "..." --negative-prompt "..." \
  --loras-high '[{"name":"WAN 2.2/02 NSFW-22-H-e8.safetensors","strength":1.0}]'
```

| Параметр | По умолчанию | Что делает |
|---|---|---|
| `image_url` (позиц.) | — | прямая ссылка на фото; воркер скачает сам |
| `width height` (позиц.) | 864 1040 | бокс: фото вписывается с сохранением пропорций, кратно 16 (расчёт в клиенте) |
| `--frames` | 81 | длина в кадрах (приводится к 4n+1), до RIFE |
| `--fps` | 45 | fps итогового mp4 (кадров после RIFE ~2×) |
| `--seed` | случайный | сид (печатается в ответе) |
| `--steps` / `--switch-step` | 8 / 4 | шаги и точка переключения high→low |
| `--crf` | 17 | качество h264 |
| `--loras-high/low` | NSFW-22 H/L | JSON-список LoRA, пути относительно `loras/` |

## Если что-то не работает

- **Воркеры создаются и умирают** — смотри логи инстанса (Instances → Logs):
  - `FATAL: network too slow` / `download exceeded budget` — watchdog отбраковал
    медленную машину, это штатно; автоскейлер возьмёт другую. Если такое
    подряд у всех — подними фильтр Internet Download в worker group.
  - `missing model file after download` — проверь `MODELS_S3_PREFIX` и что шаг 1
    завершился с 0 differences.
  - Ошибка benchmark — модели скачались, но воркфлоу не прошёл: смотри лог
    ComfyUI там же (обычно — не встала custom-нода).
- **`value not in list: unet_name`** — имя файла в R2 не совпадает с
  `workflow_api.json` байт-в-байт (пробелы в именах LoRA!).
- **В ответе нет video_url** — проверь S3_* env в шаблоне; клиент тогда
  скачивает mp4 напрямую с воркера через `/view` (fallback уже встроен).
- **OOM на 48 ГБ картах** — убери `RTX 6000 Ada` из worker group.
