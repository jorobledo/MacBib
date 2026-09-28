# Bib

A small, native paper library for Mac and iPhone, built with SwiftUI and PDFKit. No third-party app dependencies, accounts, or servers.

## Run on this Mac

From this folder:

```sh
./scripts/build-mac.sh --run
```

This compiles the Swift sources, bundles the welcome PDF and app artwork, signs the app locally, and opens `.build/Bib.app`. It requires macOS 14 or newer and Apple’s Swift command-line tools. You can also double-click the built app in Finder. Quit a running copy before rebuilding to see your latest code changes.

Click **Try a sample paper** to explore the reader, or use **+** / **⌘I** to import your own PDFs.

The script uses the Command Line Tools when installed. To choose a different toolchain:

```sh
BIB_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build-mac.sh --run
```

## Run in Xcode / on iPhone

1. Open `Bib.xcodeproj` in Xcode 16 or newer.
2. Select the **Bib** scheme.
3. Choose **My Mac** or an installed **iPhone Simulator**, then press **⌘R**.
4. For a physical iPhone, choose your team under **Signing & Capabilities**, use a unique bundle identifier if needed, and select the connected device. iOS 17 or newer is required.

The shared interface uses three columns on Mac and adapts to a navigation stack on iPhone. The target also supports iPad.

**Toolchain status on this machine:** Xcode is installed, but `xcodebuild` currently fails before loading the project with a `_XPCTypeBool` symbol error in CoreDevice/Mercury. The Mac build script works independently. Both Mac and iOS Simulator executables have compiled successfully with the standalone Swift compiler; simulator execution and physical-device signing have not been verified. Repairing the local Xcode installation is needed to use its normal Run / simulator workflow.

## What works

- Import one or several PDFs; Bib copies them into its library.
- Create folders, rename them, and remove folders while keeping their papers.
- Drag a paper from **All papers** onto a sidebar folder to move it there. The destination highlights as you hover. Papers stay visible in **All papers**; drop onto **Unfiled** to remove a folder assignment. Dragging also works from other paper lists when the sidebar is visible.
- Read PDFs, select text, scroll, zoom, and fit the page.
- Edit title, authors, year, journal/venue, DOI, and folder using **ⓘ** in the reader.
- Search metadata and sort by title, year, or when a paper was added.
- Remove a paper from its details panel, with confirmation.
- Close and reopen the app with your library intact.

Title and author are read from embedded PDF metadata when available. Otherwise the title comes from the filename. Other metadata is entered manually. The included PDF is a welcome guide, not a research paper.

This first version is local to each device. It does not sync between Mac and iPhone, retrieve metadata online, generate citations, or add PDF annotations. Imports and saves run synchronously, which is appropriate for a small initial library; background import can be added later for larger batches.

## Files and data

```text
Bib/
  BibApp.swift             Shared app entry point
  Models/                  Paper, folder, and local library persistence
  Views/                   Library, reader, and metadata editor
  Resources/Welcome.pdf    Bundled sample
Bib.xcodeproj/             Shared Mac / iPhone / iPad target
scripts/build-mac.sh        Standalone Mac build and launch
scripts/test.sh             Persistence and PDF import tests
Tests/                     Isolated store tests
```

Mac development builds (both Xcode and the script) store data in:

```text
~/Library/Application Support/Bib/
  library.json
  Documents/<generated-id>.pdf
```

These local Mac development builds are not App Sandbox builds. iOS stores the same structure in its app container. Back up the entire `Bib` data folder to keep both metadata and PDFs; deleting the source project or `.build` does not remove the library. Imported originals are never modified. The JSON format is versioned, writes are atomic, and an unreadable library is protected from accidental overwriting.

## Verify changes

```sh
./scripts/test.sh
./scripts/build-mac.sh
```

Tests use temporary libraries and generated PDFs. They cover metadata extraction, reopening saved data, atomic folder moves, deleting folders without deleting papers, original-file preservation, failed-save rollback, corrupt-library protection, and invalid/password-protected PDF imports. Drag-and-drop tests exercise native item-provider encoding and reject malformed payloads, unrelated text, and papers or folders deleted during a drag. An expected CoreGraphics diagnostic may appear for the deliberately invalid PDF fixture.

## App artwork

`logo.jpg` is the source for the Mac and iPhone app icons and the logo in the library sidebar. Generated artwork is included in the project, so building and running the app requires no image-processing dependencies. After replacing the source image, regenerate the artwork and rebuild:

```sh
python3 scripts/generate-icons.py
./scripts/build-mac.sh --run
```

The regeneration script requires Python 3 and Pillow (`python3 -m pip install Pillow`). Xcode uses `Assets.xcassets/AppIcon.appiconset`; the standalone Mac build uses `Resources/AppIcon.icns`.

The main views and storage are deliberately separate so we can build the next small feature without replacing this foundation. Navigation follows Apple’s [SwiftUI split-view guidance](https://developer.apple.com/documentation/technotes/tn3154-adopting-swiftui-navigation-split-view); the embedded reader uses [PDFKit](https://developer.apple.com/documentation/pdfkit).
