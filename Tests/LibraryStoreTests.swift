import CoreGraphics
import Foundation
import PDFKit

/// Run with the application's model sources; no app launch or signing is required.
@main
@MainActor
struct LibraryStoreTests {
    static func main() {
        do {
            try testImportAndPersistence()
            print("PASS: PDF import, metadata, persistence, folder changes, and deletion")
            try testDownloadedPDFMetadataAndPersistence()
            print("PASS: Downloaded PDFs save fetched metadata and folder assignments together")
            try testDownloadedPDFFallbackMetadata()
            print("PASS: Missing and blank fetched metadata retain PDF metadata and filename fallbacks")
            try testDownloadedPDFRejectsDeletedFolder()
            print("PASS: Downloaded PDFs reject folders deleted while retrieval was in progress")
            try testDownloadedPDFFailedSaveCleansUp()
            print("PASS: Failed download imports leave no published paper or managed copy")
            try testMovePapersAndPersistence()
            print("PASS: Batch moves persist and retain paper metadata, order, and PDF files")
            try testRejectedMovesAreAtomic()
            print("PASS: Empty and stale paper or folder moves are rejected without partial changes")
            try testFailedSaveKeepsStateAndFiles()
            print("PASS: Failed saves preserve state and files and clean up failed imports")
            try testCorruptLibraryIsProtected()
            print("PASS: Corrupt library data is never overwritten")
            try testInvalidAndLockedPDFs()
            print("PASS: Invalid and password-protected PDFs are rejected independently")
            print("All library tests passed.")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func testImportAndPersistence() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.pdf")
        let fallbackSource = root.appendingPathComponent("Fallback title.pdf")
        try makePDF(at: source, title: "A useful paper", author: "Ada Example")
        try makePDF(at: fallbackSource)

        let directory = root.appendingPathComponent("Library")
        let store = LibraryStore(directory: directory)
        let folderID = try unwrap(store.addFolder(named: "  Reading  "), "Could not add folder")
        try expect(store.folders.first?.name == "Reading", "Folder names should be trimmed")
        try expect(store.addFolder(named: "reading") == nil, "Duplicate folder names should be rejected")

        let ids = store.importPDFs(from: [source, fallbackSource], into: folderID)
        try expect(ids.count == 2, "Expected both PDFs to import: \(store.errorMessage ?? "")")
        var paper = try unwrap(store.papers.first(where: { $0.id == ids[0] }), "Missing imported paper")
        try expect(paper.title == "A useful paper", "PDF title should be extracted")
        try expect(paper.authors == "Ada Example", "PDF author should be extracted")
        try expect(store.papers.first(where: { $0.id == ids[1] })?.title == "Fallback title",
                   "A missing PDF title should use the filename")
        let managedURL = store.fileURL(for: paper)
        try expect(managedURL != source && FileManager.default.fileExists(atPath: managedURL.path),
                   "The PDF should have its own managed copy")

        paper.title = "Edited title"
        paper.year = "2026"
        paper.venue = "Example Journal"
        paper.doi = "10.0000/example"
        store.updatePaper(paper)
        store.renameFolder(id: folderID, to: "Favorites")

        let reopened = LibraryStore(directory: directory)
        try expect(reopened.errorMessage == nil, "Saved library should reopen cleanly")
        try expect(reopened.papers == store.papers, "All metadata should survive reopening")
        try expect(reopened.folders == store.folders && reopened.folders[0].name == "Favorites",
                   "Folder renaming should persist")
        reopened.deleteFolder(id: folderID)
        try expect(reopened.folders.isEmpty && reopened.papers.allSatisfy { $0.folderID == nil },
                   "Deleting a folder should unfile its papers")
        try expect(FileManager.default.fileExists(atPath: managedURL.path),
                   "Deleting a folder must retain the PDF")
        let afterFolderDeletion = LibraryStore(directory: directory)
        try expect(afterFolderDeletion.folders.isEmpty && afterFolderDeletion.papers.count == 2,
                   "Folder deletion should persist without deleting papers")

        afterFolderDeletion.deletePaper(id: paper.id)
        try expect(!FileManager.default.fileExists(atPath: managedURL.path), "Deleting a paper should remove its managed copy")
        try expect(FileManager.default.fileExists(atPath: source.path), "The source PDF must remain untouched")
        try expect(LibraryStore(directory: directory).papers.count == 1, "Paper deletion should persist")
    }

    private static func testDownloadedPDFMetadataAndPersistence() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("downloaded.pdf")
        try makePDF(at: source, title: "Embedded title", author: "Embedded author")
        let sourceBytes = try Data(contentsOf: source)
        let directory = root.appendingPathComponent("Library")
        let store = LibraryStore(directory: directory)
        let folderID = try unwrap(store.addFolder(named: "Reading"), "Could not add destination folder")
        let metadata = PaperMetadata(
            title: "  A fetched paper\n",
            authors: "  Ada Example; Grace Example  ",
            year: " 2026 ",
            venue: " Example Journal\n",
            doi: " 10.0000/fetched "
        )

        let id = try unwrap(store.importDownloadedPDF(from: source, metadata: metadata, into: folderID),
                            "Could not import downloaded PDF: \(store.errorMessage ?? "")")
        let paper = try unwrap(store.papers.first(where: { $0.id == id }), "Downloaded paper is missing")
        try expect(paper.title == "A fetched paper" && paper.authors == "Ada Example; Grace Example"
                   && paper.year == "2026" && paper.venue == "Example Journal" && paper.doi == "10.0000/fetched",
                   "Nonempty fetched metadata should override PDF metadata and be trimmed")
        try expect(paper.folderID == folderID, "The downloaded paper should be assigned to the chosen folder")
        let managedURL = store.fileURL(for: paper)
        let managedBytes = try Data(contentsOf: managedURL)
        let sourceAfterImport = try Data(contentsOf: source)
        try expect(managedURL != source && managedBytes == sourceBytes && sourceAfterImport == sourceBytes,
                   "Download import should copy the PDF without changing the original download")
        let reopened = LibraryStore(directory: directory)
        try expect(reopened.errorMessage == nil && reopened.papers == [paper] && reopened.folders == store.folders,
                   "Fetched metadata and its folder must survive reopening the library")
    }

