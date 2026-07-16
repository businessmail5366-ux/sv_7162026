"""Клиент для WAN 2.2 I2V serverless endpoint'а на Vast.ai (шаблон ComfyUI Serverless).

Вся логика бывшего RunPod handler.py перенесена сюда: клиент сам собирает
workflow из workflow_api.json и отправляет его целиком на /generate/sync
(pyworker comfyui-json). Картинку по URL воркер скачает сам, результат
зальёт в R2/S3 и вернёт presigned-ссылку.

Использование:
  pip install vastai requests pillow
  set VAST_API_KEY=...            (PowerShell: $env:VAST_API_KEY="...")
  set VAST_ENDPOINT_NAME=wan22
  python vast_request.py https://example.com/photo.jpg 864 1040

Параметры как у RunPod-версии:
  image_url, width, height, prompt, negative_prompt, frames (4n+1), fps,
  seed, steps, switch_step, crf, loras_high / loras_low.
"""

import argparse
import asyncio
import copy
import io
import json
import os
import random
import sys
import time
import uuid

import requests

try:
    from PIL import Image
except ImportError:
    Image = None

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ENDPOINT_NAME = os.environ.get("VAST_ENDPOINT_NAME", "wan22")
SAGE_MODE = os.environ.get("SAGE_ATTENTION_MODE", "disabled")  # sageattention в образе Vast нет
REQUEST_COST = int(os.environ.get("REQUEST_COST", "100"))

with open(os.path.join(SCRIPT_DIR, "workflow_api.json"), "r", encoding="utf-8") as f:
    WORKFLOW_TEMPLATE = json.load(f)


def fetch_image_size(url):
    """Скачивает фото (только чтобы узнать размеры) — как fetch_image в handler.py."""
    if Image is None:
        print("[client] pillow не установлен — использую width/height как есть, без вписывания")
        return None, None
    r = requests.get(url, timeout=120, headers={"User-Agent": "Mozilla/5.0"})
    r.raise_for_status()
    img = Image.open(io.BytesIO(r.content))
    return img.width, img.height


