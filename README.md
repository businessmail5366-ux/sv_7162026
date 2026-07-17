# WAN 2.2 I2V (GGUF) — Serverless на Vast.ai

Порт RunPod-воркера (`runpod-wan22-b200`) на Vast.ai Serverless. Тот же воркфлоу
(WAN 2.2 I2V GGUF Q8 high/low + LoRA + NAG + RIFE x2 + ColorMatch + Sharpen),
тот же API-смысл: `image_url` + `width`/`height` → mp4.

Дополнительно на том же endpoint'е доступен второй воркфлоу —
**Krea2 realism t2i** (текст → фото): [workflow_krea2_api.json](workflow_krea2_api.json)
+ клиент [krea2_request.py](krea2_request.py). См. раздел «Второй воркфлоу: Krea2» ниже.

## Чем отличается от RunPod

| | RunPod | Vast.ai |
|---|---|---|
| Хранение моделей | Network volume, монтируется в каждый воркер | **Network volume нет.** Модели скачиваются на локальный NVMe воркера один раз при его создании (provisioning). Диск остаётся у остановленного воркера — холодный старт быстрый |
| Код воркера | Свой Docker-образ + handler.py | Готовый шаблон **ComfyUI (Serverless)** + pyworker `comfyui-json`. Свой образ не нужен |
| Логика handler.py | На сервере | В клиенте ([vast_request.py](vast_request.py)) — клиент собирает весь workflow JSON и шлёт на `/generate/sync` |
| Выдача видео | R2 (BUCKET_* env) или base64 | Тот же R2 (S3_* env), в ответе presigned-ссылка |
| SageAttention | Отключён (`SAGE_ATTENTION_MODE=disabled`) | Тоже отключён — в шаблонном образе sageattention нет, нода PathchSageAttentionKJ ставится в `disabled` |
| Защита от медленных машин | — (volume в том же ДЦ) | Фильтр скорости сети в worker group + **watchdog в [provisioning.sh](provisioning.sh)**: если модели не успевают скачаться за `DOWNLOAD_BUDGET_SEC` (600с), воркер убивается сразу по прогнозу ETA |

Benchmark-workflow подменён на тривиальный (EmptyImage → SaveImage, без
моделей): pyworker'у файл обязателен, но проходит он за ~1с — воркер
принимает трафик сразу после старта, без прогона полной WAN-генерации.
Пригодность воркера проверяется по файлам моделей в provisioning'е; при
любом фатале скрипт подменяет benchmark на заведомо падающий — воркер
мгновенно помечается errored и заменяется автоскейлером. «Тихо сломанных»
воркеров по-прежнему не бывает, а рестарт инстанса ничего не перепроверяет
(флаг `.provisioning_done` — мгновенный выход из скрипта).

## Шаг 0. Залить эту папку на GitHub

**Публичный** репозиторий (секретов в файлах нет — все ключи через env):

Репозиторий: https://github.com/businessmail5366-ux/sv_7162026

URL provisioning-скрипта (понадобится в шаге 2):
`https://raw.githubusercontent.com/businessmail5366-ux/sv_7162026/main/provisioning.sh`

## Шаг 1. Скопировать модели с RunPod volume в R2 (однократно)

1. RunPod → **Pods → Deploy**: самый дешёвый GPU/CPU pod в **US-NE-1**
   (ДЦ volume), подключи network volume `shaggy_orange_crab`.
2. В веб-терминале пода:
   ```bash
   wget https://raw.githubusercontent.com/businessmail5366-ux/sv_7162026/main/copy_models_to_r2.sh
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
| `PROVISIONING_SCRIPT` | `https://raw.githubusercontent.com/businessmail5366-ux/sv_7162026/main/provisioning.sh` |
| `BENCHMARK_JSON_PATH` | `/workspace/wan22_benchmark.json` |
| `S3_ACCESS_KEY_ID` | ключ R2 (= BUCKET_ACCESS_KEY_ID на RunPod) |
| `S3_SECRET_ACCESS_KEY` | секрет R2 (= BUCKET_SECRET_ACCESS_KEY) |
| `S3_ENDPOINT_URL` | `https://<account_id>.r2.cloudflarestorage.com` |
| `S3_BUCKET_NAME` | `runpod` |
| `S3_REGION` | `auto` |
| `MODELS_S3_PREFIX` | `wan22/models` |
| `DOWNLOAD_BUDGET_SEC` | `600` |
| `UPDATE_COMFYUI` | `true` — только если нужен Krea2 (см. раздел ниже); для чистого WAN не задавать |

