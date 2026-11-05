#!/usr/bin/env python3
"""Renders the HalfTank app icon into the asset catalog.

The mark is a gauge ring whose lower half is filled with liquid: the product
shows remaining quota as a ring, and the name says the tank is only half full.
Everything is drawn at four times the target size and downsampled, because the
16-point slot has to stay readable and plain arcs alias badly otherwise.

Usage: python3 Scripts/generate_app_icon.py [--output <appiconset directory>]
Requires Pillow.
"""

import argparse
import os
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SUPERSAMPLE = 4
SCALE = SIZE * SUPERSAMPLE

INSET = int(0.095 * SCALE)
RADIUS = int(0.225 * SCALE)
TILE_TOP = (36, 47, 82)
TILE_BOTTOM = (10, 14, 27)
RIM = (238, 248, 255, 246)
LIQUID_LEFT = (86, 240, 186)
LIQUID_RIGHT = (50, 158, 255)
DISC_RATIO = 0.272
RIM_WIDTH_RATIO = 0.034

# Every slot the asset catalog asks for; each file is the largest variant of its size.
OUTPUTS = {
    "AppIcon-16.png": 16,
    "AppIcon-32.png": 32,
    "AppIcon-64.png": 64,
    "AppIcon-128.png": 128,
    "AppIcon-256.png": 256,
    "AppIcon-512.png": 512,
    "AppIcon-1024.png": 1024,
}


def lerp(start, end, t):
    return tuple(round(a + (b - a) * t) for a, b in zip(start, end))


def vertical_gradient(size, top, bottom):
    column = Image.new("RGB", (1, size))
    draw = ImageDraw.Draw(column)
    for y in range(size):
        draw.point((0, y), fill=lerp(top, bottom, y / max(1, size - 1)))
    return column.resize((size, size))


def render():
    canvas = Image.new("RGBA", (SCALE, SCALE), (0, 0, 0, 0))

    tile = vertical_gradient(SCALE, TILE_TOP, TILE_BOTTOM).convert("RGBA")
    mask = Image.new("L", (SCALE, SCALE), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [INSET, INSET, SCALE - INSET, SCALE - INSET], radius=RADIUS, fill=255
    )
    canvas.paste(tile, (0, 0), mask)

    # A faint light from above keeps the tile from reading as a flat block.
    glow = Image.new("RGBA", (SCALE, SCALE), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse(
        [INSET * 0.2, -SCALE * 0.34, SCALE - INSET * 0.2, SCALE * 0.40],
        fill=(120, 170, 255, 42),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(SCALE * 0.10))
    empty = Image.new("RGBA", (SCALE, SCALE), (0, 0, 0, 0))
    canvas = Image.alpha_composite(canvas, Image.composite(glow, empty, mask))

    center = (SCALE / 2, SCALE / 2)
    disc_r = SCALE * DISC_RATIO
    rim_w = int(SCALE * RIM_WIDTH_RATIO)
    bounds = [center[0] - disc_r, center[1] - disc_r, center[0] + disc_r, center[1] + disc_r]
    inner_bounds = [
        center[0] - disc_r + rim_w / 2, center[1] - disc_r + rim_w / 2,
        center[0] + disc_r - rim_w / 2, center[1] + disc_r - rim_w / 2,
    ]

    inner = Image.new("L", (SCALE, SCALE), 0)
    ImageDraw.Draw(inner).ellipse(inner_bounds, fill=255)

    # Liquid: the lower half of the disc, lit from the left.
    liquid = Image.new("L", (SCALE, SCALE), 0)
    ImageDraw.Draw(liquid).pieslice(bounds, 0, 180, fill=255)

    ramp = Image.new("RGBA", (SCALE, SCALE))
    ramp_draw = ImageDraw.Draw(ramp)
    for x in range(0, SCALE, 2):
        ramp_draw.rectangle(
            [x, 0, x + 2, SCALE], fill=(*lerp(LIQUID_LEFT, LIQUID_RIGHT, x / SCALE), 255)
        )

    gauge = Image.composite(ramp, Image.new("RGBA", (SCALE, SCALE), (0, 0, 0, 0)), liquid)
    gauge = Image.composite(gauge, Image.new("RGBA", (SCALE, SCALE), (0, 0, 0, 0)), inner)

    # Shade just below the surface so the level reads as depth, not paint.
    shade = Image.new("RGBA", (SCALE, SCALE), (0, 0, 0, 0))
    shade_draw = ImageDraw.Draw(shade)
    band = int(SCALE * 0.030)
    for i in range(band):
        alpha = int(34 * (1 - i / band) ** 1.8)
        shade_draw.line([(0, center[1] + i), (SCALE, center[1] + i)], fill=(6, 22, 44, alpha))
    shade = Image.composite(shade, Image.new("RGBA", (SCALE, SCALE), (0, 0, 0, 0)), inner)
    gauge = Image.alpha_composite(shade, gauge)

    sheen = Image.new("RGBA", (SCALE, SCALE), (0, 0, 0, 0))
    ImageDraw.Draw(sheen).ellipse(
        [
            center[0] - disc_r * 1.05, center[1] + disc_r * 0.18,
            center[0] + disc_r * 0.15, center[1] + disc_r * 1.25,
        ],
        fill=(255, 255, 255, 18),
    )
    sheen = sheen.filter(ImageFilter.GaussianBlur(SCALE * 0.045))
    sheen = Image.composite(sheen, Image.new("RGBA", (SCALE, SCALE), (0, 0, 0, 0)), inner)
    gauge = Image.alpha_composite(gauge, sheen)

    # The rim is a full circle so the empty half still reads as a container.
    rim = Image.new("RGBA", (SCALE, SCALE), (0, 0, 0, 0))
    ImageDraw.Draw(rim).ellipse(bounds, outline=RIM, width=rim_w)
    gauge = Image.alpha_composite(gauge, rim)

    canvas = Image.alpha_composite(canvas, gauge)
    return canvas.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    default_output = (
        Path(__file__).resolve().parent.parent
        / "CodexMeter"
        / "Assets.xcassets"
        / "AppIcon.appiconset"
    )
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=default_output)
    args = parser.parse_args()

    master = render()
    args.output.mkdir(parents=True, exist_ok=True)
    for filename, pixels in OUTPUTS.items():
        image = master if pixels == SIZE else master.resize((pixels, pixels), Image.LANCZOS)
        image.save(args.output / filename, optimize=True)
        print(f"wrote {args.output / filename}")


if __name__ == "__main__":
    main()