def fit_resolution(src_w, src_h, max_w, max_h, div=16):
    """Вписывает src в бокс max_w x max_h с сохранением пропорций, кратно div."""
    scale = min(max_w / src_w, max_h / src_h)
    w = max(div, int(src_w * scale) // div * div)
    h = max(div, int(src_h * scale) // div * div)
    return w, h


def apply_loras(wf, side, loras):
    """Пересобирает цепочку LoRA для стороны side ('high'/'low') — 1-в-1 из handler.py."""
    for key in [k for k in list(wf) if k.startswith(f"lora_{side}_")]:
        del wf[key]
    prev = f"unet_{side}"
    for i, lora in enumerate(loras, 1):
        node_id = f"lora_{side}_{i}"
        wf[node_id] = {
            "class_type": "LoraLoaderModelOnly",
            "inputs": {
                "model": [prev, 0],
                "lora_name": str(lora["name"]),
                "strength_model": float(lora.get("strength", 1.0)),
            },
        }
        prev = node_id
    wf[f"sage_{side}"]["inputs"]["model"] = [prev, 0]


def build_workflow(inp):
    wf = copy.deepcopy(WORKFLOW_TEMPLATE)

    frames = int(inp.get("frames", 81))
    frames = max(5, ((frames - 1) // 4) * 4 + 1)  # WAN требует 4n+1
    fps = int(inp.get("fps", 45))
    seed = int(inp.get("seed", random.randint(0, 2**48)))
    steps = int(inp.get("steps", 8))
    switch = int(inp.get("switch_step", max(1, steps // 2)))
    crf = int(inp.get("crf", 17))

    # Подгонка разрешения под исходное фото (клиентская замена ImageResizeKJ)
    box_w, box_h = int(inp.get("width", 864)), int(inp.get("height", 1040))
    src_w, src_h = fetch_image_size(inp["image_url"])
    if src_w:
        width, height = fit_resolution(src_w, src_h, box_w, box_h)
    else:
        width, height = box_w // 16 * 16, box_h // 16 * 16

    # comfyui-json worker сам скачает URL и подставит локальный путь
    wf["load_image"]["inputs"]["image"] = inp["image_url"]

    wf["resize"]["inputs"]["width"] = width
    wf["resize"]["inputs"]["height"] = height
    wf["i2v"]["inputs"]["width"] = width
    wf["i2v"]["inputs"]["height"] = height
    wf["i2v"]["inputs"]["length"] = frames
    wf["trim_end"]["inputs"]["length"] = max(1, frames - 1)
    wf["video"]["inputs"]["frame_rate"] = fps
    wf["video"]["inputs"]["crf"] = crf

    if inp.get("prompt"):
        wf["pos"]["inputs"]["text"] = str(inp["prompt"])
    if inp.get("negative_prompt"):
        wf["neg"]["inputs"]["text"] = str(inp["negative_prompt"])

    wf["sampler_high"]["inputs"].update(
        {"noise_seed": seed, "steps": steps, "end_at_step": switch}
    )
    wf["sampler_low"]["inputs"].update(
        {"noise_seed": seed, "steps": steps, "start_at_step": switch}
    )

    wf["sage_high"]["inputs"]["sage_attention"] = SAGE_MODE
    wf["sage_low"]["inputs"]["sage_attention"] = SAGE_MODE

    if "loras_high" in inp and inp["loras_high"] is not None:
        apply_loras(wf, "high", inp["loras_high"])
    if "loras_low" in inp and inp["loras_low"] is not None:
        apply_loras(wf, "low", inp["loras_low"])

    return wf, {"width": width, "height": height, "frames": frames, "fps": fps, "seed": seed}


def extract_video(result, meta):
    """Достаёт ссылку/файл видео из ответа comfyui-json worker'а."""
    resp = result.get("response", result) or {}
    worker_url = result.get("url", "")

    # 1) S3 настроен -> в output лежат presigned-ссылки
    for item in resp.get("output", []) or []:
        name = str(item.get("filename", ""))
        if item.get("url") and name.endswith(".mp4"):
            return {"video_url": item["url"], **meta}
    for item in resp.get("output", []) or []:
        if item.get("url"):
            return {"video_url": item["url"], **meta}

    # 2) Fallback: тянем файл напрямую с воркера через /view
    comfy = resp.get("comfyui_response") or {}
    outputs = comfy.get("outputs") or {}
    for node_output in outputs.values():
        for key in ("gifs", "videos"):
            for item in node_output.get(key, []) or []:
                filename = item.get("filename")
                if filename and worker_url:
                    r = requests.get(
                        f"{worker_url.rstrip('/')}/view",
                        params={
                            "filename": filename,
                            "type": item.get("type", "output"),
                            "subfolder": item.get("subfolder", ""),
                        },
                        timeout=300,
                        verify=False,
                    )
                    r.raise_for_status()
                    out_path = "result.mp4"
                    with open(out_path, "wb") as fh:
                        fh.write(r.content)
                    return {"video_file": out_path, **meta}

    raise RuntimeError(f"No video in response: {json.dumps(resp)[:2000]}")


async def run(inp):
    from vastai import Serverless

    wf, meta = build_workflow(inp)
    payload = {
        "input": {
            "request_id": uuid.uuid4().hex,
            "workflow_json": wf,
        }
    }
    print(f"[client] {meta['width']}x{meta['height']}, {meta['frames']} frames, seed={meta['seed']}")

    async with Serverless(os.environ.get("VAST_API_KEY")) as client:
        endpoint = await client.get_endpoint(name=ENDPOINT_NAME)
        t0 = time.time()
        try:
            result = await endpoint.request("/generate/sync", payload, cost=REQUEST_COST)
        except TypeError:  # на случай другой сигнатуры в новых версиях SDK
            result = await endpoint.request("/generate/sync", payload)
        print(f"[client] done in {time.time() - t0:.0f}s")

    return extract_video(result, meta)


def main():
    p = argparse.ArgumentParser(description="WAN 2.2 I2V на Vast.ai serverless")
    p.add_argument("image_url")
    p.add_argument("width", nargs="?", type=int, default=864)
    p.add_argument("height", nargs="?", type=int, default=1040)
    p.add_argument("--prompt")
    p.add_argument("--negative-prompt")
    p.add_argument("--frames", type=int, default=81)
    p.add_argument("--fps", type=int, default=45)
    p.add_argument("--seed", type=int)
    p.add_argument("--steps", type=int, default=8)
    p.add_argument("--switch-step", type=int)
    p.add_argument("--crf", type=int, default=17)
    p.add_argument("--loras-high", help='JSON: [{"name":"WAN 2.2/x.safetensors","strength":1.0}]')
    p.add_argument("--loras-low", help="JSON, аналогично --loras-high")
    args = p.parse_args()

    inp = {
        "image_url": args.image_url,
        "width": args.width,
        "height": args.height,
        "frames": args.frames,
        "fps": args.fps,
        "steps": args.steps,
        "crf": args.crf,
    }
    if args.prompt:
        inp["prompt"] = args.prompt
    if args.negative_prompt:
        inp["negative_prompt"] = args.negative_prompt
    if args.seed is not None:
        inp["seed"] = args.seed
    if args.switch_step is not None:
        inp["switch_step"] = args.switch_step
    if args.loras_high:
        inp["loras_high"] = json.loads(args.loras_high)
    if args.loras_low:
        inp["loras_low"] = json.loads(args.loras_low)

    out = asyncio.run(run(inp))
    print(json.dumps(out, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
