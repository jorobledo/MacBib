#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
DEVELOPER_TOOLS="${BIB_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
if [ ! -x "$DEVELOPER_TOOLS/usr/bin/swiftc" ]; then
    DEVELOPER_TOOLS="$(/usr/bin/xcode-select -p)"
fi
export DEVELOPER_DIR="$DEVELOPER_TOOLS"
SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
ARCH="$(/usr/bin/uname -m)"
mkdir -p "$BUILD_DIR/ModuleCache"

/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library \
    -sdk "$SDK_PATH" -target "$ARCH-apple-macosx14.0" \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    "$PROJECT_DIR/Bib/Models/Paper.swift" \
    "$PROJECT_DIR/Bib/Models/LibraryStore.swift" \
    "$PROJECT_DIR/Tests/LibraryStoreTests.swift" \
    -o "$BUILD_DIR/LibraryStoreTests"
"$BUILD_DIR/LibraryStoreTests"

/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library \
    -sdk "$SDK_PATH" -target "$ARCH-apple-macosx14.0" \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    "$PROJECT_DIR/Bib/Models/Paper.swift" \
    "$PROJECT_DIR/Bib/Models/LibraryStore.swift" \
    "$PROJECT_DIR/Bib/Views/Theme.swift" \
    "$PROJECT_DIR/Bib/Views/PaperDragDrop.swift" \
    "$PROJECT_DIR/Tests/PaperDragDropTests.swift" \
    -o "$BUILD_DIR/PaperDragDropTests"
"$BUILD_DIR/PaperDragDropTests"
