#!/usr/bin/env python3
"""Generates the NetBridge app icons for every Apple platform from one design: a white bridge mark (`draw_glyph`) on
the #1E40AF -> #0D9488 diagonal gradient.

  iOS    NetBridge/Assets.xcassets/AppIcon.appiconset/icon-1024.png        (opaque 1024 square)
  macOS  NetBridgeMac/Assets.xcassets/AppIcon.appiconset/icon_*.png        (downscaled from the 1024 master)
  tvOS   NetBridgeTV/Assets.xcassets   "App Icon & Top Shelf Image"        (layered: Back = gradient, Front = mark;
                                                                            Top Shelf = both flattened)

The Windows client has no app icon asset (its tray icon is a state-coloured ring drawn in code), so it is not touched.
Only the PNG files are overwritten; the iOS/macOS Contents.json files are left as they are. Edit `draw_glyph` to change
the mark, then re-run:  python3 scripts/gen-icons.py        (needs Pillow)
"""
import json
import os
import shutil
from PIL import Image, ImageDraw

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
CATALOG = os.path.join(ROOT, "NetBridgeTV", "Assets.xcassets")
IOS_ICON = os.path.join(ROOT, "NetBridge", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png")
MAC_SET = os.path.join(ROOT, "NetBridgeMac", "Assets.xcassets", "AppIcon.appiconset")
MAC_SIZES = (16, 32, 64, 128, 256, 512, 1024)
BRAND = os.path.join(CATALOG, "App Icon & Top Shelf Image.brandassets")
TOP_LEFT, BOTTOM_RIGHT = (30, 64, 175), (13, 148, 136)
INFO = {"author": "xcode", "version": 1}
SS = 2  # glyph supersampling for smooth edges


def gradient(w, h):
    # Diagonal gradient: t runs 0 (top-left) -> 1 (bottom-right).
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            t = (x / (w - 1) + y / (h - 1)) / 2
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(TOP_LEFT, BOTTOM_RIGHT))
    return img


