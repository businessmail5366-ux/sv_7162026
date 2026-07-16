#!/usr/bin/env bash
# =============================================================================
# WAN 2.2 I2V (GGUF) — provisioning для шаблона "ComfyUI (Serverless)" на Vast.ai
#
# Что делает:
#   1. Пишет кастомный benchmark-workflow (на НАШИХ моделях) — если модели не
#      скачались, воркер не пройдёт benchmark, будет помечен errored и заменён.
#   2. Ставит custom-ноды: ComfyUI-GGUF, KJNodes, VideoHelperSuite,
#      Frame-Interpolation (+ веса RIFE rife47.pth).
#   3. Качает модели (~40 ГБ) из R2/S3 бакета через rclone с watchdog'ом:
#      если по прогрессу видно, что скачивание не уложится в бюджет
#      (DOWNLOAD_BUDGET_SEC, по умолч. 600с) — падает СРАЗУ, не дожидаясь
#      таймаута. Это защита от машин с медленным интернетом.
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
# =============================================================================
set -uo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
COMFYUI_DIR="${COMFYUI_DIR:-${WORKSPACE}/ComfyUI}"
MODELS_DIR="${COMFYUI_DIR}/models"
NODES_DIR="${COMFYUI_DIR}/custom_nodes"

MODELS_S3_PREFIX="${MODELS_S3_PREFIX:-wan22/models}"
DOWNLOAD_BUDGET_SEC="${DOWNLOAD_BUDGET_SEC:-600}"
EARLY_CHECK_SEC="${EARLY_CHECK_SEC:-90}"
EARLY_GRACE_MULT="${EARLY_GRACE_MULT:-125}"   # проценты: 125 = бюджет*1.25
BENCHMARK_JSON_PATH="${BENCHMARK_JSON_PATH:-${WORKSPACE}/wan22_benchmark.json}"

log()  { echo "[provision] $*"; }

fail() {
    echo "[provision] FATAL: $*" >&2
    touch "${WORKSPACE}/.provisioning_failed"
    # Подчищаем недокачанные модели, чтобы benchmark гарантированно упал
    # и воркер был заменён автоскейлером (частичный .gguf всё равно не загрузится).
    rm -rf "${MODELS_DIR}/diffusion_models" \
           "${MODELS_DIR}/text_encoders" \
           "${MODELS_DIR}/loras/WAN 2.2" \
           "${MODELS_DIR}/vae/wan_2.1_vae.safetensors" 2>/dev/null || true
    exit 1
}

# --- pip/python из venv образа -----------------------------------------------
PIP="pip"
for cand in /venv/main/bin/pip "${WORKSPACE}/venv/bin/pip" /opt/venv/bin/pip; do
    if [ -x "$cand" ]; then PIP="$cand"; break; fi
done
log "using pip: ${PIP}"

mkdir -p "${MODELS_DIR}/diffusion_models" \
         "${MODELS_DIR}/vae" \
         "${MODELS_DIR}/text_encoders" \
         "${MODELS_DIR}/loras/WAN 2.2" \
         "${NODES_DIR}"

