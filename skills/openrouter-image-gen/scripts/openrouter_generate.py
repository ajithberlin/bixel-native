#!/usr/bin/env python3
"""Generate or edit an image through OpenRouter's images API (stdlib only).

Usage:
  python3 openrouter_generate.py --prompt "..." [--out out.png] [--model M] [--size WxH]
  python3 openrouter_generate.py --prompt "..." --image in.png --out out.png

Environment:
  OPENROUTER_API_KEY   required
  BIXEL_IMAGE_MODEL    model id to use when --model is not given
"""

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request

DEFAULT_MODELS = ["meta/muse-image", "google/gemini-3-pro-image"]


def base_url():
    return os.environ.get("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1").rstrip("/")


def api_key():
    key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if not key:
        sys.exit("error: OPENROUTER_API_KEY is not set")
    return key


def resolve_model(explicit):
    if explicit:
        return explicit
    env = os.environ.get("BIXEL_IMAGE_MODEL", "").strip()
    if env:
        return env
    return DEFAULT_MODELS[0]


def request_json(url, body):
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key()}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.status, resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8")


def extract_image(text):
    """Return (bytes, mime) from an images response, downloading a URL if needed."""
    payload = json.loads(text)
    data = (payload.get("data") or [{}])[0]
    if "b64_json" in data and data["b64_json"]:
        return base64.b64decode(data["b64_json"]), "image/png"
    url = data.get("url")
    if url:
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {api_key()}"})
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.read(), resp.headers.get("Content-Type", "image/png")
    sys.exit("error: no image returned by the model")


def generate(prompt, model, size):
    body = {
        "model": model,
        "prompt": prompt,
        "n": 1,
        "response_format": "b64_json",
    }
    if size:
        body["size"] = size
    status, text = request_json(f"{base_url()}/images/generations", body)
    if status >= 400:
        sys.exit(f"error: images/generations {status}: {text[:500]}")
    return extract_image(text)


def edit(prompt, image_path, model, size):
    # The edits endpoint expects multipart form data; build it manually.
    boundary = "----bixelformboundary"
    fields = [("model", model), ("prompt", prompt), ("n", "1"), ("response_format", "b64_json")]
    if size:
        fields.append(("size", size))
    with open(image_path, "rb") as f:
        image_bytes = f.read()

    parts = []
    for name, value in fields:
        parts.append(
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n".encode()
        )
    parts.append(
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"image.png\"\r\n"
        f"Content-Type: image/png\r\n\r\n".encode()
        + image_bytes
        + b"\r\n"
    )
    parts.append(f"--{boundary}--\r\n".encode())
    body = b"".join(parts)

    req = urllib.request.Request(
        f"{base_url()}/images/edits",
        data=body,
        headers={
            "Authorization": f"Bearer {api_key()}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            status, text = resp.status, resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        status, text = e.code, e.read().decode("utf-8")
    if status >= 400:
        sys.exit(f"error: images/edits {status}: {text[:500]}")
    return extract_image(text)


def main():
    ap = argparse.ArgumentParser(description="OpenRouter image generation (stdlib only)")
    ap.add_argument("--prompt", required=True, help="text prompt for the image")
    ap.add_argument("--image", help="input PNG for image-to-image edit")
    ap.add_argument("--out", default="out.png", help="output PNG path (default out.png)")
    ap.add_argument("--model", help="OpenRouter image model id")
    ap.add_argument("--size", help="e.g. 1024x1024")
    args = ap.parse_args()

    model = resolve_model(args.model)
    if args.image:
        data, mime = edit(args.prompt, args.image, model, args.size)
    else:
        data, mime = generate(args.prompt, model, args.size)

    with open(args.out, "wb") as f:
        f.write(data)

    # Report dimensions without an image dependency.
    w = h = 0
    if data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24:
        import struct

        w, h = struct.unpack(">II", data[16:24])
    print(f"saved {os.path.abspath(args.out)} ({w}x{h})")


if __name__ == "__main__":
    main()
