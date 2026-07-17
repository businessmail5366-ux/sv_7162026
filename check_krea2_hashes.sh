#!/bin/bash
# =============================================================================
# Proverka SHA256 vseh modelej Krea2 v R2 protiv etalonov s HuggingFace.
# Nichego ne pishet na disk: rclone kachaet iz R2 strimom i schitaet hesh.
#
# Zapusk na pode (kluchi te zhe, chto dlya upload_krea2_via_pod.sh):
#   export R2_KEY_ID="..."   # ili AWS_ACCESS_KEY_ID
#   export R2_SECRET="..."   # ili AWS_SECRET_ACCESS_KEY
#   wget -q -O check_krea2_hashes.sh https://raw.githubusercontent.com/businessmail5366-ux/sv_7162026/main/check_krea2_hashes.sh
#   bash check_krea2_hashes.sh
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
export RCLONE_S3_NO_CHECK_BUCKET=true
DEST="r2:runpod/wan22/models"

command -v rclone >/dev/null 2>&1 || { echo "FATAL: net rclone — sperva zapusti upload_krea2_via_pod.sh"; exit 1; }

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

OK=0; BAD=0; MISS=0
for entry in $ITEMS; do
    url="${entry%%|*}"
    path="${entry##*|}"

    # Etalon: LFS-pointer fajl (version/oid sha256:.../size) po /raw/ ssylke
    raw_url=$(printf '%s' "$url" | sed 's#/resolve/#/raw/#')
    ptr=$(curl -sfL "$raw_url")
    want_sha=$(printf '%s\n' "$ptr" | awk '$1=="oid"{sub("sha256:","",$2); print $2; exit}')
    want_size=$(printf '%s\n' "$ptr" | awk '$1=="size"{print $2; exit}')
    if [ -z "$want_sha" ]; then
        echo "?? $path — ne smog poluchit etalonnyj hesh s HF, propuskaju"
        continue
    fi

    have_size=$(rclone lsl "$DEST/$path" 2>/dev/null | awk '{print $1; exit}')
    if [ -z "$have_size" ]; then
        echo "MISSING $path — fajla net v R2"
        MISS=$((MISS + 1))
        continue
    fi
    if [ "$have_size" != "$want_size" ]; then
        echo "BAD $path — razmer $have_size != $want_size (dokachaj zanovo)"
        BAD=$((BAD + 1))
        continue
    fi

    echo "-- schitaju sha256: $path ($have_size bytes)..."
    got_sha=$(rclone hashsum sha256 --download "$DEST/$path" 2>/dev/null | awk '{print $1; exit}')
    if [ "$got_sha" = "$want_sha" ]; then
        echo "OK $path"
        OK=$((OK + 1))
    else
        echo "BAD $path — sha256 ne sovpal:"
        echo "     zhdali $want_sha"
        echo "     est   ${got_sha:-<pusto>}"
        BAD=$((BAD + 1))
    fi
done

echo
echo "== ITOG: OK=$OK BAD=$BAD MISSING=$MISS =="
if [ "$BAD" -eq 0 ] && [ "$MISS" -eq 0 ]; then
    echo "Vse modeli v R2 celye, hehsi sovpadajut s HuggingFace."
else
    echo "Est problemy: bitye udali i perezapusti upload_krea2_via_pod.sh"
fi
