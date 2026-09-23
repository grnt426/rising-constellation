#!/usr/bin/env python3
"""Generate compressed web variants (AVIF/WebP) of the site's heaviest images.

The originals stay in the repo untouched and remain the fallback `src` for
browsers that support neither format. Every variant is encoded from the
original, never from another variant. Resolution is preserved: the native
size is always emitted, and the smaller widths exist only so `srcset` can
hand DPR-1 screens a file that matches their render size. Nothing is upscaled.

Quality settings were picked by SSIM (8x8 block, luminance, alpha composited
over black and white) plus 100% crop inspection:
  - AVIF q80 / WebP q90 hold SSIM >= 0.99 on the painted landing art.
  - The portal backgrounds carry deliberate film grain; WebP q85 and AVIF
    q70 visibly smooth it, WebP q90 keeps it. Backgrounds are WebP-only,
    selected via CSS image-set() with the JPEG as fallback.

Usage (needs Pillow >= 11.3 with AVIF + WebP support):
    python bin/encode-web-images.py            # write variants, print report
    python bin/encode-web-images.py --check    # report only, write nothing

Re-run after replacing any source image listed in JOBS.
"""

import argparse
import io
import os
import sys

import numpy as np
from PIL import Image, features

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

AVIF = ("avif", dict(quality=80, speed=4))
WEBP = ("webp", dict(quality=90, method=6))

# (source, extra widths below native, formats)
LANDING = "assets/static/img"
SHOTS = "assets/static/img/screenshots"
BACKGROUNDS = "front/public/css/background"
SKYDOME = "front/public/map/skydome"

JOBS = [
    # Landing hero: rendered at a fixed 1600 CSS px (see _home.scss).
    (f"{LANDING}/landing-ships.png", [1600], [AVIF, WEBP]),
    (f"{LANDING}/landing-characters.png", [1600], [AVIF, WEBP]),
    # Landing screenshots: rendered at 778 CSS px inside the 800px section-3.
    (f"{SHOTS}/screenshot-1.png", [800, 1280], [AVIF, WEBP]),
    (f"{SHOTS}/screenshot-2.png", [800, 1280], [AVIF, WEBP]),
    (f"{SHOTS}/screenshot-3.png", [800, 1280], [AVIF, WEBP]),
    # Portal backgrounds: `background-size: cover`, so a portrait phone
    # upscales the native image anyway; only the native size is useful.
    (f"{BACKGROUNDS}/menu.jpg", [], [WEBP]),
    (f"{BACKGROUNDS}/default.jpg", [], [WEBP]),
    (f"{BACKGROUNDS}/tutorial.jpg", [], [WEBP]),
    (f"{BACKGROUNDS}/instance.jpg", [], [WEBP]),
    # Galaxy skydome textures (referenced from skybowl_001_LL.mtl). Their
    # SSIM reads low (~0.95) only because of faint noise in near-black
    # regions; 100% crops are indistinguishable. The star layers and the
    # two light cloud layers stay PNG: they are already small, and
    # cloudLIGHT_LL comes out LARGER as WebP.
    (f"{SKYDOME}/space002_LL.png", [], [WEBP]),
    (f"{SKYDOME}/cloudDARK03_LL.png", [], [WEBP]),
]


def variant_path(src, width, native_width, ext):
    stem = os.path.splitext(src)[0]
    suffix = "" if width == native_width else f"-{width}w"
    return f"{stem}{suffix}.{ext}"


def has_alpha(im):
    return "A" in im.getbands() or "transparency" in im.info


def luminance(rgb):
    return 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]


def block_ssim(x, y, k=8):
    h, w = (x.shape[0] // k) * k, (x.shape[1] // k) * k
    x = x[:h, :w].reshape(h // k, k, w // k, k)
    y = y[:h, :w].reshape(h // k, k, w // k, k)
    mx, my = x.mean((1, 3)), y.mean((1, 3))
    vx, vy = x.var((1, 3)), y.var((1, 3))
    cxy = ((x - mx[:, None, :, None]) * (y - my[:, None, :, None])).mean((1, 3))
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    s = ((2 * mx * my + c1) * (2 * cxy + c2)) / ((mx**2 + my**2 + c1) * (vx + vy + c2))
    return float(s.mean())


def composited(im, bg):
    a = np.asarray(im.convert("RGBA")).astype(np.float64)
    alpha = a[..., 3:4] / 255
    return luminance(a[..., :3] * alpha + np.array(bg) * (1 - alpha))


def similarity(ref, out):
    if ref.mode == "RGBA":
        return min(
            block_ssim(composited(ref, (0, 0, 0)), composited(out, (0, 0, 0))),
            block_ssim(composited(ref, (255, 255, 255)), composited(out, (255, 255, 255))),
        )
    return block_ssim(
        luminance(np.asarray(ref).astype(np.float64)),
        luminance(np.asarray(out).astype(np.float64)),
    )


def encode(im, fmt, opts):
    buf = io.BytesIO()
    im.save(buf, fmt.upper(), **opts)
    data = buf.getvalue()
    decoded = Image.open(io.BytesIO(data)).convert(im.mode)
    return data, decoded


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--check", action="store_true", help="report only; write nothing")
    args = parser.parse_args()

    for feature in ("avif", "webp"):
        if not features.check(feature):
            sys.exit(f"Pillow was built without {feature} support")

    total_src = total_best = 0
    for rel, widths, formats in JOBS:
        src = os.path.join(ROOT, rel)
        original = Image.open(src)
        im = original.convert("RGBA" if has_alpha(original) else "RGB")
        src_size = os.path.getsize(src)
        total_src += src_size
        print(f"{rel}  {im.width}x{im.height} {im.mode}  {src_size / 1e3:,.0f} KB")

        for width in sorted(set(widths + [im.width])):
            if width > im.width:
                continue
            scaled = im if width == im.width else im.resize(
                (width, round(im.height * width / im.width)), Image.LANCZOS)
            sizes = []
            for ext, opts in formats:
                data, decoded = encode(scaled, ext, opts)
                out = variant_path(rel, width, im.width, ext)
                sizes.append(len(data))
                score = similarity(scaled, decoded)
                print(f"  -> {out}  {len(data) / 1e3:,.0f} KB  ssim={score:.4f}")
                if not args.check:
                    with open(os.path.join(ROOT, out), "wb") as f:
                        f.write(data)
            if width == im.width:
                total_best += min(sizes)

    print(f"\nnative-size totals (smallest format each): {total_src / 1e6:.1f} MB -> {total_best / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
