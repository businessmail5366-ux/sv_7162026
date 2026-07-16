#!/usr/bin/env bash
# =============================================================================
# Однократный перенос моделей с RunPod network volume в Cloudflare R2.
#
# Запускать на временном RunPod Pod'е, к которому подключён network volume
# (на подах он монтируется в /workspace, модели лежат в /workspace/models).
#
# Перед запуском вставь свои ключи R2 (те же, что в BUCKET_* env endpoint'а):
#   export R2_ENDPOINT="https://<account_id>.r2.cloudflarestorage.com"
#   export R2_KEY_ID="..."
#   export R2_SECRET="..."
#   export R2_BUCKET="runpod"
#   export R2_PREFIX="wan22"
#   bash copy_models_to_r2.sh
#
# После завершения проверь вывод "rclone check" — должно быть 0 differences.
# Под можно удалять.
# =============================================================================
set -euo pipefail

SRC="${1:-/workspace/models}"
: "${R2_ENDPOINT:?export R2_ENDPOINT=https://<account_id>.r2.cloudflarestorage.com}"
: "${R2_KEY_ID:?export R2_KEY_ID=...}"
: "${R2_SECRET:?export R2_SECRET=...}"
R2_BUCKET="${R2_BUCKET:-runpod}"
R2_PREFIX="${R2_PREFIX:-wan22}"

[ -d "${SRC}" ] || { echo "source dir ${SRC} not found (volume подключён?)"; exit 1; }

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

echo "== source contents =="
find "${SRC}" -type f -exec ls -lh {} \;

echo "== copying ${SRC} -> ${DEST} =="
rclone copy "${SRC}" "${DEST}" \
    --progress --transfers 8 --s3-upload-concurrency 8 --s3-chunk-size 64M

echo "== verifying =="
rclone check "${SRC}" "${DEST}" --size-only

echo "== done =="
rclone size "${DEST}"
