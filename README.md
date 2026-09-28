# Bib

A small, native paper library for Mac and iPhone, built with SwiftUI and PDFKit. No third-party app dependencies or accounts.

## Run on this Mac

From this folder:

```sh
./scripts/build-mac.sh --run
```

This compiles the Swift sources, bundles the welcome PDF and app artwork, signs the app locally, and opens `.build/Bib.app`. It requires macOS 14 or newer and Apple’s Swift command-line tools. You can also double-click the built app in Finder. Quit a running copy before rebuilding to see your latest code changes.

Click **Try a sample paper** to explore the reader, or use **+ → Import PDFs…** / **⌘I** to import your own PDFs. **+ → Import from arXiv…** / **⌘⇧I** lets you paste an arXiv link and choose where to put the paper.

Use **+ → Import by DOI…** / **⌘⇧D** for a DOI or `https://doi.org/…` link. Choose **All papers** or a folder; Bib fetches paper details and attempts to download the PDF. If the PDF cannot be retrieved, Bib saves the details and a clickable DOI link and shows a popup explaining why.

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
- Store PDFs in **Documents/Bib** by default, or choose another folder using **Paper storage…**.
- Paste an arXiv link to download a manuscript into **All papers** or a chosen folder, with available title, authors, year, journal reference, and DOI.
- Import by DOI, with PDF retrieval when available and metadata-only records when access or downloading fails.
- Open the publisher inside Bib to sign in with a subscription or institution account, then open its PDF to attach it to the saved paper. You can also attach a PDF from your files.
- Create folders, rename them, and remove folders while keeping their papers.
- Drag a paper from **All papers** onto a sidebar folder to move it there. The destination highlights as you hover. Papers stay visible in **All papers**; drop onto **Unfiled** to remove a folder assignment. Dragging also works from other paper lists when the sidebar is visible.
- Read PDFs, select text, scroll, zoom, and fit the page.
- Highlight selected text in yellow, green, blue, or pink. Highlights save automatically in Bib’s PDF copy and remain when you reopen the paper.
- Edit title, authors, year, journal/venue, DOI, and folder using **ⓘ** in the reader.
- Search metadata and sort by title, year, or when a paper was added.
- Remove a paper from its details panel, with confirmation.
- Close and reopen the app with your library intact.

**Import PDFs…** saves local PDFs immediately, then looks up their paper details online in the background. Bib uses DOI or arXiv identifiers found in the PDF first, and searches Crossref by title when needed. Only confident matches update the title, authors, year, journal, and DOI; edits made while a search is running are preserved. The progress bar includes **Cancel search**, which keeps the imported PDFs. If the connection fails or no reliable match is found, the embedded title and author (or filename) remain, with a notice. Lookup sends identifiers or a title query to the metadata services; it does not upload the PDF. All details can be edited manually. The included welcome guide skips online lookup.

