# Bib

A small, native paper library for Mac and iPhone, built with SwiftUI and PDFKit. No third-party app dependencies or accounts.

## Run on this Mac

From this folder:

```sh
./scripts/build-mac.sh --run
```

This compiles the Swift sources, bundles the welcome PDF and app artwork, signs the app locally, and opens `.build/Bib.app`. It requires macOS 14 or newer and Apple’s Swift command-line tools. You can also double-click the built app in Finder. Quit a running copy before rebuilding to see your latest code changes.

Click **Try a sample paper** to explore the reader, or use **+ → Import PDFs…** / **⌘I** to import your own PDFs. **+ → Import from arXiv…** / **⌘⇧I** lets you paste an arXiv link and choose where to put the paper.

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
- Paste an arXiv link to download a manuscript into **All papers** or a chosen folder, with available title, authors, year, journal reference, and DOI.
- Create folders, rename them, and remove folders while keeping their papers.
- Drag a paper from **All papers** onto a sidebar folder to move it there. The destination highlights as you hover. Papers stay visible in **All papers**; drop onto **Unfiled** to remove a folder assignment. Dragging also works from other paper lists when the sidebar is visible.
- Read PDFs, select text, scroll, zoom, and fit the page.
- Highlight selected text in yellow, green, blue, or pink. Highlights save automatically in Bib’s PDF copy and remain when you reopen the paper.
- Edit title, authors, year, journal/venue, DOI, and folder using **ⓘ** in the reader.
- Search metadata and sort by title, year, or when a paper was added.
- Remove a paper from its details panel, with confirmation.
- Close and reopen the app with your library intact.

For local PDF imports, title and author are read from embedded PDF metadata when available; otherwise the title comes from the filename. arXiv imports retrieve available metadata online. All details can be edited manually. The included PDF is a welcome guide, not a research paper.

For arXiv, paste an abstract (`arxiv.org/abs/…`), PDF (`arxiv.org/pdf/…`), or HTML paper link, or the paper’s identifier. Versioned and legacy identifiers are supported. The import defaults to the folder you are browsing; choose **All papers (no folder)** for an unfiled paper. Every imported paper also appears in **All papers**. A progress indicator and Cancel button remain available while downloading. If paper details are temporarily unavailable, the PDF can still import using its embedded metadata, with a notice. The importer uses the [official arXiv API](https://info.arxiv.org/help/api/user-manual.html) and follows its [request limits](https://info.arxiv.org/help/api/tou.html).

To highlight, select text in the PDF and click a color below the page. On iPhone, touch and hold a word, adjust the selection handles, then tap a color. Reselect the same text to change its color, or select part of a highlighted line and use the eraser to remove that line’s Bib highlight. Existing annotations imported from other apps are preserved. Scanned pages need a selectable text layer; encrypted or protected PDFs need an unprotected copy before highlighting.

The library stays local to each device; it does not sync between Mac and iPhone or generate citations. arXiv imports need an internet connection and download asynchronously. Local PDF copies and library saves are synchronous, which is appropriate for a small initial library; background local import can be added later for larger batches.

## Files and data

```text
Bib/
  BibApp.swift             Shared app entry point
  Models/                  Paper, folder, and local library persistence
  Services/                arXiv link parsing, metadata retrieval, and PDF download
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

Tests use temporary libraries and generated PDFs. They cover metadata extraction, reopening saved data, atomic folder moves, deleting folders without deleting papers, original-file preservation, failed-save rollback, corrupt-library protection, and invalid/password-protected PDF imports. Drag-and-drop tests exercise native item-provider encoding and reject malformed payloads, unrelated text, and papers or folders deleted during a drag. Highlight tests verify saved colors, multiline and multipage selections, recoloring and removal after reopening, preserved text and imported annotations, write-failure rollback, and protection against overwriting another window’s changes. An expected CoreGraphics diagnostic may appear for the deliberately invalid PDF fixture.

arXiv tests use simulated responses, so the suite needs no network. They cover link parsing, version matching, metadata fallback, invalid downloads, cancellation, temporary-file cleanup, request pacing, and saving downloaded metadata and PDFs into a chosen folder. A real arXiv download and saved-library reopen were also verified during implementation.

## App artwork

`logo.jpg` is the source for the Mac and iPhone app icons and the logo in the library sidebar. Generated artwork is included in the project, so building and running the app requires no image-processing dependencies. After replacing the source image, regenerate the artwork and rebuild:

```sh
python3 scripts/generate-icons.py
./scripts/build-mac.sh --run
```

The regeneration script requires Python 3 and Pillow (`python3 -m pip install Pillow`). Xcode uses `Assets.xcassets/AppIcon.appiconset`; the standalone Mac build uses `Resources/AppIcon.icns`.

The main views and storage are deliberately separate so we can build the next small feature without replacing this foundation. Navigation follows Apple’s [SwiftUI split-view guidance](https://developer.apple.com/documentation/technotes/tn3154-adopting-swiftui-navigation-split-view); the embedded reader uses [PDFKit](https://developer.apple.com/documentation/pdfkit).
