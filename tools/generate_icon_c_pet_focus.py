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


def icon_c_pet_focus(size: int) -> Image.Image:
    bg = linear_gradient(size, (245, 95, 80), (255, 170, 70))
    img = Image.new("RGBA", (size, size))
    img.paste(bg, (0, 0))
    d = ImageDraw.Draw(img)

    cx, cy = size * 0.50, size * 0.54
    r = size * 0.285

    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.ellipse((cx - r + size * 0.012, cy - r + size * 0.020, cx + r + size * 0.012, cy + r + size * 0.020), fill=(0, 0, 0, 35))
    img = Image.alpha_composite(img, shadow)
    d = ImageDraw.Draw(img)

    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(255, 255, 255, 255))

    d.polygon(
        [
            (cx - r * 0.75, cy - r * 0.55),
            (cx - r * 0.30, cy - r * 1.05),
            (cx - r * 0.05, cy - r * 0.55),
        ],
        fill=(255, 255, 255, 255),
    )
    d.polygon(
        [
            (cx + r * 0.75, cy - r * 0.55),
            (cx + r * 0.30, cy - r * 1.05),
            (cx + r * 0.05, cy - r * 0.55),
        ],
        fill=(255, 255, 255, 255),
    )

    eye_r = size * 0.030
    eye_y = cy - r * 0.05
    left_x = cx - r * 0.30
    right_x = cx + r * 0.18
    d.ellipse((left_x - eye_r, eye_y - eye_r, left_x + eye_r, eye_y + eye_r), fill=(0, 0, 0, 85))
    d.ellipse((right_x - eye_r, eye_y - eye_r, right_x + eye_r, eye_y + eye_r), fill=(0, 0, 0, 85))

    cheek_r = size * 0.040
    d.ellipse((cx - r * 0.58 - cheek_r, cy + r * 0.12 - cheek_r, cx - r * 0.58 + cheek_r, cy + r * 0.12 + cheek_r), fill=(255, 110, 110, 120))
    d.ellipse((cx + r * 0.48 - cheek_r, cy + r * 0.12 - cheek_r, cx + r * 0.48 + cheek_r, cy + r * 0.12 + cheek_r), fill=(255, 110, 110, 120))

    smile_w = r * 0.44
    smile_h = r * 0.26
    d.arc((cx - smile_w / 2, cy + r * 0.10, cx + smile_w / 2, cy + r * 0.10 + smile_h), start=200, end=340, fill=(0, 0, 0, 70), width=int(size * 0.018))

    wx, wy = size * 0.72, size * 0.52
    for rad in [0.10, 0.16]:
        rr = size * rad
        d.arc((wx - rr, wy - rr, wx + rr, wy + rr), start=305, end=55, fill=(255, 255, 255, 210), width=int(size * 0.016))

    mx, my = size * 0.62, size * 0.62
    d.ellipse((mx - size * 0.030, my - size * 0.030, mx + size * 0.030, my + size * 0.030), fill=(255, 255, 255, 235))
    d.rectangle((mx - size * 0.008, my + size * 0.022, mx + size * 0.008, my + size * 0.055), fill=(255, 255, 255, 235))

    return img


def main() -> None:
    out_dir = Path("AIPetApp/Design/AppIconCandidates")
    out_dir.mkdir(parents=True, exist_ok=True)
    size = 1024
    img = icon_c_pet_focus(size)
    img.putalpha(rounded_mask(size, radius=int(size * 0.23)))
    img.save(out_dir / "icon_C_pet.png", format="PNG", optimize=True)


if __name__ == "__main__":
    main()

