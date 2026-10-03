#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
APP_DIR="$BUILD_DIR/Bib.app"
. "$PROJECT_DIR/scripts/toolchain.sh"
bib_configure_toolchain

if [ "${1:-}" = "--check-tools" ]; then
    exit 0
fi

if [ "${1:-}" != "" ] && [ "${1:-}" != "--run" ]; then
    echo "Usage: $0 [--run|--check-tools]" >&2
    exit 2
fi

ARCH="$(/usr/bin/uname -m)"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$BUILD_DIR/ModuleCache"
SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(/usr/bin/find "$PROJECT_DIR/Bib" -name '*.swift' -print0)

echo "Building Bib for macOS ($ARCH)…"
/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library \
    -sdk "$BIB_SDK_PATH" -target "$ARCH-apple-macosx14.0" \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    -module-name Bib -g "${SOURCES[@]}" \
    -o "$APP_DIR/Contents/MacOS/Bib"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>Bib</string>
    <key>CFBundleIdentifier</key><string>local.bib.app</string>
    <key>CFBundleName</key><string>Bib</string>
    <key>CFBundleDisplayName</key><string>Bib</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSDocumentsFolderUsageDescription</key><string>Bib stores and reads your paper PDFs in Documents/Bib or the folder you choose.</string>
    <key>UTExportedTypeDeclarations</key>
    <array><dict>
        <key>UTTypeIdentifier</key><string>local.bib.paper-reference</string>
        <key>UTTypeDescription</key><string>Bib paper reference</string>
        <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    </dict></array>
</dict></plist>
PLIST
/bin/cp "$PROJECT_DIR/Bib/Resources/Welcome.pdf" "$APP_DIR/Contents/Resources/Welcome.pdf"
/bin/cp "$PROJECT_DIR/Bib/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
/bin/cp "$PROJECT_DIR/Bib/Assets.xcassets/BibLogo.imageset/BibLogo.png" "$APP_DIR/Contents/Resources/BibLogo.png"
/usr/bin/codesign --force --sign - "$APP_DIR"
echo "Built: $APP_DIR"

if [ "${1:-}" = "--run" ]; then
    /usr/bin/open "$APP_DIR"
fi
