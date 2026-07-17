#!/usr/bin/env bash
# =============================================================================
# Перекачка моделей Krea2 (t2i воркфлоу workflow_krea2_api.json) с HuggingFace
# напрямую в R2 — стримингом через `rclone copyurl`, локальный диск не нужен.
# Запускать где угодно с нормальным интернетом: локально, на дешёвом поде и т.п.
#
# Кладёт файлы в тот же префикс <R2_PREFIX>/models/..., откуда provisioning.sh
# качает всё скопом. Повторный запуск безопасен: уже залитые файлы пропускаются.
#
#   export R2_ENDPOINT="https://<account_id>.r2.cloudflarestorage.com"
#   export R2_KEY_ID="..."
#   export R2_SECRET="..."
#   export R2_BUCKET="runpod"
#   export R2_PREFIX="wan22"
#   bash upload_krea2_models_to_r2.sh
#
# После заливки новые воркеры скачают модели автоматически (provisioning.sh
# заберёт весь префикс), старых воркеров надо пересоздать.
# =============================================================================
set -euo pipefail

: "${R2_ENDPOINT:?export R2_ENDPOINT=https://<account_id>.r2.cloudflarestorage.com}"
: "${R2_KEY_ID:?export R2_KEY_ID=...}"
: "${R2_SECRET:?export R2_SECRET=...}"
R2_BUCKET="${R2_BUCKET:-runpod}"
R2_PREFIX="${R2_PREFIX:-wan22}"

if ! command -v rclone >/dev/null 2>&1; then
    echo "== installing rclone =="
    curl -fsSL https://rclone.org/install.sh | bash
fi

export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${R2_KEY_ID}"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${R2_SECRET}"
export RCLONE_CONFIG_R2_ENDPOINT="${R2_ENDPOINT}"

DEST="r2:${R2_BUCKET}/${R2_PREFIX}/models"

# "URL|путь в models/" — пути должны совпадать с workflow_krea2_api.json.
# Первые 5 обязательны для воркфлоу (их проверяет provisioning.sh),
# остальные — дополнительные LoRA и апскейлер, пусть лежат рядом.
ITEMS=(
    "https://huggingface.co/Comfy-Org/Krea-2/resolve/main/diffusion_models/krea2_turbo_bf16.safetensors|diffusion_models/krea2_turbo_bf16.safetensors"
    "https://huggingface.co/Comfy-Org/Krea-2/resolve/9b05e613f06f5ee45d97b362ba3478fec5488b5a/text_encoders/qwen3vl_4b_bf16.safetensors|text_encoders/qwen3vl_4b_bf16.safetensors"
    "https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors|vae/qwen_image_vae.safetensors"
    "https://huggingface.co/Alex583940/qwen_girl/resolve/main/realism_engine_krea2_v3.1.safetensors?download=true|loras/Krea2/realism_engine_krea2_v3.1.safetensors"
    "https://huggingface.co/Alex583940/qwen_girl/resolve/main/RealisticSnapshotKrea2.safetensors?download=true|loras/Krea2/RealisticSnapshotKrea2.safetensors"
    "https://huggingface.co/Alex583940/qwen_girl/resolve/main/realism_engine_krea2_v2.safetensors?download=true|loras/Krea2/realism_engine_krea2_v2.safetensors"
    "https://huggingface.co/RudySen/Krea2-realism-V2/resolve/main/Krea2-realism-V2.safetensors?download=true|loras/Krea2/Krea2-realism-V2.safetensors"
    "https://huggingface.co/gemasai/4x_NMKD-Superscale-SP_178000_G/resolve/main/4x_NMKD-Superscale-SP_178000_G.pth?download=true|upscale_models/4x_NMKD-Superscale-SP_178000_G.pth"
)

for entry in "${ITEMS[@]}"; do
    url="${entry%%|*}"
    path="${entry##*|}"
    if [ -n "$(rclone lsf "${DEST}/${path}" 2>/dev/null)" ]; then
        echo "== skip (already in R2): ${path} =="
        continue
    fi
    echo "== ${url} -> ${DEST}/${path} =="
    rclone copyurl "${url}" "${DEST}/${path}" \
        -P --s3-upload-concurrency 8 --s3-chunk-size 64M
done

echo "== verifying =="
FAILED=0
for entry in "${ITEMS[@]}"; do
    path="${entry##*|}"
    if ! rclone lsl "${DEST}/${path}" 2>/dev/null | grep -q .; then
        echo "MISSING in R2: ${path}"
        FAILED=1
    fi
done
[ "${FAILED}" -eq 0 ] || { echo "не все файлы залились — перезапусти скрипт"; exit 1; }

echo "== done =="
rclone lsl "${DEST}/loras/Krea2" "${DEST}/upscale_models" 2>/dev/null || true
rclone size "${DEST}"
