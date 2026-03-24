from __future__ import annotations

from pathlib import Path
import subprocess


def _run(cmd: list[str]) -> None:
    subprocess.check_call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def write_solid_ppm(path: Path, width: int, height: int, rgb: tuple[int, int, int]) -> None:
    r, g, b = rgb
    pixel = bytes([r, g, b])
    with open(path, "wb") as f:
        f.write(f"P6\n{width} {height}\n255\n".encode("ascii"))
        f.write(pixel * (width * height))


def main() -> None:
    root = Path("AIPetApp/Assets.xcassets/AppIcon.appiconset")
    root.mkdir(parents=True, exist_ok=True)

    for p in root.glob("AppIcon-*.png"):
        p.unlink(missing_ok=True)
    (root / "test.png").unlink(missing_ok=True)

    base_ppm = root / "base.ppm"
    write_solid_ppm(base_ppm, 1024, 1024, (28, 186, 186))

    base_png = root / "AppIcon-1024.png"
    _run(["sips", "-s", "format", "png", str(base_ppm), "--out", str(base_png)])
    base_ppm.unlink(missing_ok=True)

    sizes: dict[str, int] = {
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

    for name, px in sizes.items():
        out = root / name
        _run(["sips", "-z", str(px), str(px), str(base_png), "--out", str(out)])


if __name__ == "__main__":
    main()

