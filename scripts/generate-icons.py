#!/usr/bin/env python3
"""Regenerate the checked-in app artwork from logo.jpg (requires Pillow)."""

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageOps


PROJECT_DIR = Path(__file__).resolve().parent.parent
ASSETS_DIR = PROJECT_DIR / "Bib/Assets.xcassets"
APP_ICON_DIR = ASSETS_DIR / "AppIcon.appiconset"
LOGO_DIR = ASSETS_DIR / "BibLogo.imageset"
RESOURCES_DIR = PROJECT_DIR / "Bib/Resources"


def write_catalog(directory, images):
    (directory / "Contents.json").write_text(
        json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2)
        + "\n"
    )


def main():
    for directory in (APP_ICON_DIR, LOGO_DIR, RESOURCES_DIR):
        directory.mkdir(parents=True, exist_ok=True)

    with Image.open(PROJECT_DIR / "logo.jpg") as source:
        artwork = ImageOps.exif_transpose(source).convert("RGB")

    # Preserve the complete artwork, padding rather than cropping a future non-square logo.
    icon = ImageOps.pad(artwork, (1024, 1024), method=Image.Resampling.LANCZOS, color="white")
    icon.save(APP_ICON_DIR / "ios_1024x1024.png")
    artwork.save(LOGO_DIR / "BibLogo.png")
    write_catalog(LOGO_DIR, [{"idiom": "universal", "filename": "BibLogo.png"}])

    # iOS supplies its own icon mask. Classic macOS .icns artwork needs transparent
    # margins and a rounded tile so Finder and the Dock match other native icons.
    mask = Image.new("L", (2048, 2048), 0)
    ImageDraw.Draw(mask).rounded_rectangle((128, 128, 1919, 1919), radius=380, fill=255)
    mask = mask.resize((1024, 1024), Image.Resampling.LANCZOS)
    mac_icon = Image.new("RGB", (1024, 1024), "white")
    mac_icon.paste(icon.resize((896, 896), Image.Resampling.LANCZOS), (64, 64))
    mac_icon.putalpha(mask)

    images = [{
        "idiom": "universal",
        "platform": "ios",
        "size": "1024x1024",
        "filename": "ios_1024x1024.png",
    }]
    resized_icons = []
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            suffix = "@2x" if scale == 2 else ""
            filename = f"icon_{size}x{size}{suffix}.png"
            resized = mac_icon.resize((size * scale, size * scale), Image.Resampling.LANCZOS)
            resized.save(APP_ICON_DIR / filename)
            resized_icons.append(resized)
            images.append({
                "idiom": "mac",
                "size": f"{size}x{size}",
                "scale": f"{scale}x",
                "filename": filename,
            })
    write_catalog(APP_ICON_DIR, images)
    mac_icon.save(RESOURCES_DIR / "AppIcon.icns", format="ICNS", append_images=resized_icons)

    print("Updated the Mac app icon, iOS app icon, and sidebar logo from logo.jpg.")


if __name__ == "__main__":
    main()
