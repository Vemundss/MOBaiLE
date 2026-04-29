#!/usr/bin/env python3

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


COPY = {
    "01-configured-empty": {
        "headline": "Run your own\ncomputer from iPhone",
        "body": "Pair your Mac or Linux machine once, then start the next repo or terminal task from the phone.",
    },
    "02-live-conversation": {
        "headline": "Watch the run\nstay readable",
        "body": "Progress, results, and follow-up stay together in one live thread.",
    },
    "03-voice-recording": {
        "headline": "Use voice when\ntyping is awkward",
        "body": "Dictate the next task, review the transcript, and keep voice mode attached to the current chat.",
    },
    "04-settings": {
        "headline": "See access and\ncontext clearly",
        "body": "Connection, executor, profile instructions, and memory controls stay explicit in settings.",
    },
    "05-threads": {
        "headline": "Keep work split\nby thread",
        "body": "Switch between workspace chats without losing the next step.",
    },
}

FALLBACK_SCREENSHOT_SIZES = {
    (1320, 2868): (1290, 2796),
    (2868, 1320): (2796, 1290),
}


def font(size: int, bold: bool = False):
    candidates = []
    if bold:
        candidates.extend(
            [
                "/System/Library/Fonts/Supplemental/ArialHB.ttc",
                "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
                "/System/Library/Fonts/Supplemental/Arial Black.ttf",
                "/System/Library/Fonts/SFNS.ttf",
            ]
        )
    else:
        candidates.extend(
            [
                "/System/Library/Fonts/SFNS.ttf",
                "/System/Library/Fonts/Helvetica.ttc",
                "/System/Library/Fonts/Supplemental/Arial.ttf",
            ]
        )

    for candidate in candidates:
        path = Path(candidate)
        if path.exists():
            return ImageFont.truetype(str(path), size=size)
    return ImageFont.load_default()


def wrap(draw: ImageDraw.ImageDraw, text: str, max_width: int, style) -> str:
    lines = []
    for paragraph in text.splitlines():
        words = paragraph.split()
        current: list[str] = []
        for word in words:
            trial = " ".join(current + [word]) if current else word
            box = draw.textbbox((0, 0), trial, font=style)
            if box[2] <= max_width:
                current.append(word)
            else:
                if current:
                    lines.append(" ".join(current))
                current = [word]
        if current:
            lines.append(" ".join(current))
    return "\n".join(lines)


def rounded_shadow(size: tuple[int, int], radius: int) -> Image.Image:
    shadow = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(shadow)
    draw.rounded_rectangle((0, 0, size[0], size[1]), radius=radius, fill=(0, 12, 24, 165))
    return shadow.filter(ImageFilter.GaussianBlur(24))


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size[0], size[1]), radius=radius, fill=255)
    return mask


def vertical_gradient(size: tuple[int, int], top: str, bottom: str) -> Image.Image:
    top_rgb = Image.new("RGB", (1, 1), top).getpixel((0, 0))
    bottom_rgb = Image.new("RGB", (1, 1), bottom).getpixel((0, 0))
    width, height = size
    image = Image.new("RGBA", size)
    draw = ImageDraw.Draw(image)
    for y in range(height):
        ratio = y / max(1, height - 1)
        color = tuple(int(top_rgb[i] * (1 - ratio) + bottom_rgb[i] * ratio) for i in range(3))
        draw.line((0, y, width, y), fill=color + (255,))
    return image


def draw_background(draw: ImageDraw.ImageDraw, width: int, height: int) -> None:
    draw.rounded_rectangle(
        (44, 44, width - 44, height - 44),
        radius=58,
        outline="#2A5665",
        width=2,
    )
    draw.polygon(
        [(int(width * 0.78), 0), (width, 0), (width, int(height * 0.24)), (int(width * 0.88), int(height * 0.18))],
        fill="#0E746A",
    )
    draw.polygon(
        [(0, int(height * 0.82)), (int(width * 0.26), height), (0, height)],
        fill="#1268D3",
    )
    for x in range(116, width, 120):
        draw.line((x, int(height * 0.58), x + 220, height), fill="#123243", width=2)


def compose(source: Path, destination: Path) -> None:
    slug = source.stem.split("-iphone-")[0]
    copy = COPY[slug]

    raw = Image.open(source).convert("RGBA")
    width, height = raw.size

    canvas = vertical_gradient((width, height), "#081522", "#0E3D49")
    draw = ImageDraw.Draw(canvas)
    draw_background(draw, width, height)

    badge_font = font(max(28, width // 32), bold=True)
    title_font = font(max(86, width // 13), bold=True)
    body_font = font(max(36, width // 32))

    badge_x = 78
    badge_y = 84
    badge_w = max(220, width // 4)
    badge_h = max(58, height // 30)
    draw.rounded_rectangle(
        (badge_x, badge_y, badge_x + badge_w, badge_y + badge_h),
        radius=999,
        fill="#DDF4ED",
    )
    draw.ellipse(
        (badge_x + 22, badge_y + 18, badge_x + 46, badge_y + 42),
        fill="#0D9488",
    )
    draw.text((badge_x + 62, badge_y + 13), "MOBaiLE", font=badge_font, fill="#073C35")

    wrapped_title = wrap(draw, copy["headline"], width - 156, title_font)
    title_y = 188
    draw.multiline_text((78, title_y), wrapped_title, font=title_font, fill="#F7FBFF", spacing=10)
    title_box = draw.multiline_textbbox((78, title_y), wrapped_title, font=title_font, spacing=10)

    wrapped_body = wrap(draw, copy["body"], width - 190, body_font)
    body_y = title_box[3] + 26
    draw.multiline_text((80, body_y), wrapped_body, font=body_font, fill="#C9D8DC", spacing=9)

    target_width_ratio = 0.66 if slug == "04-settings" else 0.72
    target_width = int(width * target_width_ratio)
    target_height = int(raw.size[1] * (target_width / raw.size[0]))
    screenshot = raw.resize((target_width, target_height), Image.Resampling.LANCZOS)

    screen_x = (width - screenshot.width) // 2
    bottom_margin = 118 if slug == "04-settings" else 88
    screen_y = height - screenshot.height - bottom_margin

    canvas.alpha_composite(rounded_shadow(screenshot.size, 52), dest=(screen_x, screen_y + 28))
    panel = Image.new("RGBA", screenshot.size, (255, 255, 255, 255))
    canvas.alpha_composite(panel, dest=(screen_x, screen_y))
    mask = rounded_mask(screenshot.size, 52)
    canvas.paste(screenshot, (screen_x, screen_y), mask)

    highlight_y = screen_y - 26
    draw.rounded_rectangle(
        (screen_x + 34, highlight_y, screen_x + screenshot.width - 34, highlight_y + 10),
        radius=999,
        fill="#3CDBBE",
    )

    normalized_size = FALLBACK_SCREENSHOT_SIZES.get(canvas.size)
    if normalized_size is not None:
        canvas = canvas.resize(normalized_size, Image.Resampling.LANCZOS)

    destination.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(destination, optimize=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Render marketing App Store screenshots from raw simulator captures.")
    parser.add_argument("--input-dir", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    input_dir = Path(args.input_dir)
    output_dir = Path(args.output_dir)

    for source in sorted(input_dir.glob("*.png")):
        compose(source, output_dir / source.name)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
