#!/usr/bin/env python3

from __future__ import annotations

from pathlib import Path
from typing import Iterable

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps


ROOT = Path(__file__).resolve().parent.parent
DOCS_DIR = ROOT / "docs"
SCREEN_DIR = DOCS_DIR / "readme-screens"

HERO_PATH = DOCS_DIR / "readme-hero.png"
SHOWCASE_PATH = DOCS_DIR / "readme-showcase.png"

CONFIGURED_SCREEN = SCREEN_DIR / "configured-empty.png"
CONVERSATION_SCREEN = SCREEN_DIR / "conversation.png"
RECORDING_SCREEN = SCREEN_DIR / "recording.png"


def load_font(paths: Iterable[str], size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    for path in paths:
        font_path = Path(path)
        if font_path.exists():
            try:
                return ImageFont.truetype(str(font_path), size)
            except OSError:
                continue
    return ImageFont.load_default()


FONT_BODY = [
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
]
FONT_BOLD = [
    "/System/Library/Fonts/Supplemental/ArialHB.ttc",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
]
FONT_ROUNDED = [
    "/System/Library/Fonts/SFNSRounded.ttf",
    "/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf",
]


def gradient_canvas(size: tuple[int, int], start: tuple[int, int, int], end: tuple[int, int, int]) -> Image.Image:
    width, height = size
    canvas = Image.new("RGBA", size)
    draw = ImageDraw.Draw(canvas)
    for y in range(height):
        ratio = y / max(1, height - 1)
        color = tuple(int(start[i] * (1 - ratio) + end[i] * ratio) for i in range(3)) + (255,)
        draw.line((0, y, width, y), fill=color)
    return canvas


def add_blur_blob(
    image: Image.Image,
    box: tuple[int, int, int, int],
    color: tuple[int, int, int],
    alpha: int,
    blur: int,
) -> None:
    overlay = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    draw.ellipse(box, fill=color + (alpha,))
    overlay = overlay.filter(ImageFilter.GaussianBlur(blur))
    image.alpha_composite(overlay)


def wrap_text(
    draw: ImageDraw.ImageDraw,
    text: str,
    font: ImageFont.ImageFont,
    max_width: int,
) -> list[str]:
    words = text.split()
    if not words:
        return []

    lines: list[str] = []
    current = words[0]
    for word in words[1:]:
        trial = f"{current} {word}"
        if draw.textlength(trial, font=font) <= max_width:
            current = trial
        else:
            lines.append(current)
            current = word
    lines.append(current)
    return lines


def draw_wrapped_text(
    draw: ImageDraw.ImageDraw,
    text: str,
    position: tuple[int, int],
    font: ImageFont.ImageFont,
    fill: tuple[int, int, int],
    max_width: int,
    line_spacing: int,
) -> int:
    lines = wrap_text(draw, text, font, max_width)
    x, y = position
    for line in lines:
        draw.text((x, y), line, font=font, fill=fill)
        bbox = draw.textbbox((x, y), line, font=font)
        y = bbox[3] + line_spacing
    return y


def paste_shadowed_panel(
    canvas: Image.Image,
    panel: Image.Image,
    center: tuple[int, int],
    angle: float = 0,
    shadow_alpha: float = 0.28,
    shadow_blur: int = 26,
    shadow_offset: tuple[int, int] = (0, 24),
) -> None:
    rotated = panel.rotate(angle, resample=Image.Resampling.BICUBIC, expand=True)
    alpha = rotated.getchannel("A")
    shadow = Image.new("RGBA", rotated.size, (18, 24, 38, 0))
    shadow.putalpha(alpha.point(lambda value: int(value * shadow_alpha)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(shadow_blur))

    x = int(center[0] - rotated.width / 2)
    y = int(center[1] - rotated.height / 2)
    canvas.alpha_composite(shadow, (x + shadow_offset[0], y + shadow_offset[1]))
    canvas.alpha_composite(rotated, (x, y))


def build_screen_panel(
    source: Image.Image,
    panel_size: tuple[int, int],
    background: tuple[int, int, int] = (255, 255, 255),
    frame: int = 14,
    radius: int = 42,
) -> Image.Image:
    width, height = panel_size
    panel = Image.new("RGBA", panel_size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(panel)
    draw.rounded_rectangle(
        (0, 0, width - 1, height - 1),
        radius=radius,
        fill=background + (255,),
        outline=(255, 255, 255, 215),
        width=2,
    )

    inner_width = width - frame * 2
    inner_height = height - frame * 2
    shot = ImageOps.fit(source, (inner_width, inner_height), method=Image.Resampling.LANCZOS)
    mask = Image.new("L", (inner_width, inner_height), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle(
        (0, 0, inner_width, inner_height),
        radius=max(16, radius - frame),
        fill=255,
    )
    panel.paste(shot, (frame, frame), mask)
    return panel


def draw_pill(
    draw: ImageDraw.ImageDraw,
    text: str,
    position: tuple[int, int],
    font: ImageFont.ImageFont,
    fill: tuple[int, int, int],
    background: tuple[int, int, int],
    padding_x: int = 20,
    padding_y: int = 12,
) -> tuple[int, int, int, int]:
    bbox = draw.textbbox((0, 0), text, font=font)
    width = bbox[2] - bbox[0]
    height = bbox[3] - bbox[1]
    x, y = position
    rect = (x, y, x + width + padding_x * 2, y + height + padding_y * 2)
    draw.rounded_rectangle(rect, radius=(rect[3] - rect[1]) // 2, fill=background)
    draw.text((x + padding_x, y + padding_y - 1), text, font=font, fill=fill)
    return rect


def create_hero() -> None:
    canvas = gradient_canvas((1600, 900), (252, 245, 238), (238, 247, 243))
    add_blur_blob(canvas, (1050, 40, 1490, 430), (219, 240, 231), 180, 32)
    add_blur_blob(canvas, (1060, 450, 1540, 910), (243, 231, 206), 120, 44)
    add_blur_blob(canvas, (-40, 540, 320, 900), (255, 221, 186), 110, 36)

    draw = ImageDraw.Draw(canvas)
    badge_font = load_font(FONT_ROUNDED, 28)
    title_font = load_font(FONT_BOLD, 84)
    body_font = load_font(FONT_BODY, 31)
    pill_font = load_font(FONT_BODY, 24)
    note_font = load_font(FONT_BODY, 23)

    draw_pill(
        draw,
        "MOBaiLE",
        (120, 110),
        badge_font,
        fill=(35, 90, 73),
        background=(221, 240, 231),
    )

    title = "Your own computer,\nin your pocket."
    draw.multiline_text(
        (120, 190),
        title,
        font=title_font,
        fill=(26, 28, 33),
        spacing=4,
    )

    body = (
        "Send a task from iPhone, run it on your Mac or Linux machine, "
        "and keep the whole execution thread visible while you're away from the keyboard."
    )
    next_y = draw_wrapped_text(
        draw,
        body,
        (120, 410),
        body_font,
        fill=(82, 88, 95),
        max_width=620,
        line_spacing=10,
    )

    pill_y = next_y + 26
    pill_rect = draw_pill(
        draw,
        "Voice and text",
        (120, pill_y),
        pill_font,
        fill=(15, 87, 177),
        background=(226, 240, 255),
    )
    pill_rect = draw_pill(
        draw,
        "Runs on your machine",
        (pill_rect[2] + 12, pill_y),
        pill_font,
        fill=(35, 90, 73),
        background=(221, 240, 231),
    )
    draw_pill(
        draw,
        "Live run stream",
        (pill_rect[2] + 12, pill_y),
        pill_font,
        fill=(120, 84, 16),
        background=(249, 236, 207),
    )

    note = "Pair once, stay in context, and keep every follow-up in the same thread."
    draw_wrapped_text(
        draw,
        note,
        (120, pill_y + 94),
        note_font,
        fill=(101, 105, 111),
        max_width=620,
        line_spacing=8,
    )

    configured = Image.open(CONFIGURED_SCREEN).convert("RGBA")
    conversation = Image.open(CONVERSATION_SCREEN).convert("RGBA")
    recording = Image.open(RECORDING_SCREEN).convert("RGBA")

    left_panel = build_screen_panel(recording, (280, 610), background=(248, 250, 252))
    center_panel = build_screen_panel(configured, (340, 730))
    right_panel = build_screen_panel(conversation, (290, 620), background=(250, 249, 246))

    paste_shadowed_panel(canvas, left_panel, center=(990, 560), angle=-8)
    paste_shadowed_panel(canvas, right_panel, center=(1360, 430), angle=8)
    paste_shadowed_panel(canvas, center_panel, center=(1175, 485), angle=0, shadow_blur=30)

    canvas.save(HERO_PATH, optimize=True)


def draw_feature_card(
    canvas: Image.Image,
    box: tuple[int, int, int, int],
    label: str,
    title: str,
    body: str,
    screen: Image.Image,
    tint: tuple[int, int, int],
) -> None:
    x0, y0, x1, y1 = box
    radius = 38
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle(
        (x0, y0 + 18, x1, y1 + 18),
        radius=radius,
        fill=(19, 26, 38, 52),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(26))
    canvas.alpha_composite(shadow)

    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle(box, radius=radius, fill=(255, 255, 255, 245), outline=(255, 255, 255, 225), width=2)

    label_font = load_font(FONT_BODY, 18)
    title_font = load_font(FONT_BOLD, 28)
    body_font = load_font(FONT_BODY, 20)

    label_rect = draw_pill(
        draw,
        label,
        (x0 + 28, y0 + 26),
        label_font,
        fill=tint,
        background=tuple(int(channel * 0.18 + 255 * 0.82) for channel in tint),
        padding_x=16,
        padding_y=9,
    )

    title_y = label_rect[3] + 22
    draw.text((x0 + 28, title_y), title, font=title_font, fill=(30, 32, 37))
    body_end_y = draw_wrapped_text(
        draw,
        body,
        (x0 + 28, title_y + 46),
        body_font,
        fill=(94, 98, 104),
        max_width=(x1 - x0) - 56,
        line_spacing=8,
    )

    panel = build_screen_panel(screen, (214, 368), background=(248, 249, 252))
    paste_shadowed_panel(
        canvas,
        panel,
        center=(x0 + (x1 - x0) // 2, max(body_end_y + 120, y0 + 360)),
        angle=0,
        shadow_blur=18,
        shadow_offset=(0, 14),
    )


def create_showcase() -> None:
    canvas = gradient_canvas((1600, 920), (248, 244, 238), (246, 250, 249))
    add_blur_blob(canvas, (70, 80, 420, 430), (251, 228, 194), 120, 26)
    add_blur_blob(canvas, (1180, 40, 1550, 360), (221, 239, 231), 140, 28)

    draw = ImageDraw.Draw(canvas)
    eyebrow_font = load_font(FONT_ROUNDED, 24)
    title_font = load_font(FONT_BOLD, 58)
    body_font = load_font(FONT_BODY, 28)

    draw_pill(
        draw,
        "Product tour",
        (90, 72),
        eyebrow_font,
        fill=(35, 90, 73),
        background=(221, 240, 231),
        padding_x=18,
        padding_y=10,
    )
    draw.text((90, 140), "Three moments that matter", font=title_font, fill=(28, 30, 35))
    draw_wrapped_text(
        draw,
        "The product experience needs to feel legible at a glance: getting oriented, following a run, and sending a voice task without losing context.",
        (90, 212),
        body_font,
        fill=(97, 101, 106),
        max_width=1180,
        line_spacing=10,
    )

    configured = Image.open(CONFIGURED_SCREEN).convert("RGBA")
    conversation = Image.open(CONVERSATION_SCREEN).convert("RGBA")
    recording = Image.open(RECORDING_SCREEN).convert("RGBA")

    card_top = 300
    card_height = 560
    card_width = 440
    gap = 50
    left = 90

    cards = [
        (
            "Get oriented",
            "Start in the right workspace",
            "Open to a thread that already shows the runtime, workspace, chat switcher, and composer.",
            configured,
            (49, 121, 242),
        ),
        (
            "Stay in the loop",
            "Follow the run live",
            "Prompts, summaries, and the next recommended action stay together so follow-up work feels immediate.",
            conversation,
            (43, 150, 98),
        ),
        (
            "Go hands-free",
            "Keep talking after each reply",
            "Voice mode keeps typed context, attachments, and silence-based send behavior visible right where the action happens.",
            recording,
            (34, 113, 214),
        ),
    ]

    for index, card in enumerate(cards):
        x0 = left + index * (card_width + gap)
        draw_feature_card(
            canvas,
            (x0, card_top, x0 + card_width, card_top + card_height),
            *card,
        )

    canvas.save(SHOWCASE_PATH, optimize=True)


def main() -> None:
    DOCS_DIR.mkdir(parents=True, exist_ok=True)
    create_hero()
    create_showcase()
    print(f"Wrote {HERO_PATH.relative_to(ROOT)}")
    print(f"Wrote {SHOWCASE_PATH.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
