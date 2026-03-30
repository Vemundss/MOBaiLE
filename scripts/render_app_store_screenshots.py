#!/usr/bin/env python3

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


COPY = {
    "01-configured-empty": {
        "headline": "Your computer,\nin your pocket",
        "body": "Start a task from iPhone and keep every run anchored to your own machine.",
    },
    "02-live-conversation": {
        "headline": "Watch every run\nstream live",
        "body": "Progress, summaries, and the next step stay in one thread instead of disappearing into a black box.",
    },
    "03-voice-recording": {
        "headline": "Capture voice tasks\nhands-free",
        "body": "Record, review, and send with inline attachments, haptics, and auto-send after silence.",
    },
    "04-settings": {
        "headline": "Dial in the setup\nonce, then move",
        "body": "Connection, voice, and support controls stay in one native settings sheet.",
    },
    "05-threads": {
        "headline": "Keep work ready\nacross threads",
        "body": "Jump between active conversations without losing workspace context or the next follow-up.",
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
                "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
                "/System/Library/Fonts/Supplemental/Arial Black.ttf",
                "/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf",
            ]
        )
    else:
        candidates.extend(
            [
                "/System/Library/Fonts/Supplemental/Arial.ttf",
                "/System/Library/Fonts/Supplemental/Arial Narrow.ttf",
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
    draw.rounded_rectangle((0, 0, size[0], size[1]), radius=radius, fill=(45, 36, 28, 190))
    return shadow.filter(ImageFilter.GaussianBlur(18))


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size[0], size[1]), radius=radius, fill=255)
    return mask


def compose(source: Path, destination: Path) -> None:
    slug = source.stem.split("-iphone-")[0]
    copy = COPY[slug]

    raw = Image.open(source).convert("RGBA")
    width, height = raw.size

    canvas = Image.new("RGBA", (width, height), "#F6F0E7")
    draw = ImageDraw.Draw(canvas)

    draw.rectangle((0, 0, width, height), fill="#F6F0E7")
    draw.ellipse((-200, -120, width // 2, height // 3), fill="#F0D9BA")
    draw.ellipse((width // 2, -120, width + 180, height // 3), fill="#DDEAE4")
    draw.rounded_rectangle((48, 48, width - 48, height - 48), radius=58, fill="#FBF8F3", outline="#E8DDCC", width=2)

    badge_font = font(max(34, width // 24), bold=True)
    title_font = font(max(122, width // 10), bold=True)
    body_font = font(max(42, width // 26))

    badge_x = 88
    badge_y = 94
    badge_w = max(200, width // 5)
    badge_h = max(58, height // 24)
    draw.rounded_rectangle((badge_x, badge_y, badge_x + badge_w, badge_y + badge_h), radius=999, fill="#DDEDE6")
    draw.text((badge_x + 28, badge_y + 16), "MOBaiLE", font=badge_font, fill="#0D4F42")

    wrapped_title = wrap(draw, copy["headline"], width - 180, title_font)
    draw.multiline_text((88, 190), wrapped_title, font=title_font, fill="#1F1915", spacing=2)
    title_box = draw.multiline_textbbox((88, 190), wrapped_title, font=title_font, spacing=2)

    wrapped_body = wrap(draw, copy["body"], width - 220, body_font)
    body_y = title_box[3] + 28
    draw.multiline_text((88, body_y), wrapped_body, font=body_font, fill="#665B50", spacing=8)

    target_width = int(width * 0.68)
    target_height = int(raw.size[1] * (target_width / raw.size[0]))
    screenshot = raw.resize((target_width, target_height), Image.Resampling.LANCZOS)

    screen_x = (width - screenshot.width) // 2
    screen_y = height - screenshot.height - 86

    canvas.alpha_composite(rounded_shadow(screenshot.size, 46), dest=(screen_x, screen_y + 24))
    panel = Image.new("RGBA", screenshot.size, (255, 255, 255, 255))
    canvas.alpha_composite(panel, dest=(screen_x, screen_y))
    mask = rounded_mask(screenshot.size, 46)
    canvas.paste(screenshot, (screen_x, screen_y), mask)

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
