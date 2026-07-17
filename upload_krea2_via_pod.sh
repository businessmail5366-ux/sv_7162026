#!/bin/bash
set -u
EP="https://df97de19340dfc07e26d8b4f8c5a8547.r2.cloudflarestorage.com"
: "${AWS_ACCESS_KEY_ID:?SNACHALA: export AWS_ACCESS_KEY_ID=...}"
: "${AWS_SECRET_ACCESS_KEY:?SNACHALA: export AWS_SECRET_ACCESS_KEY=...}"
export AWS_DEFAULT_REGION=auto

if ! command -v aws >/dev/null 2>&1; then
    echo "== installing awscli =="
    python3 -m pip install -q awscli 2>/dev/null || { apt-get update -qq; apt-get install -y -qq awscli; }
fi
command -v aws >/dev/null 2>&1 || { echo "FATAL: aws cli ne ustanovilsya"; exit 1; }

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
    url="${entry%%|*}"; path="${entry##*|}"
    key="wan22/models/$path"
    want=$(curl -sIL "$url" | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print v}')
    have=$(aws --endpoint-url "$EP" s3api head-object --bucket runpod --key "$key" --query ContentLength --output text 2>/dev/null || true)
    if [ -n "$have" ] && [ "$have" = "$want" ]; then
        echo "SKIP $path (uzhe v R2, $have bytes)"
        continue
    fi
    echo "== $path ($want bytes) =="
    curl -sSfL "$url" | aws --endpoint-url "$EP" s3 cp - "s3://runpod/$key" --expected-size "${want:-40000000000}"
    rc=("${PIPESTATUS[@]}")
    have=$(aws --endpoint-url "$EP" s3api head-object --bucket runpod --key "$key" --query ContentLength --output text 2>/dev/null || true)
    if [ "${rc[0]}" -ne 0 ] || [ "${rc[1]}" -ne 0 ] || { [ -n "$want" ] && [ "$have" != "$want" ]; }; then
        echo "FAILED $path (curl=${rc[0]} aws=${rc[1]} size=$have/$want) - udalyaju chastichnyj fajl, perezapusti skript"
        aws --endpoint-url "$EP" s3 rm "s3://runpod/$key" >/dev/null 2>&1 || true
    else
        echo "OK $path"
    fi
done

echo; echo "== ITOG =="
aws --endpoint-url "$EP" s3 ls --recursive --human-readable s3://runpod/wan22/models/ | grep -iE "krea2|qwen|nmkd"
