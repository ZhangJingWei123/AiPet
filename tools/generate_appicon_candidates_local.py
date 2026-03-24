from __future__ import annotations

from pathlib import Path
from PIL import Image, ImageDraw


def linear_gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    img = Image.new("RGB", (size, size), top)
    px = img.load()
    for y in range(size):
        t = y / (size - 1)
        r = int(top[0] * (1 - t) + bottom[0] * t)
        g = int(top[1] * (1 - t) + bottom[1] * t)
        b = int(top[2] * (1 - t) + bottom[2] * t)
        for x in range(size):
            px[x, y] = (r, g, b)
    return img


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle((0, 0, size, size), radius=radius, fill=255)
    return mask


def icon_a(size: int) -> Image.Image:
    bg = linear_gradient(size, (10, 130, 140), (5, 70, 90))
    img = Image.new("RGBA", (size, size))
    img.paste(bg, (0, 0))
    d = ImageDraw.Draw(img)

    cx, cy = size * 0.48, size * 0.50
    r = size * 0.24
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(255, 255, 255, 255))

    eye_r = size * 0.03
    d.ellipse((cx - r * 0.35 - eye_r, cy - r * 0.10 - eye_r, cx - r * 0.35 + eye_r, cy - r * 0.10 + eye_r), fill=(0, 0, 0, 80))
    d.ellipse((cx + r * 0.10 - eye_r, cy - r * 0.10 - eye_r, cx + r * 0.10 + eye_r, cy - r * 0.10 + eye_r), fill=(0, 0, 0, 80))

    bubble_w, bubble_h = size * 0.30, size * 0.18
    bx, by = size * 0.62, size * 0.30
    d.rounded_rectangle((bx, by, bx + bubble_w, by + bubble_h), radius=int(size * 0.05), fill=(255, 255, 255, 255))
    tail = [(bx + bubble_w * 0.18, by + bubble_h), (bx + bubble_w * 0.30, by + bubble_h), (bx + bubble_w * 0.20, by + bubble_h + size * 0.05)]
    d.polygon(tail, fill=(255, 255, 255, 255))

    return img


def icon_b(size: int) -> Image.Image:
    bg = linear_gradient(size, (30, 20, 60), (110, 60, 180))
    img = Image.new("RGBA", (size, size))
    img.paste(bg, (0, 0))
    d = ImageDraw.Draw(img)

    cx, cy = size * 0.50, size * 0.54
    pad_r = size * 0.18
    toe_r = size * 0.08
    d.ellipse((cx - pad_r, cy - pad_r * 0.7, cx + pad_r, cy + pad_r * 1.1), fill=(255, 255, 255, 255))

    toes = [(-0.22, -0.28), (-0.07, -0.34), (0.09, -0.34), (0.24, -0.28)]
    for ox, oy in toes:
        tx, ty = cx + ox * size, cy + oy * size
        d.ellipse((tx - toe_r, ty - toe_r, tx + toe_r, ty + toe_r), fill=(255, 255, 255, 255))

    nodes = [(-0.06, 0.01), (0.07, -0.01), (0.03, 0.08), (-0.10, 0.10)]
    pts = []
    for ox, oy in nodes:
        px, py = cx + ox * size, cy + oy * size
        pts.append((px, py))
        d.ellipse((px - size * 0.015, py - size * 0.015, px + size * 0.015, py + size * 0.015), fill=(60, 40, 110, 220))
    for a, b in [(0, 2), (1, 2), (0, 3)]:
        d.line([pts[a], pts[b]], fill=(60, 40, 110, 180), width=int(size * 0.012))

    return img


def icon_c(size: int) -> Image.Image:
    bg = linear_gradient(size, (245, 95, 80), (255, 165, 70))
    img = Image.new("RGBA", (size, size))
    img.paste(bg, (0, 0))
    d = ImageDraw.Draw(img)

    cx, cy = size * 0.46, size * 0.54
    r = size * 0.22
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(255, 255, 255, 255))
    ear = size * 0.10
    d.polygon([(cx - r * 0.55, cy - r * 0.72), (cx - r * 0.15, cy - r * 0.95), (cx - r * 0.05, cy - r * 0.55)], fill=(255, 255, 255, 255))
    d.polygon([(cx + r * 0.20, cy - r * 0.95), (cx + r * 0.55, cy - r * 0.72), (cx + r * 0.05, cy - r * 0.55)], fill=(255, 255, 255, 255))

    eye_r = size * 0.028
    d.ellipse((cx - r * 0.28 - eye_r, cy - r * 0.05 - eye_r, cx - r * 0.28 + eye_r, cy - r * 0.05 + eye_r), fill=(0, 0, 0, 70))
    d.ellipse((cx + r * 0.10 - eye_r, cy - r * 0.05 - eye_r, cx + r * 0.10 + eye_r, cy - r * 0.05 + eye_r), fill=(0, 0, 0, 70))

    wx = size * 0.68
    wy = size * 0.50
    for i, rad in enumerate([0.09, 0.14, 0.19]):
        rr = size * rad
        d.arc((wx - rr, wy - rr, wx + rr, wy + rr), start=300, end=60, fill=(255, 255, 255, 220), width=int(size * 0.018))

    mic_w = size * 0.06
    mic_h = size * 0.10
    mx, my = size * 0.62, size * 0.58
    d.rounded_rectangle((mx, my, mx + mic_w, my + mic_h), radius=int(size * 0.03), fill=(255, 255, 255, 255))
    d.line([(mx + mic_w / 2, my + mic_h), (mx + mic_w / 2, my + mic_h + size * 0.04)], fill=(255, 255, 255, 255), width=int(size * 0.018))
    d.arc((mx - size * 0.03, my + mic_h + size * 0.01, mx + mic_w + size * 0.03, my + mic_h + size * 0.08), start=200, end=-20, fill=(255, 255, 255, 255), width=int(size * 0.018))

    return img


def main() -> None:
    out_dir = Path("AIPetApp/Design/AppIconCandidates")
    out_dir.mkdir(parents=True, exist_ok=True)
    size = 1024

    for name, fn in [("icon_A.png", icon_a), ("icon_B.png", icon_b), ("icon_C.png", icon_c)]:
        img = fn(size)
        img.putalpha(rounded_mask(size, radius=int(size * 0.23)))
        img.save(out_dir / name, format="PNG", optimize=True)


if __name__ == "__main__":
    main()