# =============================================================================
# 1. Benchmark-workflow НА НАШИХ МОДЕЛЯХ — пишем в самом начале.
#    Если что-то из моделей/нод не встанет, benchmark упадёт и воркер
#    не получит трафик (будет заменён). Никаких «тихо сломанных» воркеров.
# =============================================================================
log "writing WAN benchmark workflow -> ${BENCHMARK_JSON_PATH}"
cat > "${BENCHMARK_JSON_PATH}" <<'BENCHMARK_EOF'
{
  "empty_image": {
    "class_type": "EmptyImage",
    "inputs": { "width": 480, "height": 480, "batch_size": 1, "color": 8355711 }
  },
  "unet_high": {
    "class_type": "UnetLoaderGGUF",
    "inputs": { "unet_name": "wan22EnhancedNSFWCameraPrompt_nsfwFASTMOVEV2Q8H.gguf" }
  },
  "unet_low": {
    "class_type": "UnetLoaderGGUF",
    "inputs": { "unet_name": "wan22EnhancedNSFWCameraPrompt_nsfwFASTMOVEV2Q8L.gguf" }
  },
  "clip": {
    "class_type": "CLIPLoader",
    "inputs": { "clip_name": "umt5_xxl_fp8_e4m3fn_scaled.safetensors", "type": "wan", "device": "default" }
  },
  "vae": {
    "class_type": "VAELoader",
    "inputs": { "vae_name": "wan_2.1_vae.safetensors" }
  },
  "pos": {
    "class_type": "CLIPTextEncode",
    "inputs": { "text": "Smooth natural motion, benchmark run.", "clip": ["clip", 0] }
  },
  "neg": {
    "class_type": "CLIPTextEncode",
    "inputs": { "text": "static, blurry, low quality", "clip": ["clip", 0] }
  },
  "lora_high_1": {
    "class_type": "LoraLoaderModelOnly",
    "inputs": { "model": ["unet_high", 0], "lora_name": "WAN 2.2/02 NSFW-22-H-e8.safetensors", "strength_model": 1.0 }
  },
  "lora_low_1": {
    "class_type": "LoraLoaderModelOnly",
    "inputs": { "model": ["unet_low", 0], "lora_name": "WAN 2.2/02 NSFW-22-L-e8.safetensors", "strength_model": 1.0 }
  },
  "sage_high": {
    "class_type": "PathchSageAttentionKJ",
    "inputs": { "model": ["lora_high_1", 0], "sage_attention": "disabled" }
  },
  "sage_low": {
    "class_type": "PathchSageAttentionKJ",
    "inputs": { "model": ["lora_low_1", 0], "sage_attention": "disabled" }
  },
  "nag_high": {
    "class_type": "WanVideoNAG",
    "inputs": { "model": ["sage_high", 0], "conditioning": ["neg", 0], "nag_scale": 11.0, "nag_alpha": 0.25, "nag_tau": 2.373 }
  },
  "nag_low": {
    "class_type": "WanVideoNAG",
    "inputs": { "model": ["sage_low", 0], "conditioning": ["neg", 0], "nag_scale": 11.0, "nag_alpha": 0.25, "nag_tau": 2.373 }
  },
  "shift_high": {
    "class_type": "ModelSamplingSD3",
    "inputs": { "model": ["nag_high", 0], "shift": 5.0 }
  },
  "shift_low": {
    "class_type": "ModelSamplingSD3",
    "inputs": { "model": ["nag_low", 0], "shift": 5.0 }
  },
  "i2v": {
    "class_type": "WanImageToVideo",
    "inputs": {
      "positive": ["pos", 0], "negative": ["neg", 0], "vae": ["vae", 0],
      "start_image": ["empty_image", 0],
      "width": 480, "height": 480, "length": 17, "batch_size": 1
    }
  },
  "sampler_high": {
    "class_type": "KSamplerAdvanced",
    "inputs": {
      "model": ["shift_high", 0],
      "positive": ["i2v", 0], "negative": ["i2v", 1], "latent_image": ["i2v", 2],
      "add_noise": "enable", "noise_seed": "__RANDOM_INT__",
      "steps": 4, "cfg": 1.0, "sampler_name": "euler", "scheduler": "beta",
      "start_at_step": 0, "end_at_step": 2, "return_with_leftover_noise": "enable"
    }
  },
  "sampler_low": {
    "class_type": "KSamplerAdvanced",
    "inputs": {
      "model": ["shift_low", 0],
      "positive": ["i2v", 0], "negative": ["i2v", 1], "latent_image": ["sampler_high", 0],
      "add_noise": "disable", "noise_seed": "__RANDOM_INT__",
      "steps": 4, "cfg": 1.0, "sampler_name": "euler", "scheduler": "beta",
      "start_at_step": 2, "end_at_step": 10000, "return_with_leftover_noise": "disable"
    }
  },
  "decode": {
    "class_type": "VAEDecode",
    "inputs": { "samples": ["sampler_low", 0], "vae": ["vae", 0] }
  },
  "color_match": {
    "class_type": "ColorMatch",
    "inputs": { "image_ref": ["empty_image", 0], "image_target": ["decode", 0], "method": "mkl", "strength": 0.8 }
  },
  "trim_end": {
    "class_type": "ImageFromBatch",
    "inputs": { "image": ["color_match", 0], "batch_index": 0, "length": 16 }
  },
  "rife": {
    "class_type": "RIFE VFI",
    "inputs": {
      "frames": ["trim_end", 0], "ckpt_name": "rife47.pth",
      "clear_cache_after_n_frames": 10, "multiplier": 2, "fast_mode": true,
      "ensemble": true, "scale_factor": 1.0, "dtype": "float32",
      "torch_compile": false, "batch_size": 1
    }
  },
  "sharpen": {
    "class_type": "ImageSharpen",
    "inputs": { "image": ["rife", 0], "sharpen_radius": 1, "sigma": 0.6, "alpha": 0.3 }
  },
  "video": {
    "class_type": "VHS_VideoCombine",
    "inputs": {
      "images": ["sharpen", 0], "frame_rate": 30, "loop_count": 0,
      "filename_prefix": "benchmark", "format": "video/h264-mp4",
      "pix_fmt": "yuv420p", "crf": 28, "save_metadata": false,
      "trim_to_audio": false, "pingpong": false, "save_output": true
    }
  }
}
BENCHMARK_EOF

# Продублируем в стандартное место pyworker'а (если он уже скачан)
for misc in $(find "${WORKSPACE}" /opt -maxdepth 6 -type d -path "*workers/comfyui-json/misc" 2>/dev/null); do
    cp -f "${BENCHMARK_JSON_PATH}" "${misc}/benchmark.json" && \
        log "benchmark also copied to ${misc}/benchmark.json"
done

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
: "${S3_ACCESS_KEY_ID:?S3_ACCESS_KEY_ID is required (R2 key)}"
: "${S3_SECRET_ACCESS_KEY:?S3_SECRET_ACCESS_KEY is required (R2 secret)}"
: "${S3_ENDPOINT_URL:?S3_ENDPOINT_URL is required (https://<acct>.r2.cloudflarestorage.com)}"
: "${S3_BUCKET_NAME:?S3_BUCKET_NAME is required}"

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

TOTAL_TIME=$(( $(date +%s) - START_TS ))
log "OK: all models in place, download took ${TOTAL_TIME}s"
touch "${WORKSPACE}/.provisioning_done"
