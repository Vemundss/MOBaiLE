#!/usr/bin/env python3

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parent.parent
ICON_DIR = ROOT / "ios" / "VoiceAgentApp" / "Assets.xcassets" / "AppIcon.appiconset"
LOGO_PATH = ROOT / "ios" / "VoiceAgentApp" / "mobaile_logo.png"


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


def rounded_shadow(size: int, box: tuple[int, int, int, int], radius: int, alpha: int, blur: int) -> Image.Image:
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(shadow)
    draw.rounded_rectangle(box, radius=radius, fill=(0, 15, 28, alpha))
    return shadow.filter(ImageFilter.GaussianBlur(blur))


def draw_master(size: int = 2048) -> Image.Image:
    scale = size / 1024

    def s(value: int) -> int:
        return int(round(value * scale))

    image = gradient(size, "#071525", "#0E766C")
    draw = ImageDraw.Draw(image)

    draw.polygon(
        [(s(640), 0), (size, 0), (size, s(270)), (s(756), s(206))],
        fill=rgb("#24C6A8") + (70,),
    )
    draw.polygon(
        [(0, s(750)), (s(330), size), (0, size)],
        fill=rgb("#1B73E8") + (62,),
    )

    connector = [(s(276), s(642)), (s(380), s(724)), (s(586), s(720)), (s(676), s(610))]
    draw.line(connector, fill=rgb("#7EE7D3") + (160,), width=s(28), joint="curve")

    host_box = (s(164), s(246), s(802), s(690))
    image.alpha_composite(rounded_shadow(size, (host_box[0], host_box[1] + s(26), host_box[2], host_box[3] + s(26)), s(58), 135, s(30)))
    draw.rounded_rectangle(host_box, radius=s(58), fill=rgb("#F8FCFF"), outline=rgb("#FFFFFF"), width=s(3))
    draw.rounded_rectangle(
        (host_box[0], host_box[1], host_box[2], s(356)),
        radius=s(58),
        fill=rgb("#102436"),
    )
    draw.rectangle((host_box[0], s(316), host_box[2], s(356)), fill=rgb("#102436"))
    for index, color in enumerate(("#FF6B6B", "#FFD166", "#2ED47A")):
        cx = s(228 + index * 44)
        draw.ellipse((cx - s(13), s(289) - s(13), cx + s(13), s(289) + s(13)), fill=rgb(color))

    draw.line((s(250), s(448), s(302), s(486), s(250), s(524)), fill=rgb("#1268D3"), width=s(30), joint="curve")
    for y, width in ((s(440), 314), (s(508), 390), (s(578), 280)):
        draw.rounded_rectangle((s(346), y, s(346 + width), y + s(30)), radius=s(15), fill=rgb("#203040"))

    phone_box = (s(588), s(430), s(830), s(828))
    image.alpha_composite(rounded_shadow(size, (phone_box[0], phone_box[1] + s(18), phone_box[2], phone_box[3] + s(18)), s(54), 125, s(24)))
    draw.rounded_rectangle(phone_box, radius=s(54), fill=rgb("#F7FBFF"), outline=rgb("#E3EEF5"), width=s(4))
    screen_box = (s(626), s(486), s(792), s(744))
    draw.rounded_rectangle(screen_box, radius=s(34), fill=rgb("#0F2233"))
    draw.rounded_rectangle((s(674), s(454), s(744), s(468)), radius=s(7), fill=rgb("#CAD8DF"))

    draw.rounded_rectangle((s(658), s(542), s(760), s(568)), radius=s(13), fill=rgb("#2CDDBE"))
    draw.rounded_rectangle((s(658), s(600), s(730), s(626)), radius=s(13), fill=rgb("#DCEBFF"))
    draw.rounded_rectangle((s(658), s(656), s(760), s(682)), radius=s(13), fill=rgb("#DCEBFF"))

    mic_center = (s(710), s(782))
    draw.ellipse(
        (
            mic_center[0] - s(54),
            mic_center[1] - s(54),
            mic_center[0] + s(54),
            mic_center[1] + s(54),
        ),
        fill=rgb("#1268D3"),
    )
    draw.rounded_rectangle(
        (mic_center[0] - s(11), mic_center[1] - s(30), mic_center[0] + s(11), mic_center[1] + s(16)),
        radius=s(11),
        fill=rgb("#FFFFFF"),
    )
    draw.arc(
        (mic_center[0] - s(28), mic_center[1] - s(6), mic_center[0] + s(28), mic_center[1] + s(46)),
        20,
        160,
        fill=rgb("#FFFFFF"),
        width=s(8),
    )
    draw.line((mic_center[0], mic_center[1] + s(26), mic_center[0], mic_center[1] + s(44)), fill=rgb("#FFFFFF"), width=s(8))

    return image.convert("RGB")


def icon_size(entry: dict[str, str]) -> int:
    point_size = float(entry["size"].replace("x20", "").split("x")[0])
    scale = int(entry["scale"].replace("x", ""))
    return int(round(point_size * scale))


def main() -> None:
    master = draw_master()
    ICON_DIR.mkdir(parents=True, exist_ok=True)

    contents = json.loads((ICON_DIR / "Contents.json").read_text())
    for entry in contents["images"]:
        filename = entry["filename"]
        size = icon_size(entry)
        output = master.resize((size, size), Image.Resampling.LANCZOS)
        output.save(ICON_DIR / filename, optimize=True)

    master.resize((256, 256), Image.Resampling.LANCZOS).save(LOGO_PATH, optimize=True)
    print(f"Wrote {ICON_DIR.relative_to(ROOT)}")
    print(f"Wrote {LOGO_PATH.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
