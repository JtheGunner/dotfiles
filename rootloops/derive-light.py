#!/usr/bin/env python3
"""Derive a LIGHT companion palette from the (dark) Root Loops palette.env.

rootloops.sh only produces dark schemes, so the light variant is generated here:
same hues, lightness/saturation reworked to read as dark-on-light. Output is
rootloops/palette-light.env, which you can hand-tweak afterwards - apply.sh will
not overwrite it if it already exists (delete it to regenerate).
"""
import colorsys
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent


def load(path):
    out = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def to_hls(hexstr):
    h = hexstr.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return colorsys.rgb_to_hls(r, g, b)  # (h, l, s)


def from_hls(hue, light, sat):
    r, g, b = colorsys.hls_to_rgb(hue, max(0, min(1, light)), max(0, min(1, sat)))
    return "{:02x}{:02x}{:02x}".format(round(r * 255), round(g * 255), round(b * 255))


def main():
    dark = load(HERE / "palette.env")
    out = HERE / "palette-light.env"
    if out.exists():
        print(f"{out.name} already exists - leaving it alone")
        return 0

    def relight(key, light, sat_floor=0.0):
        hue, _, s = to_hls(dark[key])
        return from_hls(hue, light, max(s, sat_floor))

    lines = [
        "# LIGHT Root Loops palette - derived from palette.env by derive-light.py.",
        "# Same hues, reworked for a light background. Hand-tweak freely; delete",
        "# this file and re-run apply.sh to regenerate.",
        "",
        f"RL_BG={from_hls(to_hls(dark['RL_BG'])[0], 0.965, 0.30)}",
        f"RL_FG={from_hls(to_hls(dark['RL_FG'])[0], 0.20, 0.25)}",
        "",
    ]
    # normal colors: darker + saturated so they carry on white
    plan = {
        "RL_COLOR0": (0.22, 0.10), "RL_COLOR7": (0.42, 0.15),
        "RL_COLOR8": (0.55, 0.12), "RL_COLOR15": (0.28, 0.10),
    }
    for i in (1, 2, 3, 4, 5, 6):
        plan[f"RL_COLOR{i}"] = (0.42, 0.55)
    for i in (9, 10, 11, 12, 13, 14):
        plan[f"RL_COLOR{i}"] = (0.52, 0.50)
    for i in range(16):
        k = f"RL_COLOR{i}"
        light, floor = plan[k]
        lines.append(f"{k}={relight(k, light, floor)}")

    out.write_text("\n".join(lines) + "\n")
    print(f"wrote {out.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
