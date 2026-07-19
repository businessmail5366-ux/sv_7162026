#!/usr/bin/env bash
# =============================================================================
# WAN 2.2 I2V (GGUF) — provisioning для шаблона "ComfyUI (Serverless)" на Vast.ai
#
# Что делает:
#   1. Пишет ТРИВИАЛЬНЫЙ benchmark-workflow (EmptyImage -> SaveImage, без
#      моделей): pyworker требует наличие benchmark'а, но проходит он за ~1с —
#      воркер начинает принимать трафик сразу после старта, без прогона
#      полной WAN-генерации. Проверка моделей — по файлам (шаг 4); при
#      любом фатале пишется заведомо падающий benchmark, чтобы воркер
#      мгновенно пометился errored и был заменён автоскейлером.
#   2. Ставит custom-ноды: ComfyUI-GGUF, KJNodes, VideoHelperSuite,
#      Frame-Interpolation (+ веса RIFE rife47.pth), rgthree-comfy (Krea2).
#   3. Качает модели (~40 ГБ) из R2/S3 бакета через rclone с watchdog'ом:
#      если по прогрессу видно, что скачивание не уложится в бюджет
#      (DOWNLOAD_BUDGET_SEC, по умолч. 600с) — падает СРАЗУ, не дожидаясь
#      таймаута. Это защита от машин с медленным интернетом.
#   4. Krea2 t2i (workflow_krea2_api.json): модели опциональны — если они
#      уже залиты в R2 (upload_krea2_models_to_r2.sh), проверяет их наличие
#      после скачивания; если в R2 их ещё нет — только предупреждает,
#      WAN 2.2 работает как раньше.
#
# Скрипт идемпотентен: при повторном запуске (рестарт инстанса) выходит
# сразу по флагу .provisioning_done — никаких pip/rclone/git на старте.
#
# Требуемые env (задаются в template на Vast):
#   S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY / S3_ENDPOINT_URL / S3_BUCKET_NAME
#       — те же ключи R2, что использует comfyui-json worker для выгрузки
#         результатов; отсюда же качаем модели.
#   MODELS_S3_PREFIX      — путь к моделям в бакете (по умолч. wan22/models)
#   DOWNLOAD_BUDGET_SEC   — жёсткий бюджет на скачивание моделей, сек (600)
#   EARLY_CHECK_SEC       — с какой секунды начинать прогноз ETA (90)
#   BENCHMARK_JSON_PATH   — куда положить benchmark (должен совпадать с env
#                           шаблона; по умолч. /workspace/wan22_benchmark.json)
#   UPDATE_COMFYUI        — true = обновить ComfyUI до свежего master.
#                           Нужно для Krea2: CLIPLoader type "krea2" есть
#                           только в новых версиях comfy-core.
#   SAGE_INSTALL          — true (по умолч.) = поставить SageAttention на
#                           поддерживаемых GPU (compute capability >= 8.0),
#                           −20–40% времени семплинга WAN. Шаг выполняется
#                           И при рестарте уже развёрнутого воркера.
#   SAGE_REQUIRED         — true = воркер без рабочего sage помечается errored
#                           и заменяется (по умолч. false: просто предупреждение).
#   SAGE_PKG              — pip-спека пакета (по умолч. sageattention==1.0.6).
# =============================================================================
set -uo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"

log()  { echo "[provision] $*"; }

# Кладём benchmark в BENCHMARK_JSON_PATH + в стандартное место pyworker'а
BENCHMARK_JSON_PATH="${BENCHMARK_JSON_PATH:-${WORKSPACE}/wan22_benchmark.json}"
write_benchmark() {
    printf '%s' "$1" > "${BENCHMARK_JSON_PATH}"
    for misc in $(find "${WORKSPACE}" /opt -maxdepth 6 -type d -path "*workers/comfyui-json/misc" 2>/dev/null); do
        cp -f "${BENCHMARK_JSON_PATH}" "${misc}/benchmark.json" && \
            log "benchmark also copied to ${misc}/benchmark.json"
    done
}

