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

    private static func testFailedSaveKeepsStateAndFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("paper.pdf")
        try makePDF(at: source)
        let directory = root.appendingPathComponent("Library")
        let store = LibraryStore(directory: directory)
        let folderID = try unwrap(store.addFolder(named: "Reading"), "Could not add folder")
        _ = store.importPDFs(from: [source], into: folderID)
        let paper = try unwrap(store.papers.first, "Could not import test PDF")
        let originalPapers = store.papers
        let originalFolders = store.folders
        let libraryURL = directory.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: libraryURL)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: false)

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
        try expect(files == [paper.fileName], "A failed import must clean up its copied PDF")
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