Disk Space: **100 GB** (с моделями Krea2 — **140 GB**, и `DOWNLOAD_BUDGET_SEC` → `1200`).

## Шаг 3. Endpoint + Worker Group

Console → **Serverless** → New Endpoint (имя `wan22`), затем Worker Group:

- **Template**: шаблон из шага 2.
- **GPU**: отметить `RTX PRO 6000` / `RTX 6000 Ada` / `H100 SXM` / `H100 NVL` / `H200` / `B200`
  (⚠️ RTX 6000 Ada — 48 ГБ VRAM, впритык для двух Q8 GGUF; если будут OOM — убрать).
- **Фильтры машины**: Internet Download ≥ **800 Mbps** (первая линия защиты от
  медленных машин), Disk ≥ 100 GB, Verified.
- **Scaling**: Cold Workers 1–2, Max Workers 2–3, Cold Multiplier 2,
  Target Utilization 0.9 — аналог Max 2 / Active 0 на RunPod.

Первый воркер: ~5–15 мин (образ + ноды + модели; benchmark тривиальный, ~1с).
Дальше воркер хранит модели на своём диске — при рестарте provisioning выходит
сразу по флагу, benchmark ничего не генерирует, и воркер готов к трафику
почти мгновенно; модели грузятся в VRAM уже на первом реальном запросе.

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

## Второй воркфлоу: Krea2 realism t2i (текст → фото)

Основан на GUI-воркфлоу `ComfyUI_temp_ytzkx_00283_.json` (Krea 2 Realism,
SFW+NSFW): Krea2 Turbo + Qwen3-VL энкодер + 2 realism-LoRA, 8 шагов,
cfg 1.0, denoise 0.7. API-версия — [workflow_krea2_api.json](workflow_krea2_api.json):

- Power Lora Loader (rgthree) заменён цепочкой стандартных `LoraLoader`
  (пересобирается флагом `--loras`, как `--loras-high/low` у WAN);
- `PreviewImage` заменён на `SaveImage` — иначе воркер не выгрузит png в R2;
- негатив как в оригинале: `ConditioningZeroOut` от позитива.

Работает на том же endpoint'е и тех же воркерах, что и WAN 2.2.

### Шаг 1. Залить модели Krea2 в R2

Скрипт [upload_krea2_models_to_r2.sh](upload_krea2_models_to_r2.sh) сам
перекачивает модели с HuggingFace напрямую в R2 (стримингом через
`rclone copyurl`, локальный диск не нужен). Запускать где угодно с хорошим
интернетом — локально или на дешёвом поде:

```bash
export R2_ENDPOINT="https://<account_id>.r2.cloudflarestorage.com"
export R2_KEY_ID="..."  R2_SECRET="..."  R2_BUCKET="runpod"  R2_PREFIX="wan22"
bash upload_krea2_models_to_r2.sh
```

Повторный запуск безопасен — уже залитые файлы пропускаются.
Раскладка в бакете (скрипт делает её сам):

| Файл (с HuggingFace) | Куда в `wan22/models/` | |
|---|---|---|
| `krea2_turbo_bf16.safetensors` | `diffusion_models/` | обязателен |
| `qwen3vl_4b_bf16.safetensors` | `text_encoders/` | обязателен |
| `qwen_image_vae.safetensors` | `vae/` | обязателен |
| `realism_engine_krea2_v3.1.safetensors` | `loras/Krea2/` | обязателен (в воркфлоу) |
| `RealisticSnapshotKrea2.safetensors` | `loras/Krea2/` | обязателен (в воркфлоу) |
| `realism_engine_krea2_v2.safetensors` | `loras/Krea2/` | доп. LoRA для `--loras` |
| `Krea2-realism-V2.safetensors` | `loras/Krea2/` | доп. LoRA для `--loras` |
| `4x_NMKD-Superscale-SP_178000_G.pth` | `upscale_models/` | апскейлер (на будущее) |