fail() {
    echo "[provision] FATAL: $*" >&2
    touch "${WORKSPACE}/.provisioning_failed"
    # Пишем заведомо падающий benchmark (несуществующая модель): валидация
    # ComfyUI отбивает его мгновенно, без загрузки чего-либо — воркер сразу
    # помечается errored и заменяется автоскейлером.
    write_benchmark '{ "broken": { "class_type": "UnetLoaderGGUF", "inputs": { "unet_name": "PROVISIONING_FAILED.gguf" } } }'
    exit 1
}

# --- pip/python из venv образа -----------------------------------------------
PIP="pip"
for cand in /venv/main/bin/pip "${WORKSPACE}/venv/bin/pip" /opt/venv/bin/pip; do
    if [ -x "$cand" ]; then PIP="$cand"; break; fi
done
PYTHON="python3"
for cand in /venv/main/bin/python "${WORKSPACE}/venv/bin/python" /opt/venv/bin/python; do
    if [ -x "$cand" ]; then PYTHON="$cand"; break; fi
done
log "using pip: ${PIP}, python: ${PYTHON}"

# =============================================================================
# 0. SageAttention — ДО быстрого выхода по .provisioning_done, чтобы шаг
#    отработал и на уже развёрнутых воркерах при их рестарте.
#    Функциональный тест (реальный вызов sageattn на GPU) — единственный
#    критерий успеха; просто «pip поставился» не считается.
# =============================================================================
SAGE_INSTALL="${SAGE_INSTALL:-true}"
SAGE_REQUIRED="${SAGE_REQUIRED:-false}"
SAGE_PKG="${SAGE_PKG:-sageattention==1.0.6}"

sage_test() {
    "$PYTHON" - <<'PY'
import torch
from sageattention import sageattn
q = torch.randn(1, 8, 128, 64, dtype=torch.float16, device="cuda")
o = sageattn(q, q, q)
assert o is not None and o.shape == q.shape
print("sage functional test OK")
PY
}

if [ "${SAGE_INSTALL}" = "true" ]; then
    CC_MAJOR=$("$PYTHON" -c "import torch; print(torch.cuda.get_device_capability(0)[0])" 2>/dev/null || echo 0)
    if [ "${CC_MAJOR:-0}" -ge 8 ]; then
        if sage_test >/dev/null 2>&1; then
            log "sageattention already functional (cc ${CC_MAJOR}.x)"
        else
            log "installing sageattention (${SAGE_PKG}, cc ${CC_MAJOR}.x)"
            "$PIP" install --no-cache-dir "${SAGE_PKG}" \
                || log "WARNING: pip install ${SAGE_PKG} failed"
            if sage_test; then
                log "OK: sageattention installed and functional"
            elif [ "${SAGE_REQUIRED}" = "true" ]; then
                fail "SAGE_REQUIRED=true, but sageattention is not functional on this GPU"
            else
                log "WARNING: sageattention not functional on this GPU — WAN будет работать без него (держи SAGE_ATTENTION_MODE=disabled на клиенте)"
            fi
        fi
    else
        log "GPU compute capability ${CC_MAJOR}.x < 8 — sageattention не поддерживается, пропускаю"
    fi
fi

# Быстрый выход при рестарте инстанса: всё уже установлено и скачано,
# ничего не перепроверяем — генерация доступна сразу.
if [ -f "${WORKSPACE}/.provisioning_done" ]; then
    echo "[provision] .provisioning_done found — skipping (fast start)"
    exit 0
fi
COMFYUI_DIR="${COMFYUI_DIR:-${WORKSPACE}/ComfyUI}"
MODELS_DIR="${COMFYUI_DIR}/models"
NODES_DIR="${COMFYUI_DIR}/custom_nodes"

