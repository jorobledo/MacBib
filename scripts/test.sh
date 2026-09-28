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
    "$PROJECT_DIR/Bib/Models/StorageFolderMigration.swift" \
    "$PROJECT_DIR/Tests/LibraryStoreTests.swift" \
    -o "$BUILD_DIR/LibraryStoreTests"
"$BUILD_DIR/LibraryStoreTests"

/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library \
    -sdk "$SDK_PATH" -target "$ARCH-apple-macosx14.0" \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    "$PROJECT_DIR/Bib/Models/Paper.swift" \
    "$PROJECT_DIR/Bib/Models/LibraryStore.swift" \
    "$PROJECT_DIR/Bib/Models/StorageFolderMigration.swift" \
    "$PROJECT_DIR/Bib/Views/Theme.swift" \
    "$PROJECT_DIR/Bib/Views/PaperDragDrop.swift" \
    "$PROJECT_DIR/Tests/PaperDragDropTests.swift" \
    -o "$BUILD_DIR/PaperDragDropTests"
"$BUILD_DIR/PaperDragDropTests"

/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library \
    -sdk "$SDK_PATH" -target "$ARCH-apple-macosx14.0" \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    "$PROJECT_DIR/Bib/Models/PDFHighlights.swift" \
    "$PROJECT_DIR/Tests/PDFHighlightsTests.swift" \
    -o "$BUILD_DIR/PDFHighlightsTests"
"$BUILD_DIR/PDFHighlightsTests"

/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library \
    -sdk "$SDK_PATH" -target "$ARCH-apple-macosx14.0" \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    "$PROJECT_DIR/Bib/Models/Paper.swift" \
    "$PROJECT_DIR/Bib/Services/ArxivImportService.swift" \
    "$PROJECT_DIR/Tests/ArxivImportTests.swift" \
    -o "$BUILD_DIR/ArxivImportTests"
"$BUILD_DIR/ArxivImportTests"

/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library \
    -sdk "$SDK_PATH" -target "$ARCH-apple-macosx14.0" \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    "$PROJECT_DIR/Bib/Models/Paper.swift" \
    "$PROJECT_DIR/Bib/Services/DOIImportService.swift" \
    "$PROJECT_DIR/Tests/DOIImportTests.swift" \
    -o "$BUILD_DIR/DOIImportTests"
"$BUILD_DIR/DOIImportTests"

/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library \
    -sdk "$SDK_PATH" -target "$ARCH-apple-macosx14.0" \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    "$PROJECT_DIR/Bib/Models/StorageFolderMigration.swift" \
    "$PROJECT_DIR/Tests/StorageFolderMigrationTests.swift" \
    -o "$BUILD_DIR/StorageFolderMigrationTests"
"$BUILD_DIR/StorageFolderMigrationTests"

/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library \
    -sdk "$SDK_PATH" -target "$ARCH-apple-macosx14.0" \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    "$PROJECT_DIR/Bib/Models/Paper.swift" \
    "$PROJECT_DIR/Bib/Models/StorageFolderMigration.swift" \
    "$PROJECT_DIR/Bib/Models/LibraryStore.swift" \
    "$PROJECT_DIR/Tests/StorageLocationTests.swift" \
    -o "$BUILD_DIR/StorageLocationTests"
"$BUILD_DIR/StorageLocationTests"
