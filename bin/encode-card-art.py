#!/usr/bin/env python3
"""Encode the card illustrations as 1x/2x WebP for `srcset`.

Card art (agents, doctrines, patents, buildings, ships, avatars) is drawn at
304x152 CSS px on desktop and 238x119 on mobile. The repo's JPEGs are
400x200 (avatars 800x400), saved at near-maximum quality, ~65 KB each.

For every JPEG this writes, next to it:
  - `<name>.webp`     400x200, WebP q90: what a DPR-1 screen needs. ~16 KB.
  - `<name>@2x.webp`  800x400, WebP q85 (q90 for grainy art, see Q2_FLOOR),
                      ONLY when a real >= 800px master exists: what a
                      DPR-2/3 screen needs. ~50 KB.
The JPEG stays untouched as the `<img src>` fallback (and for the server
renders that read it). Nothing is upscaled: no master, no @2x.

Masters come from the original developers' design files (not in the repo;
pass --design). Avatars need none: their JPEGs are already 800x400.
  Lex/Lex_HD/<x>_HD.jpg           -> doctrines/<x>.jpg   1600x800
  Brevets/Brevets_HD/<x>_HD.jpg   -> patents/<x>.jpg     1600x800
  Agents/Upscale, Agents/team RC  -> agents/... via AGENT_MASTERS (the
                                     files are named after the dev team)
Every master is checked against the game JPEG it replaces (same art, same
crop) before anything is written.

Quality was picked by block SSIM (see encode-web-images.py) on a sample of
the masters: 400px q90 >= 0.959 (the convention for card art, keeps grain);
800px q85 >= 0.949 at 52 KB, where q90 would be 70 KB, bigger than the JPEG.

Also writes front/src/utils/card-art-hd.js, the list of illustrations that
have an @2x file (generated from what is on disk, so it never claims a file
that does not exist), and the @2x files for the landing page's cards in
assets/static/img (their 1x WebP belongs to encode-web-images.py).

Usage (Pillow with WebP support):
    python bin/encode-card-art.py --design <path>/original-design-files/Design
    python bin/encode-card-art.py                # 1x only, keep existing @2x
    python bin/encode-card-art.py --check ...    # report only, write nothing
"""

import argparse
import importlib.util
import io
import os
import sys

from PIL import Image, features

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAME = os.path.join(ROOT, "front", "public", "data")
LANDING = os.path.join(ROOT, "assets", "static", "img")
MANIFEST = os.path.join(ROOT, "front", "src", "utils", "card-art-hd.js")

DIRS = ("agents", "doctrines", "patents", "buildings", "ships", "avatars")
LANDING_DIRS = ("agents", "doctrines", "patents", "buildings")

ONE_X = (400, 200)
TWO_X = (800, 400)
Q1 = dict(quality=90, method=6)
Q2 = dict(quality=85, method=6)
# Art with even film grain over large dark areas (the avatars' backdrop)
# loses that grain at q85 (SSIM ~0.91); those step up to q90 (~0.95).
Q2_FLOOR = 0.94
Q2_GRAIN = dict(quality=90, method=6)

# Mean absolute difference (0-255) between a master shrunk to 64x32 and the
# game JPEG. Same art scores < 1; the loosest true match measured is 9.0
# (patents/dome_defense_2, fine binary-digit texture); different art >= 30.
MATCH_LIMIT = 12.0

# The agent masters are named after the people the portraits were drawn
# from. Mapping found by pixel matching, re-verified on every run.
AGENT_MASTERS = {
    "Agents/Upscale/amandine_1600x800_RC_001.jpg": "speakerF_002",
    "Agents/Upscale/avok_1600x800_RC_001.jpg": "admiralM_011",
    "Agents/Upscale/david_1600x800_RC_001.jpg": "speakerM_008",
    "Agents/Upscale/lucie_1600x800_RC_001.jpg": "speakerF_003",
    "Agents/Upscale/noe_1600x800_RC_001.jpg": "speakerM_006",
    "Agents/Upscale/noelle_1600x800_RC_001.jpg": "spyF_003",
    "Agents/Upscale/victor_1600x800_RC_001.jpg": "speakerM_007",
    "Agents/Upscale/vincent_1600x800_RC_001.jpg": "spyM_006",
    "Agents/Upscale/zahnki_1600x800_RC_001.jpg": "admiralM_007",
    "Agents/team RC/clement_002_BIG_LL.jpg": "spyM_004",
    "Agents/team RC/david_002_BIG_LL.jpg": "speakerM_003",
    "Agents/team RC/gil_002_BIG_LL.jpg": "admiralM_003",
    "Agents/team RC/jerome_002_BIG_LL.jpg": "spyM_002",
    "Agents/team RC/loïc_002_BIG_LL.jpg": "admiralM_006",
    "Agents/team RC/raph_002_BIG_LL.jpg": "spyM_003",
    "Agents/team RC/seb_002_BIG_LL.jpg": "speakerM_004",
    "Agents/team RC/thierry_002_BIG_LL.jpg": "admiralM_004",
    "Agents/team RC/victor_002_BIG_LL.jpg": "spyM_005",
    "Agents/team RC/vincent_002_BIG_LL.jpg": "admiralM_005",
}