Пока моделей в R2 нет — provisioning только предупреждает
(`krea2 t2i disabled`), WAN-воркеры работают как раньше. Как только модели
появились в бакете, provisioning начинает их скачивать и **требовать**
(нет файла — воркер бракуется, как с WAN-моделями).

### Шаг 2. Обновить шаблон и пересоздать воркеров

1. В env шаблона добавь `UPDATE_COMFYUI=true` — `CLIPLoader` с типом `krea2`
   есть только в свежем comfy-core, provisioning обновит ComfyUI до master.
2. Подними Disk Space до ~140 GB и `DOWNLOAD_BUDGET_SEC` до `1200`:
   моделей Krea2 ~38 ГБ (одна turbo-модель — 24.5 ГБ), суммарное скачивание
   на воркер почти удваивается (~78 ГБ) — со старым бюджетом 600с watchdog
   начнёт браковать нормальные машины.
3. Пересоздай воркеров (Instances → destroy): provisioning выполняется один
   раз при создании воркера, старые воркеры новые модели сами не скачают.

Ноды: provisioning дополнительно ставит `rgthree-comfy` — для нашего
API-воркфлоу он не нужен, но с ним работают и «сырые» GUI-экспорты
с `Power Lora Loader (rgthree)`.

### Шаг 3. Запросы

```bash
python krea2_request.py "a candid smartphone photo of a woman in a park" 896 1152
```

Ответ: `{"image_url": "https://... (presigned R2)", "image_urls": [...], "seed": ...}`

```bash
python krea2_request.py "prompt..." 896 1152 --seed 123 --steps 8 \
  --cfg 1.0 --denoise 0.7 --batch 1 \
  --loras '[{"name":"Krea2/realism_engine_krea2_v3.1.safetensors","strength":1.5}]'
```

| Параметр | По умолчанию | Что делает |
|---|---|---|
| `prompt` (позиц.) | — | текстовый промпт (негатив не нужен — zero-out) |
| `width height` (позиц.) | 896 1152 | размер, приводится к кратному 16 |
| `--seed` | случайный | сид (печатается в ответе) |
| `--steps` / `--cfg` | 8 / 1.0 | как в оригинальном воркфлоу (turbo) |
| `--denoise` | 0.7 | значение автора воркфлоу |
| `--batch` | 1 | картинок за один запрос |
| `--sampler` / `--scheduler` | dpmpp_2m_sde_gpu / sgm_uniform | сэмплер |
| `--loras` | realism_engine 1.0 + RealisticSnapshot 0.8 | JSON-список, пути относительно `loras/`; автор рекомендует strength 1.0–2.0 |

## Если что-то не работает

- **Воркеры создаются и умирают** — смотри логи инстанса (Instances → Logs):
  - `FATAL: network too slow` / `download exceeded budget` — watchdog отбраковал
    медленную машину, это штатно; автоскейлер возьмёт другую. Если такое
    подряд у всех — подними фильтр Internet Download в worker group.
  - `missing model file after download` — проверь `MODELS_S3_PREFIX` и что шаг 1
    завершился с 0 differences.
  - Benchmark падает с `PROVISIONING_FAILED.gguf` — это не ошибка benchmark'а,
    а маркер: provisioning упал (причина — строкой `FATAL:` выше в логе),
    и скрипт нарочно подменил benchmark, чтобы воркер был заменён.
- **`value not in list: unet_name`** — имя файла в R2 не совпадает с
  `workflow_api.json` байт-в-байт (пробелы в именах LoRA!).
- **Krea2: `value not in list: type: 'krea2'`** — ComfyUI на воркере старый,
  не знает тип `krea2` в CLIPLoader: задай `UPDATE_COMFYUI=true` в env
  шаблона и пересоздай воркеров.
- **Krea2: `value not in list: unet_name: 'krea2_turbo_bf16.safetensors'`** —
  воркер создан до заливки моделей Krea2 в R2 — пересоздай воркеров.
- **В ответе нет video_url** — проверь S3_* env в шаблоне; клиент тогда
  скачивает mp4 напрямую с воркера через `/view` (fallback уже встроен).
- **OOM на 48 ГБ картах** — убери `RTX 6000 Ada` из worker group.
