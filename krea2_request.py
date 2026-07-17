"""Клиент для Krea2 realism t2i (text-to-image) на том же Vast.ai endpoint'е.

Второй воркфлоу рядом с WAN 2.2 (vast_request.py). Основан на GUI-воркфлоу
ComfyUI_temp_ytzkx_00283_.json (Krea 2 Realism, SFW+NSFW): собирает workflow
из workflow_krea2_api.json и отправляет целиком на /generate/sync
(pyworker comfyui-json). Результат (png) воркер зальёт в R2/S3 и вернёт
presigned-ссылку.

Отличия API-версии от исходного GUI-воркфлоу:
  - Power Lora Loader (rgthree) заменён цепочкой стандартных LoraLoader
    (модель+clip); список пересобирается параметром --loras — как
    loras_high/low у WAN-версии;
  - PreviewImage заменён на SaveImage — иначе воркер не выгрузит результат;
  - негатив как в оригинале: ConditioningZeroOut от позитива (текст негатива
    у Krea2-turbo не используется, cfg=1).

Требует: свежий comfy-core (CLIPLoader type "krea2") — см. UPDATE_COMFYUI
в provisioning.sh, и модели Krea2 в R2 — см. upload_krea2_models_to_r2.sh.

Использование:
  pip install vastai requests
  set VAST_API_KEY=...            (PowerShell: $env:VAST_API_KEY="...")
  set VAST_ENDPOINT_NAME=wan22
  python krea2_request.py "a candid smartphone photo of ..." 896 1152
"""

import argparse
import asyncio
import copy
import json
import os
import random
import time
import uuid

import requests

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ENDPOINT_NAME = os.environ.get("VAST_ENDPOINT_NAME", "wan22")
REQUEST_COST = int(os.environ.get("REQUEST_COST", "100"))

with open(os.path.join(SCRIPT_DIR, "workflow_krea2_api.json"), "r", encoding="utf-8") as f:
    KREA2_TEMPLATE = json.load(f)

IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".webp")


def apply_loras(wf, loras):
    """Пересобирает цепочку LoRA (LoraLoader: модель+clip) — аналог apply_loras в vast_request.py."""
    for key in [k for k in list(wf) if k.startswith("lora_")]:
        del wf[key]
    prev_model, prev_clip = ["unet", 0], ["clip", 0]
    for i, lora in enumerate(loras, 1):
        node_id = f"lora_{i}"
        strength = float(lora.get("strength", 1.0))
        wf[node_id] = {
            "class_type": "LoraLoader",
            "inputs": {
                "model": prev_model,
                "clip": prev_clip,
                "lora_name": str(lora["name"]),
                "strength_model": strength,
                "strength_clip": float(lora.get("strength_clip", strength)),
            },
        }
        prev_model, prev_clip = [node_id, 0], [node_id, 1]
    wf["sampler"]["inputs"]["model"] = prev_model
    wf["pos"]["inputs"]["clip"] = prev_clip


def build_workflow(inp):
    wf = copy.deepcopy(KREA2_TEMPLATE)

    width = max(16, int(inp.get("width", 896)) // 16 * 16)
    height = max(16, int(inp.get("height", 1152)) // 16 * 16)
    batch = max(1, int(inp.get("batch", 1)))
    seed = int(inp.get("seed", random.randint(0, 2**48)))
    steps = int(inp.get("steps", 8))
    cfg = float(inp.get("cfg", 1.0))
    denoise = float(inp.get("denoise", 0.7))

    wf["pos"]["inputs"]["text"] = str(inp["prompt"])
    wf["latent"]["inputs"].update({"width": width, "height": height, "batch_size": batch})
    wf["sampler"]["inputs"].update(
        {
            "seed": seed,
            "steps": steps,
            "cfg": cfg,
            "denoise": denoise,
            "sampler_name": str(inp.get("sampler", "dpmpp_2m_sde_gpu")),
            "scheduler": str(inp.get("scheduler", "sgm_uniform")),
        }
    )

    if "loras" in inp and inp["loras"] is not None:
        apply_loras(wf, inp["loras"])

    return wf, {"width": width, "height": height, "seed": seed, "steps": steps, "batch": batch}


def extract_images(result, meta):
    """Достаёт ссылки/файлы картинок из ответа comfyui-json worker'а."""
    resp = result.get("response", result) or {}
    worker_url = result.get("url", "")

    # 1) S3 настроен -> в output лежат presigned-ссылки
    output = resp.get("output", []) or []
    urls = [
        item["url"]
        for item in output
        if item.get("url") and str(item.get("filename", "")).lower().endswith(IMAGE_EXTS)
    ]
    if not urls:
        urls = [item["url"] for item in output if item.get("url")]
    if urls:
        return {"image_url": urls[0], "image_urls": urls, **meta}

    # 2) Fallback: тянем файлы напрямую с воркера через /view
    comfy = resp.get("comfyui_response") or {}
    outputs = comfy.get("outputs") or {}
    saved = []
    for node_output in outputs.values():
        for item in node_output.get("images", []) or []:
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
                out_path = f"krea2_{len(saved)}.png"
                with open(out_path, "wb") as fh:
                    fh.write(r.content)
                saved.append(out_path)
    if saved:
        return {"image_file": saved[0], "image_files": saved, **meta}

    raise RuntimeError(f"No image in response: {json.dumps(resp)[:2000]}")


async def run(inp):
    from vastai import Serverless

    wf, meta = build_workflow(inp)
    payload = {
        "input": {
            "request_id": uuid.uuid4().hex,
            "workflow_json": wf,
        }
    }
    print(f"[client] krea2 t2i {meta['width']}x{meta['height']}, seed={meta['seed']}, steps={meta['steps']}")

    async with Serverless(os.environ.get("VAST_API_KEY")) as client:
        endpoint = await client.get_endpoint(name=ENDPOINT_NAME)
        t0 = time.time()
        try:
            result = await endpoint.request("/generate/sync", payload, cost=REQUEST_COST)
        except TypeError:  # на случай другой сигнатуры в новых версиях SDK
            result = await endpoint.request("/generate/sync", payload)
        print(f"[client] done in {time.time() - t0:.0f}s")

    return extract_images(result, meta)


def main():
    p = argparse.ArgumentParser(description="Krea2 realism t2i на Vast.ai serverless")
    p.add_argument("prompt")
    p.add_argument("width", nargs="?", type=int, default=896)
    p.add_argument("height", nargs="?", type=int, default=1152)
    p.add_argument("--seed", type=int)
    p.add_argument("--steps", type=int, default=8)
    p.add_argument("--cfg", type=float, default=1.0)
    p.add_argument("--denoise", type=float, default=0.7)
    p.add_argument("--batch", type=int, default=1)
    p.add_argument("--sampler", default="dpmpp_2m_sde_gpu")
    p.add_argument("--scheduler", default="sgm_uniform")
    p.add_argument(
        "--loras",
        help='JSON: [{"name":"Krea2/realism_engine_krea2_v3.1.safetensors","strength":1.0}]',
    )
    args = p.parse_args()

    inp = {
        "prompt": args.prompt,
        "width": args.width,
        "height": args.height,
        "steps": args.steps,
        "cfg": args.cfg,
        "denoise": args.denoise,
        "batch": args.batch,
        "sampler": args.sampler,
        "scheduler": args.scheduler,
    }
    if args.seed is not None:
        inp["seed"] = args.seed
    if args.loras:
        inp["loras"] = json.loads(args.loras)

    out = asyncio.run(run(inp))
    print(json.dumps(out, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