MODELS_S3_PREFIX="${MODELS_S3_PREFIX:-wan22/models}"
DOWNLOAD_BUDGET_SEC="${DOWNLOAD_BUDGET_SEC:-600}"
EARLY_CHECK_SEC="${EARLY_CHECK_SEC:-90}"
EARLY_GRACE_MULT="${EARLY_GRACE_MULT:-125}"   # проценты: 125 = бюджет*1.25

mkdir -p "${MODELS_DIR}/diffusion_models" \
         "${MODELS_DIR}/vae" \
         "${MODELS_DIR}/text_encoders" \
         "${MODELS_DIR}/loras/WAN 2.2" \
         "${MODELS_DIR}/loras/Krea2" \
         "${NODES_DIR}"

# =============================================================================
# 1. Тривиальный benchmark-workflow — без моделей, проходит за ~1с.
#    pyworker'у файл нужен обязательно, но гонять полную WAN-генерацию при
#    каждом старте воркера — минуты задержки до первого трафика. Пригодность
#    воркера проверяется по файлам моделей (шаг 4); при фатале fail()
#    подменяет benchmark на заведомо падающий.
# =============================================================================
log "writing trivial benchmark workflow -> ${BENCHMARK_JSON_PATH}"
write_benchmark '{
  "img": { "class_type": "EmptyImage", "inputs": { "width": 64, "height": 64, "batch_size": 1, "color": 0 } },
  "save": { "class_type": "SaveImage", "inputs": { "images": ["img", 0], "filename_prefix": "benchmark" } }
}'

# =============================================================================
# 1.5. (опционально) Обновление ComfyUI до свежего master.
#      Нужно для Krea2 t2i: CLIPLoader type "krea2" (Qwen3-VL энкодер)
#      появился в новых версиях comfy-core, в шаблонном образе Vast его
#      может не быть. Включается UPDATE_COMFYUI=true в env шаблона.
# =============================================================================
if [ "${UPDATE_COMFYUI:-false}" = "true" ]; then
    if [ -d "${COMFYUI_DIR}/.git" ]; then
        log "updating ComfyUI to latest master (UPDATE_COMFYUI=true)"
        git -C "${COMFYUI_DIR}" fetch --depth 1 origin master \
            && git -C "${COMFYUI_DIR}" reset --hard FETCH_HEAD \
            || fail "ComfyUI git update failed"
        "$PIP" install --no-cache-dir -r "${COMFYUI_DIR}/requirements.txt" \
            || fail "pip install for updated ComfyUI failed"
    else
        log "WARNING: ${COMFYUI_DIR} is not a git repo — skipping ComfyUI update"
    fi
fi

# =============================================================================
# 2. Custom-ноды
# =============================================================================
clone_node() {
    local repo="$1" name reqs
    name="$(basename "$repo" .git)"
    if [ -d "${NODES_DIR}/${name}" ]; then
        log "node ${name} already present"
    else
        log "cloning ${name}"
        git clone --depth 1 --recursive "$repo" "${NODES_DIR}/${name}" \
            || fail "git clone failed: ${repo}"
    fi
    for reqs in "requirements-no-cupy.txt" "requirements.txt"; do
        if [ -f "${NODES_DIR}/${name}/${reqs}" ]; then
            log "pip install -r ${name}/${reqs}"
            "$PIP" install --no-cache-dir -r "${NODES_DIR}/${name}/${reqs}" \
                || fail "pip install failed for ${name}"
            break
        fi
    done
}

clone_node "https://github.com/city96/ComfyUI-GGUF.git"
clone_node "https://github.com/kijai/ComfyUI-KJNodes.git"
clone_node "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
clone_node "https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git"
# Krea2 t2i: наш workflow_krea2_api.json использует стандартные LoraLoader,
# но rgthree нужен, чтобы работали и «сырые» GUI-экспорты воркфлоу
# с Power Lora Loader (rgthree) — режим «Свой воркфлоу» в webui.
clone_node "https://github.com/rgthree/rgthree-comfy.git"