    private static func testDownloadedPDFFallbackMetadata() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let embedded = root.appendingPathComponent("downloaded.pdf")
        let untitled = root.appendingPathComponent("Filename fallback.pdf")
        try makePDF(at: embedded, title: " Embedded title ", author: " Embedded author ")
        try makePDF(at: untitled)
        let store = LibraryStore(directory: root.appendingPathComponent("Library"))
        let blank = PaperMetadata(title: " \n ", authors: "\t ", year: " ", venue: "\n", doi: " \t ")

        for metadata in [nil, blank] as [PaperMetadata?] {
            let id = try unwrap(store.importDownloadedPDF(from: embedded, metadata: metadata),
                                "Could not import PDF with fallback metadata")
            let paper = try unwrap(store.papers.first(where: { $0.id == id }), "Missing fallback paper")
            try expect(paper.title == "Embedded title" && paper.authors == "Embedded author",
                       "Nil and blank fetched values should preserve trimmed embedded metadata")
            try expect(paper.year.isEmpty && paper.venue.isEmpty && paper.doi.isEmpty && paper.folderID == nil,
                       "Unavailable metadata should remain empty and the paper should be in the unfiled library")
            let untitledID = try unwrap(store.importDownloadedPDF(from: untitled, metadata: metadata),
                                        "Could not import PDF without embedded metadata")
            let untitledPaper = try unwrap(store.papers.first(where: { $0.id == untitledID }), "Missing untitled paper")
            try expect(untitledPaper.title == "Filename fallback" && untitledPaper.authors.isEmpty,
                       "A PDF without metadata should fall back to its filename")
        }

