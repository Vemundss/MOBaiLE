#!/usr/bin/env python3

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageOps


ROOT = Path(__file__).resolve().parent.parent
ICON_DIR = ROOT / "ios" / "VoiceAgentApp" / "Assets.xcassets" / "AppIcon.appiconset"
LOGO_PATH = ROOT / "ios" / "VoiceAgentApp" / "mobaile_logo.png"
SOURCE_LOGO_PATH = ROOT / "logo" / "02-cheeky-side-eye-bot.png"
SOURCE_BACKGROUND_TOP = "#F7EFFF"
SOURCE_BACKGROUND_BOTTOM = "#FFD4B9"


def rgb(hex_color: str) -> tuple[int, int, int]:
    value = hex_color.lstrip("#")
    return tuple(int(value[index : index + 2], 16) for index in (0, 2, 4))


def gradient(size: int, top: str, bottom: str) -> Image.Image:
    top_rgb = rgb(top)
    bottom_rgb = rgb(bottom)
    image = Image.new("RGB", (size, size))
    draw = ImageDraw.Draw(image)
    for y in range(size):
        ratio = y / max(1, size - 1)
        color = tuple(int(top_rgb[i] * (1 - ratio) + bottom_rgb[i] * ratio) for i in range(3))
        draw.line((0, y, size, y), fill=color)
    return image.convert("RGBA")


def load_source_logo(size: int = 1024) -> Image.Image:
    logo = Image.open(SOURCE_LOGO_PATH).convert("RGBA")
    return ImageOps.fit(logo, (size, size), method=Image.Resampling.LANCZOS)


def flatten_for_app_icon(logo: Image.Image) -> Image.Image:
    background = gradient(logo.width, SOURCE_BACKGROUND_TOP, SOURCE_BACKGROUND_BOTTOM)
    background.alpha_composite(logo)
    return background.convert("RGB")


def icon_size(entry: dict[str, str]) -> int:
    point_size = float(entry["size"].replace("x20", "").split("x")[0])
    scale = int(entry["scale"].replace("x", ""))
    return int(round(point_size * scale))


def main() -> None:
    master = load_source_logo()
    app_icon_master = flatten_for_app_icon(master)
    ICON_DIR.mkdir(parents=True, exist_ok=True)

    contents = json.loads((ICON_DIR / "Contents.json").read_text())
    for entry in contents["images"]:
        filename = entry["filename"]
        size = icon_size(entry)
        output = app_icon_master.resize((size, size), Image.Resampling.LANCZOS)
        output.save(ICON_DIR / filename, optimize=True)

    master.resize((256, 256), Image.Resampling.LANCZOS).save(LOGO_PATH, optimize=True)
    print(f"Read {SOURCE_LOGO_PATH.relative_to(ROOT)}")
    print(f"Wrote {ICON_DIR.relative_to(ROOT)}")
    print(f"Wrote {LOGO_PATH.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