# Веса RIFE — кладём заранее, чтобы не качались при первом запросе
RIFE_DIR="${NODES_DIR}/ComfyUI-Frame-Interpolation/ckpts/rife"
mkdir -p "${RIFE_DIR}"
if [ ! -s "${RIFE_DIR}/rife47.pth" ]; then
    log "downloading rife47.pth"
    wget -q -O "${RIFE_DIR}/rife47.pth" \
        "https://github.com/Fannovel16/ComfyUI-Frame-Interpolation/releases/download/models/rife47.pth" || \
    wget -q -O "${RIFE_DIR}/rife47.pth" \
        "https://huggingface.co/marduk191/rife/resolve/main/rife47.pth" || \
    fail "cannot download rife47.pth"
fi

# =============================================================================
# 3. Модели из R2/S3 с watchdog'ом по скорости
# =============================================================================
# Через fail(), а не ${VAR:?}: иначе скрипт умрёт мимо fail() и воркер
# с пройденным тривиальным benchmark'ом, но без моделей, возьмёт трафик.
for v in S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY S3_ENDPOINT_URL S3_BUCKET_NAME; do
    [ -n "${!v:-}" ] || fail "${v} is required (R2/S3 env)"
done

if ! command -v rclone >/dev/null 2>&1; then
    log "installing rclone"
    if ! curl -fsSL https://rclone.org/install.sh | bash >/dev/null 2>&1; then
        apt-get update -qq || true
        apt-get install -y -qq rclone || true
    fi
    command -v rclone >/dev/null 2>&1 || fail "cannot install rclone"
fi

export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID}"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY}"
export RCLONE_CONFIG_R2_ENDPOINT="${S3_ENDPOINT_URL}"
REMOTE="r2:${S3_BUCKET_NAME}/${MODELS_S3_PREFIX}"

log "checking remote ${REMOTE}"
EXPECTED_BYTES=$(rclone size --json "${REMOTE}" 2>/dev/null | sed -n 's/.*"bytes":\([0-9]*\).*/\1/p')
[ -n "${EXPECTED_BYTES}" ] || fail "cannot read ${REMOTE} — check S3_* env and MODELS_S3_PREFIX"
[ "${EXPECTED_BYTES}" -gt 1000000000 ] || fail "remote ${REMOTE} contains only ${EXPECTED_BYTES} bytes — models missing?"
log "models to download: $((EXPECTED_BYTES / 1024 / 1024)) MB, budget ${DOWNLOAD_BUDGET_SEC}s"

BASE_BYTES=$(du -sb "${MODELS_DIR}" 2>/dev/null | cut -f1)
BASE_BYTES=${BASE_BYTES:-0}
START_TS=$(date +%s)

rclone copy "${REMOTE}" "${MODELS_DIR}" \
    --transfers 4 --multi-thread-streams 8 --multi-thread-cutoff 64M \
    --s3-chunk-size 64M --retries 2 --low-level-retries 5 \
    --stats-one-line --stats 30s &
RCLONE_PID=$!