def draw_glyph(w, h, scale):
    """White bridge mark (arch, deck, two piers) centred on a transparent w x h canvas.
    `scale` is the glyph's height as a fraction of the canvas height."""
    W, H = w * SS, h * SS
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    gh = H * scale
    gw = gh * 1.9
    cx, cy = W / 2, H / 2
    left, right = cx - gw / 2, cx + gw / 2
    deck_y = cy + gh * 0.28
    stroke = max(2, round(gh * 0.085))
    white = (255, 255, 255, 255)
    # Arch: upper half of an ellipse spanning the deck.
    top = deck_y - gh * 0.78
    d.arc([left, top, right, deck_y + (deck_y - top)], 180, 360, fill=white, width=stroke)
    # Deck.
    d.rounded_rectangle([left - stroke, deck_y - stroke / 2, right + stroke, deck_y + stroke / 2],
                        radius=stroke / 2, fill=white)
    # Piers.
    pier_bottom = deck_y + gh * 0.22
    for x in (left, right):
        d.rounded_rectangle([x - stroke / 2, deck_y, x + stroke / 2, pier_bottom], radius=stroke / 2, fill=white)
    # Hangers: from the arch down to the deck.
    ry = deck_y - top
    for f in (0.25, 0.5, 0.75):
        x = left + gw * f
        y = deck_y - ry * (1 - ((x - cx) / (gw / 2)) ** 2) ** 0.5
        y += stroke / 2  # PIL draws arc strokes inward from the outer edge; start at the stroke's centre line
        d.line([x, y, x, deck_y], fill=white, width=max(2, stroke // 2))
    return layer.resize((w, h), Image.LANCZOS)


def write_png(img, path):
    # write next to the target, then rename: a crash never leaves a half-written icon
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp.png"
    img.save(tmp, optimize=True)
    os.replace(tmp, path)


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")


def imageset(path, name, make, w, h, scales):
    """An imageset holding `make(width, height)` at each of `scales`."""
    images = []
    for s in scales:
        fn = f"{name}@{s}x.png"
        write_png(make(w * s, h * s), os.path.join(path, fn))
        images.append({"idiom": "tv", "filename": fn, "scale": f"{s}x"})
    write_json(os.path.join(path, "Contents.json"), {"images": images, "info": INFO})


def imagestack(path, w, h, scales):
    """Two-layer parallax icon: Front (glyph) over Back (gradient)."""
    write_json(os.path.join(path, "Contents.json"),
               {"layers": [{"filename": "Front.imagestacklayer"}, {"filename": "Back.imagestacklayer"}], "info": INFO})
    for layer, make in (("Front", lambda pw, ph: draw_glyph(pw, ph, 0.50)), ("Back", gradient)):
        lp = os.path.join(path, f"{layer}.imagestacklayer")
        write_json(os.path.join(lp, "Contents.json"), {"info": INFO})
        imageset(os.path.join(lp, "Content.imageset"), layer, make, w, h, scales)


def flattened(pw, ph):
    img = gradient(pw, ph).convert("RGBA")
    img.alpha_composite(draw_glyph(pw, ph, 0.50 if ph >= 600 else 0.6))
    return img.convert("RGB")  # Top Shelf images are opaque


def square_master(size=1024):
    """The square app icon: full-bleed gradient (as the old iOS/macOS icons) with the mark ~62% of the width."""
    img = gradient(size, size).convert("RGBA")
    img.alpha_composite(draw_glyph(size, size, 0.33))
    return img.convert("RGB")  # opaque: the App Store rejects icons with an alpha channel


def write_ios_mac_icons():
    master = square_master()
    write_png(master, IOS_ICON)
    for n in MAC_SIZES:
        write_png(master if n == 1024 else master.resize((n, n), Image.LANCZOS), os.path.join(MAC_SET, f"icon_{n}.png"))
    print("wrote", os.path.normpath(IOS_ICON), "and", len(MAC_SIZES), "macOS icons in", os.path.normpath(MAC_SET))


def write_brandassets(brand):
    write_json(os.path.join(brand, "Contents.json"), {
        "assets": [
            {"size": "1280x768", "idiom": "tv", "filename": "App Icon - App Store.imagestack", "role": "primary-app-icon"},
            {"size": "400x240", "idiom": "tv", "filename": "App Icon.imagestack", "role": "primary-app-icon"},
            {"size": "2320x720", "idiom": "tv", "filename": "Top Shelf Image Wide.imageset", "role": "top-shelf-image-wide"},
            {"size": "1920x720", "idiom": "tv", "filename": "Top Shelf Image.imageset", "role": "top-shelf-image"},
        ],
        "info": INFO,
    })
    imagestack(os.path.join(brand, "App Icon - App Store.imagestack"), 1280, 768, [1])
    imagestack(os.path.join(brand, "App Icon.imagestack"), 400, 240, [1, 2])
    imageset(os.path.join(brand, "Top Shelf Image.imageset"), "TopShelf", flattened, 1920, 720, [1, 2])
    imageset(os.path.join(brand, "Top Shelf Image Wide.imageset"), "TopShelfWide", flattened, 2320, 720, [1, 2])


def main():
    write_ios_mac_icons()
    # Build the tvOS brand assets in a temporary folder and swap it in only when complete. Only the generated
    # .brandassets folder is replaced; anything else in the catalog (e.g. a hand-added AccentColor) is left alone.
    if not os.path.exists(os.path.join(CATALOG, "Contents.json")):
        write_json(os.path.join(CATALOG, "Contents.json"), {"info": INFO})
    tmp = BRAND + ".tmp"
    if os.path.isdir(tmp):
        shutil.rmtree(tmp)
    write_brandassets(tmp)
    if os.path.isdir(BRAND):
        shutil.rmtree(BRAND)
    os.rename(tmp, BRAND)
    print("wrote", os.path.normpath(BRAND))


if __name__ == "__main__":
    main()