For arXiv, paste an abstract (`arxiv.org/abs/…`), PDF (`arxiv.org/pdf/…`), or HTML paper link, or the paper’s identifier. Versioned and legacy identifiers are supported. The import defaults to the folder you are browsing; choose **All papers (no folder)** for an unfiled paper. Every imported paper also appears in **All papers**. A progress indicator and Cancel button remain available while downloading. If paper details are temporarily unavailable, the PDF can still import using its embedded metadata, with a notice. The importer uses the [official arXiv API](https://info.arxiv.org/help/api/user-manual.html) and follows its [request limits](https://info.arxiv.org/help/api/tou.html).

DOI imports use [Crossref metadata](https://www.crossref.org/documentation/retrieve-metadata/rest-api/) and [DOI content negotiation](https://www.crossref.org/documentation/retrieve-metadata/content-negotiation/), then try PDF links supplied by the publisher. Public PDFs and access granted through your network, such as an institutional VPN, can download automatically. Publisher login requirements, missing PDF links, and connection failures leave a **No PDF** record that remains searchable, editable, and movable between folders. A failed connection is not treated as proof that a subscription is required. Invalid DOIs or unavailable metadata show an error without creating an empty paper.

For a saved paper without a PDF, use **Open publisher & sign in**, sign in on the publisher or institution’s site, and open its PDF. Bib attaches the downloaded file to that same record. WebKit keeps the publisher session inside Bib; Safari and other browser logins are not shared. Some publisher or institutional login flows may not work in an embedded browser. In that case, open the DOI link in your usual browser, download the PDF using your access, then choose **Attach PDF…** in Bib. **Try PDF download again** also lets you retry after connecting to your institution’s network. The importer does not bypass subscription checks, and discovering a PDF is not guaranteed for every publisher.

To highlight, select text in the PDF and click a color below the page. On iPhone, touch and hold a word, adjust the selection handles, then tap a color. Reselect the same text to change its color, or select part of a highlighted line and use the eraser to remove that line’s Bib highlight. Existing annotations imported from other apps are preserved. Scanned pages need a selectable text layer; encrypted or protected PDFs need an unprotected copy before highlighting.

The library stays local to each device; it does not sync between Mac and iPhone or generate citations. arXiv and DOI imports need an internet connection and download asynchronously. Online details for local PDF imports are optional and retrieved asynchronously; importing and reading local PDFs works offline. Changing the PDF storage folder copies and verifies files in the background. Individual local PDF copies and library saves are synchronous, which is appropriate for a small initial library.

## Files and data

```text
Bib/
  BibApp.swift             Shared app entry point
  Models/                  Paper, folder, and local library persistence
  Services/                Online paper metadata lookup and PDF downloads
  Views/                   Library, reader, and metadata editor
  Resources/Welcome.pdf    Bundled sample
Bib.xcodeproj/             Shared Mac / iPhone / iPad target
scripts/build-mac.sh        Standalone Mac build and launch
scripts/test.sh             Persistence and PDF import tests
Tests/                     Isolated store tests
```

Mac development builds (both Xcode and the script) use these default locations:

```text
~/Library/Application Support/Bib/
  library.json                 Metadata, logical folders, and chosen PDF location
~/Documents/Bib/
  <generated-id>.pdf            The PDFs used by the reader and highlight tools
```

On the first launch of this version, Bib copies existing managed PDFs from `Application Support/Bib/Documents` into `Documents/Bib`, verifies that the copies match, and saves the new references. Highlights, metadata, paper IDs, and logical folders are preserved. The previous copies stay in their old location; Bib uses the new copies for reading and future highlights. Metadata-only DOI records remain in the library without a PDF. macOS may ask Bib for access to Documents.

Use **Paper storage…** at the bottom of the sidebar (also in the **+** menu) to see the current location, reveal it in Finder, or **Choose folder…**. The selected folder is used directly; future local imports, downloads, and attachments go there. Folder choices persist across launches using bookmarks. Changing location copies all attached PDFs and switches only after verification and a successful library save. Missing or corrupt PDFs, differing files with the same name, and write failures leave the previous location active. Identical existing copies are reused; unrelated files are untouched. If a selected drive or folder is unavailable, reconnect or reselect it; Bib does not silently switch locations or recreate a missing folder. An empty library can choose a new location without recovering an unavailable old folder.

On iPhone and iPad, the default is the app’s `Documents/Bib` directory, visible in **Files → On My iPhone/iPad → Bib → Bib**. The folder picker can select another available Files location. Library metadata stays in Application Support in the app container. Files access and persistence depend on the chosen provider; physical-device folder picking has not been verified here.

These local Mac development builds are not App Sandbox builds. Back up both `library.json` and the selected PDF folder to keep the complete library. Stable generated filenames prevent title collisions; library topic folders are organizational metadata, not subdirectories on disk. Removing a paper deletes its managed PDF from the active storage folder, as before. Imported originals and previous storage copies are not modified. Deleting the source project or `.build` does not remove the library. The JSON format is versioned, writes are atomic, and an unreadable library is protected from accidental overwriting.

## Verify changes

```sh
./scripts/test.sh
./scripts/build-mac.sh
```

Tests use temporary libraries and generated PDFs. They cover metadata extraction, reopening saved data, atomic folder moves, deleting folders without deleting papers, original-file preservation, failed-save rollback, corrupt-library protection, and invalid/password-protected PDF imports. Drag-and-drop tests exercise native item-provider encoding and reject malformed payloads, unrelated text, and papers or folders deleted during a drag. Highlight tests verify saved colors, multiline and multipage selections, recoloring and removal after reopening, preserved text and imported annotations, write-failure rollback, and protection against overwriting another window’s changes. An expected CoreGraphics diagnostic may appear for the deliberately invalid PDF fixture.

arXiv tests use simulated responses, so the suite needs no network. They cover link parsing, version matching, metadata fallback, invalid downloads, cancellation, temporary-file cleanup, request pacing, and saving downloaded metadata and PDFs into a chosen folder. A real arXiv download and saved-library reopen were also verified during implementation.

DOI tests also use simulated responses and cover Crossref and CSL metadata, publisher PDF links, rejection of unrelated recommended-paper links, access-denied and network fallback, invalid PDFs, cancellation, and cleanup. Store tests cover metadata-only records, compatibility with existing libraries, and attaching PDFs without replacing current paper details. A real open-access DOI download, saved-library reopen, and the native transition from a metadata-only record to the PDF reader were verified. Subscription and institutional sign-in flows have not been tested with a live account.

Local PDF metadata tests use simulated responses to check identifier extraction, title matching, ambiguous-result rejection, offline fallback, and cancellation without downloading another PDF. Background lookup tests cover queued imports, reading the managed PDF copy, late results after cancellation, and preserving edits and deletions. Store tests also verify that retrieved details persist and that failed saves retain the imported PDF and previous metadata.

Storage tests cover legacy migration, persisted folder choices, later imports/downloads/attachments, byte-for-byte preservation, identical-file reuse, conflicting or corrupt files, unavailable folders, metadata-only libraries, cancellation, and failed-save rollback. All test libraries and PDF folders are isolated temporary directories.

## App artwork

`logo.jpg` is the source for the Mac and iPhone app icons and the logo in the library sidebar. Generated artwork is included in the project, so building and running the app requires no image-processing dependencies. After replacing the source image, regenerate the artwork and rebuild:

```sh
python3 scripts/generate-icons.py
./scripts/build-mac.sh --run
```

The regeneration script requires Python 3 and Pillow (`python3 -m pip install Pillow`). Xcode uses `Assets.xcassets/AppIcon.appiconset`; the standalone Mac build uses `Resources/AppIcon.icns`.

The main views and storage are deliberately separate so we can build the next small feature without replacing this foundation. Navigation follows Apple’s [SwiftUI split-view guidance](https://developer.apple.com/documentation/technotes/tn3154-adopting-swiftui-navigation-split-view); the embedded reader uses [PDFKit](https://developer.apple.com/documentation/pdfkit).
