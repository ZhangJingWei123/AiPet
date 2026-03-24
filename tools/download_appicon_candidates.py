from __future__ import annotations

from pathlib import Path
import subprocess
from urllib.request import Request, urlopen
import ssl
import hashlib
import time


def _download(url: str) -> bytes:
    req = Request(url, headers={"User-Agent": "Mozilla/5.0"})
    context = ssl._create_unverified_context()
    with urlopen(req, timeout=120, context=context) as r:
        return r.read()


def _to_png(src: Path, dst: Path) -> None:
    subprocess.check_call(["sips", "-s", "format", "png", str(src), "--out", str(dst)], stdout=subprocess.DEVNULL)


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> None:
    out_dir = Path("AIPetApp/Design/AppIconCandidates")
    out_dir.mkdir(parents=True, exist_ok=True)

    items = {
        "icon_A": "https://copilot-cn.bytedance.net/api/ide/v1/text_to_image?prompt=minimal%20app%20icon%2C%20cute%20round%20pet%20face%20silhouette%20with%20two%20dot%20eyes%2C%20small%20chat%20bubble%20next%20to%20it%2C%20single%20color%20glyph%20in%20white%20on%20deep%20teal%20gradient%20background%2C%20flat%20vector%2C%20high%20contrast%2C%20centered%2C%20no%20text%2C%20no%20border%2C%20ios%20app%20icon%20style%2C%20clean%20geometry%2C%20rounded%20square%20composition%2C%201024x1024&image_size=square_hd",
        "icon_B": "https://copilot-cn.bytedance.net/api/ide/v1/text_to_image?prompt=minimal%20app%20icon%2C%20simple%20paw%20print%20combined%20with%20a%20small%20neural%20network%20node%20pattern%20inside%20the%20paw%20pad%2C%20white%20glyph%20on%20midnight%20navy%20to%20purple%20gradient%20background%2C%20flat%20vector%2C%20high%20contrast%2C%20centered%2C%20no%20text%2C%20no%20border%2C%20ios%20app%20icon%20style%2C%20clean%20geometry%2C%20rounded%20square%20composition%2C%201024x1024&image_size=square_hd",
        "icon_C": "https://copilot-cn.bytedance.net/api/ide/v1/text_to_image?prompt=minimal%20app%20icon%2C%20cute%20pet%20head%20silhouette%20with%20a%20tiny%20microphone%20symbol%20or%20sound%20waves%20to%20the%20side%2C%20white%20glyph%20on%20warm%20coral%20to%20orange%20gradient%20background%2C%20flat%20vector%2C%20high%20contrast%2C%20centered%2C%20no%20text%2C%20no%20border%2C%20ios%20app%20icon%20style%2C%20clean%20geometry%2C%20rounded%20square%20composition%2C%201024x1024&image_size=square_hd",
    }

    placeholder_hash: str | None = None

    for name, url in items.items():
        out_png = out_dir / f"{name}.png"
        for attempt in range(1, 31):
            tmp = out_dir / f"{name}.jpg"
            tmp.write_bytes(_download(url))
            _to_png(tmp, out_png)
            tmp.unlink(missing_ok=True)

            digest = _sha256(out_png)
            if placeholder_hash is None:
                placeholder_hash = digest
                break

            if digest != placeholder_hash:
                break
            time.sleep(2.0)


if __name__ == "__main__":
    main()