# Watchdog: рано прогнозируем итоговое время; медленная сеть -> fail fast
while kill -0 "${RCLONE_PID}" 2>/dev/null; do
    sleep 10
    NOW=$(date +%s); ELAPSED=$((NOW - START_TS))
    CUR=$(du -sb "${MODELS_DIR}" 2>/dev/null | cut -f1); CUR=${CUR:-0}
    DONE=$((CUR - BASE_BYTES)); [ "${DONE}" -lt 0 ] && DONE=0

    if [ "${ELAPSED}" -ge "${DOWNLOAD_BUDGET_SEC}" ]; then
        kill "${RCLONE_PID}" 2>/dev/null
        fail "download exceeded budget: ${ELAPSED}s > ${DOWNLOAD_BUDGET_SEC}s ($((DONE/1024/1024))/$((EXPECTED_BYTES/1024/1024)) MB)"
    fi

    if [ "${ELAPSED}" -ge "${EARLY_CHECK_SEC}" ] && [ "${DONE}" -gt 0 ]; then
        SPEED=$((DONE / ELAPSED))                                  # bytes/s
        PROJECTED=$((ELAPSED + (EXPECTED_BYTES - DONE) / (SPEED + 1)))
        LIMIT=$((DOWNLOAD_BUDGET_SEC * EARLY_GRACE_MULT / 100))
        if [ "${PROJECTED}" -gt "${LIMIT}" ]; then
            kill "${RCLONE_PID}" 2>/dev/null
            fail "network too slow: $((SPEED/1024/1024)) MB/s, projected ${PROJECTED}s > limit ${LIMIT}s — aborting early"
        fi
        log "progress: $((DONE/1024/1024))/$((EXPECTED_BYTES/1024/1024)) MB, $((SPEED/1024/1024)) MB/s, ETA ${PROJECTED}s"
    fi
done

wait "${RCLONE_PID}"
RC=$?
[ "${RC}" -eq 0 ] || fail "rclone copy exited with code ${RC}"

# =============================================================================
# 4. Проверка: все файлы на месте (имена должны совпадать байт-в-байт)
# =============================================================================
REQUIRED_FILES=(
    "diffusion_models/wan22EnhancedNSFWCameraPrompt_nsfwFASTMOVEV2Q8H.gguf"
    "diffusion_models/wan22EnhancedNSFWCameraPrompt_nsfwFASTMOVEV2Q8L.gguf"
    "vae/wan_2.1_vae.safetensors"
    "text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
    "loras/WAN 2.2/02 NSFW-22-H-e8.safetensors"
    "loras/WAN 2.2/02 NSFW-22-L-e8.safetensors"
    "loras/WAN 2.2/01 SmoothXXXAnimation_High.safetensors"
    "loras/WAN 2.2/01 SmoothXXXAnimation_Low.safetensors"
)
for f in "${REQUIRED_FILES[@]}"; do
    [ -s "${MODELS_DIR}/${f}" ] || fail "missing model file after download: models/${f}"
done

# Krea2 t2i (workflow_krea2_api.json) — опциональный набор: модели могут быть
# ещё не залиты в R2. Требуем файл только если он есть в бакете; если нет —
# предупреждаем, воркер остаётся рабочим для WAN 2.2.
KREA2_FILES=(
    "diffusion_models/krea2_turbo_bf16.safetensors"
    "text_encoders/qwen3vl_4b_bf16.safetensors"
    "vae/qwen_image_vae.safetensors"
    "loras/Krea2/realism_engine_krea2_v3.1.safetensors"
    "loras/Krea2/RealisticSnapshotKrea2.safetensors"
)
KREA2_MISSING=0
for f in "${KREA2_FILES[@]}"; do
    if [ -n "$(rclone lsf "${REMOTE}/${f}" 2>/dev/null)" ]; then
        [ -s "${MODELS_DIR}/${f}" ] || fail "krea2 model present in R2 but missing locally: models/${f}"
    else
        KREA2_MISSING=$((KREA2_MISSING + 1))
    fi
done
if [ "${KREA2_MISSING}" -eq 0 ]; then
    log "OK: krea2 models in place — krea2 t2i workflow available"
else
    log "NOTE: ${KREA2_MISSING}/${#KREA2_FILES[@]} krea2 models not in R2 yet — krea2 t2i disabled (upload via upload_krea2_models_to_r2.sh)"
fi

TOTAL_TIME=$(( $(date +%s) - START_TS ))
log "OK: all models in place, download took ${TOTAL_TIME}s"
touch "${WORKSPACE}/.provisioning_done"
