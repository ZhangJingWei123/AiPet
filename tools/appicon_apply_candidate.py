from __future__ import annotations

from pathlib import Path
from PIL import Image


def make_background(size: int) -> Image.Image:
    top = (245, 95, 80)
    bottom = (255, 170, 70)
    bg = Image.new("RGB", (size, size), top)
    px = bg.load()
    for y in range(size):
        t = y / (size - 1)
        r = int(top[0] * (1 - t) + bottom[0] * t)
        g = int(top[1] * (1 - t) + bottom[1] * t)
        b = int(top[2] * (1 - t) + bottom[2] * t)
        for x in range(size):
            px[x, y] = (r, g, b)
    return bg


def main() -> None:
    repo = Path(__file__).resolve().parents[1]
    src = repo / "AIPetApp/Design/AppIconCandidates/icon_C_pet.png"
    out_set = repo / "AIPetApp/Assets.xcassets/AppIcon.appiconset"
    out_set.mkdir(parents=True, exist_ok=True)

    icon = Image.open(src).convert("RGBA")
    size = 1024
    bg = make_background(size)
    bg.paste(icon, (0, 0), icon)
    base = bg

    targets: dict[str, int] = {
        "AppIcon-1024.png": 1024,
        "AppIcon-20@2x.png": 40,
        "AppIcon-20@3x.png": 60,
        "AppIcon-29@2x.png": 58,
        "AppIcon-29@3x.png": 87,
        "AppIcon-40@2x.png": 80,
        "AppIcon-40@3x.png": 120,
        "AppIcon-60@2x.png": 120,
        "AppIcon-60@3x.png": 180,
        "AppIcon-20.png": 20,
        "AppIcon-20@2x-ipad.png": 40,
        "AppIcon-29.png": 29,
        "AppIcon-29@2x-ipad.png": 58,
        "AppIcon-40.png": 40,
        "AppIcon-40@2x-ipad.png": 80,
        "AppIcon-76.png": 76,
        "AppIcon-76@2x.png": 152,
        "AppIcon-83.5@2x.png": 167,
    }

    for name, px in targets.items():
        img = base.resize((px, px), Image.Resampling.LANCZOS)
        img.save(out_set / name, format="PNG", optimize=True)


if __name__ == "__main__":
    main()

