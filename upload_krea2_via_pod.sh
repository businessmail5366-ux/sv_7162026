#!/bin/bash
# =============================================================================
# Perekachka modelej Krea2 s HuggingFace naprjamuju v R2 (rclone copyurl,
# streaming — disk poda ne ispolzuetsya). Sekretov v fajle net: kluchi
# tolko cherez env.
#
# Zapusk na pode (Ubuntu), 4 stroki:
#   export R2_KEY_ID="..."       # ili AWS_ACCESS_KEY_ID
#   export R2_SECRET="..."       # ili AWS_SECRET_ACCESS_KEY
#   wget -q https://raw.githubusercontent.com/businessmail5366-ux/sv_7162026/main/upload_krea2_via_pod.sh
#   bash upload_krea2_via_pod.sh
#
# Povtornyj zapusk bezopasen: celye fajly propuskajutsya (SKIP), bitye
# udaljajutsja i kachajutsya zanovo.
# =============================================================================
set -u

KEY="${R2_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
SECRET="${R2_SECRET:-${AWS_SECRET_ACCESS_KEY:-}}"
if [ -z "$KEY" ] || [ -z "$SECRET" ]; then
    echo "SNACHALA: export R2_KEY_ID=... ; export R2_SECRET=..."
    exit 1
fi

export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$KEY"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$SECRET"
export RCLONE_CONFIG_R2_ENDPOINT="https://df97de19340dfc07e26d8b4f8c5a8547.r2.cloudflarestorage.com"
# R2-tokeny obychno ogranicheny odnim buketom: proverka/sozdanie buketa daet 403
export RCLONE_S3_NO_CHECK_BUCKET=true
DEST="r2:runpod/wan22/models"

# Nuzhen rclone >= 1.59 (provider Cloudflare); apt na Ubuntu 20.04 stavit 1.50.
need_install=1
if command -v rclone >/dev/null 2>&1; then
    ver=$(rclone version 2>/dev/null | head -n1 | sed 's/rclone v//')
    maj=${ver%%.*}; rest=${ver#*.}; min=${rest%%.*}
    case "$maj$min" in *[!0-9]*) maj=0; min=0;; esac
    if [ "${maj:-0}" -gt 1 ] || { [ "${maj:-0}" -eq 1 ] && [ "${min:-0}" -ge 59 ]; }; then
        need_install=0
    fi
fi
if [ "$need_install" -eq 1 ]; then
    echo "== installing rclone (latest .deb) =="
    curl -fsSL -o /tmp/rclone.deb https://downloads.rclone.org/rclone-current-linux-amd64.deb \
        && dpkg -i /tmp/rclone.deb >/dev/null \
        || { curl -fsSL https://rclone.org/install.sh | bash; }
fi
command -v rclone >/dev/null 2>&1 || { echo "FATAL: rclone ne ustanovilsya"; exit 1; }
rclone version | head -n1

echo "== proverka dostupa k buketu =="
rclone lsd r2:runpod >/dev/null || { echo "FATAL: net dostupa k buketu runpod — prover kluchi"; exit 1; }
echo test | rclone rcat "$DEST/.write_test" \
    && rclone deletefile "$DEST/.write_test" 2>/dev/null \
    || { echo "FATAL: zapis v buket zapreshhena — tokenu nuzhny prava Object Read & Write"; exit 1; }

ITEMS="
https://huggingface.co/Comfy-Org/Krea-2/resolve/main/diffusion_models/krea2_turbo_bf16.safetensors|diffusion_models/krea2_turbo_bf16.safetensors
https://huggingface.co/Comfy-Org/Krea-2/resolve/9b05e613f06f5ee45d97b362ba3478fec5488b5a/text_encoders/qwen3vl_4b_bf16.safetensors|text_encoders/qwen3vl_4b_bf16.safetensors
https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors|vae/qwen_image_vae.safetensors
https://huggingface.co/Alex583940/qwen_girl/resolve/main/realism_engine_krea2_v3.1.safetensors|loras/Krea2/realism_engine_krea2_v3.1.safetensors
https://huggingface.co/Alex583940/qwen_girl/resolve/main/RealisticSnapshotKrea2.safetensors|loras/Krea2/RealisticSnapshotKrea2.safetensors
https://huggingface.co/Alex583940/qwen_girl/resolve/main/realism_engine_krea2_v2.safetensors|loras/Krea2/realism_engine_krea2_v2.safetensors
https://huggingface.co/RudySen/Krea2-realism-V2/resolve/main/Krea2-realism-V2.safetensors|loras/Krea2/Krea2-realism-V2.safetensors
https://huggingface.co/gemasai/4x_NMKD-Superscale-SP_178000_G/resolve/main/4x_NMKD-Superscale-SP_178000_G.pth|upscale_models/4x_NMKD-Superscale-SP_178000_G.pth
"

for entry in $ITEMS; do
    url="${entry%%|*}"
    path="${entry##*|}"
    want=$(curl -sIL "$url" | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print v}')
    have=$(rclone lsl "$DEST/$path" 2>/dev/null | awk '{print $1; exit}')
    if [ -n "$have" ] && [ "$have" = "$want" ]; then
        echo "SKIP $path (uzhe v R2, $have bytes)"
        continue
    fi
    echo "== $path ($want bytes) =="
    rclone copyurl "$url" "$DEST/$path" -P --s3-upload-concurrency 8 --s3-chunk-size 64M
    rc=$?
    have=$(rclone lsl "$DEST/$path" 2>/dev/null | awk '{print $1; exit}')
    if [ "$rc" -ne 0 ] || { [ -n "$want" ] && [ "$have" != "$want" ]; }; then
        echo "FAILED $path (rc=$rc size=${have:-0}/$want) — udalyaju chastichnyj fajl, perezapusti skript"
        rclone deletefile "$DEST/$path" 2>/dev/null || true
    else
        echo "OK $path"
    fi
done

echo
echo "== ITOG =="
rclone lsl "$DEST" | grep -iE "krea2|qwen|nmkd"
rclone size "$DEST"