        let partialID = try unwrap(store.importDownloadedPDF(from: embedded, metadata: PaperMetadata(year: "2025")),
                                   "Could not import PDF with partial metadata")
        let partialPaper = try unwrap(store.papers.first(where: { $0.id == partialID }), "Missing partial metadata paper")
        try expect(partialPaper.title == "Embedded title" && partialPaper.authors == "Embedded author"
                   && partialPaper.year == "2025",
                   "Fallbacks should apply independently to each fetched metadata field")
    }

    private static func testDownloadedPDFRejectsDeletedFolder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("downloaded.pdf")
        try makePDF(at: source)
        let directory = root.appendingPathComponent("Library")
        let store = LibraryStore(directory: directory)
        let destinationID = try unwrap(store.addFolder(named: "Reading"), "Could not add destination folder")
        // The user can delete the chosen destination before an asynchronous download finishes.
        store.deleteFolder(id: destinationID)
        let libraryURL = directory.appendingPathComponent("library.json")
        let originalLibrary = try Data(contentsOf: libraryURL)

        let id = store.importDownloadedPDF(from: source, metadata: PaperMetadata(title: "Fetched title"),
                                           into: destinationID)
        try expect(id == nil && store.errorMessage?.contains("folder no longer exists") == true,
                   "A deleted destination must fail with an actionable error")
        let libraryAfterImport = try Data(contentsOf: libraryURL)
        let managedFiles = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Documents").path)
        try expect(store.papers.isEmpty && store.folders.isEmpty && libraryAfterImport == originalLibrary,
                   "A stale destination must leave all library state unchanged")
        try expect(managedFiles.isEmpty && FileManager.default.fileExists(atPath: source.path),
                   "A rejected destination must not copy or delete the downloaded PDF")
    }

    private static func testDownloadedPDFFailedSaveCleansUp() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("downloaded.pdf")
        try makePDF(at: source, title: "Embedded title", author: "Embedded author")
        let sourceBytes = try Data(contentsOf: source)
        let directory = root.appendingPathComponent("Library")
        let store = LibraryStore(directory: directory)
        let folderID = try unwrap(store.addFolder(named: "Reading"), "Could not add destination folder")
        let originalFolders = store.folders
        let libraryURL = directory.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: libraryURL)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: false)

        let id = store.importDownloadedPDF(from: source,
                                           metadata: PaperMetadata(title: "Fetched title", authors: "Fetched author", year: "2026"),
                                           into: folderID)
        try expect(id == nil && store.errorMessage != nil && store.papers.isEmpty && store.folders == originalFolders,
                   "A failed JSON save must retain the previous in-memory library without publishing downloaded metadata")
        let managedFiles = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Documents").path)
        let sourceAfterImport = try Data(contentsOf: source)
        try expect(managedFiles.isEmpty && sourceAfterImport == sourceBytes,
                   "A failed download import must remove its managed copy and preserve the original PDF")
    }

    private static func testMovePapersAndPersistence() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("paper.pdf")
        try makePDF(at: source, title: "Original title", author: "Original author")
        let directory = root.appendingPathComponent("Library")
        let store = LibraryStore(directory: directory)
        let readingID = try unwrap(store.addFolder(named: "Reading"), "Could not add source folder")
        let favoriteID = try unwrap(store.addFolder(named: "Favorites"), "Could not add destination folder")
        let ids = store.importPDFs(from: [source, source, source], into: readingID)
        try expect(ids.count == 3, "Could not import papers for moving")

        // Metadata may be edited after a drag begins; moves must use the latest records.
        var edited = try unwrap(store.papers.first(where: { $0.id == ids[0] }), "Missing paper")
        edited.title = "Current title"
        edited.authors = "Current author"
        edited.year = "2026"
        edited.venue = "Current journal"
        edited.doi = "10.0000/current"
        store.updatePaper(edited)
        let originalPapers = store.papers
        let originalFolders = store.folders
        let originalFiles = try Dictionary(uniqueKeysWithValues: originalPapers.map {
            ($0.id, try Data(contentsOf: store.fileURL(for: $0)))
        })

        try expect(store.movePapers(ids: [ids[0], ids[1], ids[0]], to: favoriteID),
                   "Moving multiple papers with duplicate IDs should succeed")
        var expectedPapers = originalPapers.map { paper in
            var updated = paper
            if ids.prefix(2).contains(paper.id) { updated.folderID = favoriteID }
            return updated
        }
        try expect(store.papers == expectedPapers && store.folders == originalFolders,
                   "Moves should retain every paper, order, metadata, and folder")
        let reopened = LibraryStore(directory: directory)
        try expect(reopened.errorMessage == nil && reopened.papers == expectedPapers,
                   "All moved papers should retain their assignments after reopening")
        try expect(reopened.movePapers(ids: [ids[1]], to: nil), "A moved paper should be able to become unfiled")
        let unfiledIndex = try unwrap(expectedPapers.firstIndex(where: { $0.id == ids[1] }), "Missing expected paper")
        expectedPapers[unfiledIndex].folderID = nil
        let afterUnfiling = LibraryStore(directory: directory)
        try expect(afterUnfiling.papers == expectedPapers, "Unfiling should persist without other metadata changes")
        for paper in originalPapers {
            let current = try unwrap(afterUnfiling.papers.first(where: { $0.id == paper.id }), "Move lost a paper")
            let url = afterUnfiling.fileURL(for: current)
            let bytes = try Data(contentsOf: url)
            try expect(url == store.fileURL(for: paper) && bytes == originalFiles[paper.id],
                       "Moving papers must preserve each managed PDF's path and bytes")
        }
    }

    private static func testRejectedMovesAreAtomic() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("paper.pdf")
        try makePDF(at: source)
        let directory = root.appendingPathComponent("Library")
        let store = LibraryStore(directory: directory)
        let folderID = try unwrap(store.addFolder(named: "Reading"), "Could not add destination folder")
        let deletedFolderID = try unwrap(store.addFolder(named: "Removed"), "Could not add temporary folder")
        let ids = store.importPDFs(from: [source, source])
        try expect(ids.count == 2, "Could not import papers for stale move test")
        store.deletePaper(id: ids[0])
        store.deleteFolder(id: deletedFolderID)
        let originalPapers = store.papers
        let originalFolders = store.folders
        let libraryURL = directory.appendingPathComponent("library.json")
        let originalData = try Data(contentsOf: libraryURL)

        try expect(!store.movePapers(ids: ids, to: folderID) && store.errorMessage != nil,
                   "A deleted paper should reject the entire batch with an explanation")
        try expect(store.papers == originalPapers, "A stale batch must not move its remaining valid papers")
        try expect(!store.movePapers(ids: [ids[1]], to: deletedFolderID) && store.errorMessage != nil,
                   "Moving to a deleted folder should fail with an explanation")
        try expect(!store.movePapers(ids: [], to: folderID) && store.errorMessage != nil,
                   "An empty move should be rejected with an explanation")
        let afterAttempts = try Data(contentsOf: libraryURL)
        try expect(store.papers == originalPapers && store.folders == originalFolders && afterAttempts == originalData,
                   "Rejected moves must leave in-memory and saved library state unchanged")
    }

    private static func testFailedSaveKeepsStateAndFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("paper.pdf")
        try makePDF(at: source)
        let directory = root.appendingPathComponent("Library")
        let store = LibraryStore(directory: directory)
        let folderID = try unwrap(store.addFolder(named: "Reading"), "Could not add folder")
        let ids = store.importPDFs(from: [source, source], into: folderID)
        try expect(ids.count == 2, "Could not import papers for failed save test")
        let paper = try unwrap(store.papers.first, "Could not import test PDF")
        let originalPapers = store.papers
        let originalFolders = store.folders
        let libraryURL = directory.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: libraryURL)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: false)

        try expect(store.movePapers(ids: ids, to: folderID),
                   "Moving to the existing destination should succeed without attempting a disk write")
        try expect(!store.movePapers(ids: ids, to: nil) && store.errorMessage != nil,
                   "A failed batch move save should be reported")
        try expect(store.papers == originalPapers && store.folders == originalFolders,
                   "A failed batch move must preserve every paper's previous folder assignment")
        store.renameFolder(id: folderID, to: "Changed")
        try expect(store.folders == originalFolders && store.errorMessage != nil,
                   "A failed save must not publish a folder rename")
        store.deletePaper(id: paper.id)
        try expect(store.papers == originalPapers, "A failed save must not remove paper metadata")
        try expect(FileManager.default.fileExists(atPath: store.fileURL(for: paper).path),
                   "A failed save must not delete an existing PDF")
        let imported = store.importPDFs(from: [source])
        try expect(imported.isEmpty && store.papers == originalPapers, "Failed imports must leave metadata untouched")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Documents").path)
        try expect(Set(files) == Set(originalPapers.map(\.fileName)), "A failed import must clean up its copied PDF")
    }

    private static func testCorruptLibraryIsProtected() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryURL = root.appendingPathComponent("library.json")
        let corrupt = Data("existing but unreadable library".utf8)
        try corrupt.write(to: libraryURL)
        let store = LibraryStore(directory: root)
        try expect(store.errorMessage != nil, "A corrupt library should explain the problem")
        store.errorMessage = nil
        try expect(store.addFolder(named: "Must not overwrite") == nil, "Edits must be blocked after a loading failure")
        try expect(store.errorMessage != nil, "Dismissing the error must not unlock a corrupt library")
        try expect(!store.movePapers(ids: [UUID()], to: nil) && store.errorMessage != nil,
                   "Paper moves must also be blocked after a library loading failure")
        let afterAttempt = try Data(contentsOf: libraryURL)
        try expect(afterAttempt == corrupt, "Corrupt library bytes must remain untouched")
    }

    private static func testInvalidAndLockedPDFs() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = root.appendingPathComponent("valid.pdf")
        let invalid = root.appendingPathComponent("invalid.pdf")
        let locked = root.appendingPathComponent("locked.pdf")
        try makePDF(at: valid)
        try Data("not a PDF".utf8).write(to: invalid)
        let document = try unwrap(PDFDocument(url: valid), "Could not create a locked test PDF")
        try expect(document.write(to: locked, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]),
                   "Could not write locked test PDF")

        let store = LibraryStore(directory: root.appendingPathComponent("Library"))
        let imported = store.importPDFs(from: [invalid, valid, locked])
        try expect(imported.count == 1 && store.papers.count == 1, "Valid files should import even when other files fail")
        try expect(store.errorMessage?.contains("invalid.pdf") == true, "The invalid file should be identified")
        try expect(store.errorMessage?.contains("locked.pdf") == true, "The locked file should be identified")
        try expect(store.errorMessage?.contains("password protected") == true, "Locked PDFs should explain how to resolve the issue")
    }

    private static func makePDF(at url: URL, title: String? = nil, author: String? = nil) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        var metadata: [String: String] = [:]
        metadata[kCGPDFContextTitle as String] = title
        metadata[kCGPDFContextAuthor as String] = author
        let context = try unwrap(CGContext(url as CFURL, mediaBox: &mediaBox, metadata as CFDictionary),
                                 "Could not create test PDF")
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 30, y: 30, width: 240, height: 340))
        context.endPDFPage()
        context.closePDF()
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BibTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(message: message) }
    }

    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw TestFailure(message: message) }
        return value
    }

    private struct TestFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