def load_helpers():
    path = os.path.join(ROOT, "bin", "encode-web-images.py")
    sys.dont_write_bytecode = True  # no bin/__pycache__
    spec = importlib.util.spec_from_file_location("encode_web_images", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def rgb(path):
    with Image.open(path) as im:
        return im.convert("RGB")


def mad(a, b):
    ta = a.resize((64, 32), Image.LANCZOS).tobytes()
    tb = b.resize((64, 32), Image.LANCZOS).tobytes()
    return sum(abs(x - y) for x, y in zip(ta, tb)) / len(ta)


def find_masters(design):
    """{(dir, name): master path} for every >= 800px master in the design files."""
    found = {}
    if not design:
        return found
    for sub, target in (("Lex/Lex_HD", "doctrines"), ("Brevets/Brevets_HD", "patents")):
        folder = os.path.join(design, sub)
        for f in sorted(os.listdir(folder)):
            if f.endswith("_HD.jpg"):
                found[(target, f[: -len("_HD.jpg")])] = os.path.join(folder, f)
    for rel, name in AGENT_MASTERS.items():
        found[("agents", name)] = os.path.join(design, *rel.split("/"))
    return found


def encode(ewi, im, size, opts):
    scaled = im if im.size == size else im.resize(size, Image.LANCZOS)
    data, decoded = ewi.encode(scaled, "webp", opts)
    return data, ewi.similarity(scaled, decoded)


def write(path, data, check):
    if not check:
        with open(path, "wb") as f:
            f.write(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--design", help="path to original-design-files/Design")
    parser.add_argument("--check", action="store_true", help="report only; write nothing")
    args = parser.parse_args()

    if not features.check("webp"):
        sys.exit("Pillow was built without webp support")
    if args.design and not os.path.isdir(args.design):
        sys.exit(f"--design: no such folder: {args.design}")
    ewi = load_helpers()

    masters = find_masters(args.design)
    used = set()
    problems = []
    totals = {"jpg": 0, "1x": 0, "2x": 0, "n1": 0, "n2": 0}
    min_ssim = {"1x": 1.0, "2x": 1.0}

    for d in DIRS:
        folder = os.path.join(GAME, d)
        for f in sorted(os.listdir(folder)):
            if not f.endswith(".jpg"):
                continue
            name = f[:-4]
            jpg_path = os.path.join(folder, f)
            game = rgb(jpg_path)
            totals["jpg"] += os.path.getsize(jpg_path)

            master = None
            if game.width >= TWO_X[0]:
                master = game                      # avatars: the JPEG is the master
            elif (d, name) in masters:
                path = masters[(d, name)]
                used.add((d, name))
                candidate = rgb(path)
                if candidate.width < TWO_X[0]:
                    problems.append(f"{d}/{name}: master {candidate.size} is smaller than 2x")
                else:
                    score = mad(candidate, game)
                    if score > MATCH_LIMIT:
                        problems.append(f"{d}/{name}: master {os.path.basename(path)} does not match (MAD {score:.1f})")
                    else:
                        master = candidate

            src = master or game
            data1, s1 = encode(ewi, src, ONE_X, Q1)
            write(os.path.join(folder, f"{name}.webp"), data1, args.check)
            totals["1x"] += len(data1)
            totals["n1"] += 1
            min_ssim["1x"] = min(min_ssim["1x"], s1)
            line = f"{d}/{name}: 1x {len(data1) / 1024:4.1f} KB ssim {s1:.3f}"

            if master is not None:
                data2, s2 = encode(ewi, master, TWO_X, Q2)
                if s2 < Q2_FLOOR:
                    data2, s2 = encode(ewi, master, TWO_X, Q2_GRAIN)
                write(os.path.join(folder, f"{name}@2x.webp"), data2, args.check)
                totals["2x"] += len(data2)
                totals["n2"] += 1
                min_ssim["2x"] = min(min_ssim["2x"], s2)
                line += f" | 2x {len(data2) / 1024:4.1f} KB ssim {s2:.3f}"

                landing = os.path.join(LANDING, d, f)
                if d in LANDING_DIRS and os.path.exists(landing):
                    write(os.path.join(LANDING, d, f"{name}@2x.webp"), data2, args.check)
                    line += " (+landing)"
            print(line)

    for key in sorted(set(masters) - used):
        problems.append(f"{key[0]}/{key[1]}: master has no game JPEG")

    if not args.check:
        write_manifest()

    n1, n2 = totals["n1"], max(totals["n2"], 1)
    print(f"\n{totals['n1']} illustrations: JPEG {totals['jpg'] / 1e6:.1f} MB "
          f"(avg {totals['jpg'] / n1 / 1024:.0f} KB) -> 1x WebP {totals['1x'] / 1e6:.1f} MB "
          f"(avg {totals['1x'] / n1 / 1024:.0f} KB, min ssim {min_ssim['1x']:.3f})")
    print(f"{totals['n2']} with 2x: {totals['2x'] / 1e6:.1f} MB "
          f"(avg {totals['2x'] / n2 / 1024:.0f} KB, min ssim {min_ssim['2x']:.3f})")
    for p in problems:
        print("WARNING:", p)
    if problems:
        sys.exit(1)


def write_manifest():
    hd = {}
    for d in DIRS:
        folder = os.path.join(GAME, d)
        hd[d] = sorted(f[: -len("@2x.webp")] for f in os.listdir(folder) if f.endswith("@2x.webp"))
    lines = [
        "// GENERATED by bin/encode-card-art.py from the @2x.webp files on disk.",
        "// Do not edit: re-run the script. Illustrations listed here have an",
        "// 800x400 `<name>@2x.webp` next to their JPEG; every JPEG has a 400x200",
        "// `<name>.webp`.",
        "",
        "export default {",
    ]
    for d in DIRS:
        lines.append(f"  {d}: [")
        lines.extend(f"    '{n}'," for n in hd[d])
        lines.append("  ],")
    lines.append("};")
    with open(MANIFEST, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
