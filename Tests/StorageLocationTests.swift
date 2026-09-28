import CoreGraphics
import Foundation
import PDFKit

/// Exercises migration and storage transactions entirely inside temporary test libraries.
@main
@MainActor
struct StorageLocationTests {
    static func main() async {
        do {
            try await testDefaultMigration()
            print("PASS: Existing PDFs migrate to the Documents folder without changing papers or originals")
            try await testChosenFolderPersistenceAndFutureImports()
            print("PASS: Chosen PDF folders persist and receive later local imports, downloads, and attachments")
            try await testRejectedStorageChanges()
            print("PASS: Missing or invalid PDFs and destination collisions retain all existing references and user files")
            try await testFailedSaveRollsBackCopies()
            print("PASS: A failed library save rolls back new copies and retains the previous storage location")
            try await testCorruptLibraryIsProtected()
            print("PASS: Corrupt library data blocks storage migration without changing saved files")
            try await testUnavailableChosenFolder()
            print("PASS: Unavailable chosen folders keep their location and never silently fall back or recreate themselves")
            print("All storage location tests passed.")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func testDefaultMigration() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Library", isDirectory: true)
        let target = root.appendingPathComponent("User Documents/Bib", isDirectory: true)
        let source = root.appendingPathComponent("original.pdf")
        try makePDF(at: source, title: "A paper to migrate")
        let sourceBytes = try Data(contentsOf: source)
        let legacyStore = LibraryStore(directory: directory)
        try expect(sameLocation(legacyStore.defaultStorageFolderURL, directory.appendingPathComponent("Documents")),
                   "Explicit test libraries should keep their own legacy Documents default")
        let folderID = try unwrap(legacyStore.addFolder(named: "Reading"), "Could not add logical folder")
        let paperID = try unwrap(legacyStore.importPDFs(from: [source], into: folderID).first,
                                 "Could not create a legacy paper")
        let referenceID = try unwrap(legacyStore.importMetadata(PaperMetadata(title: "Reference only", doi: "10.1234/reference")),
                                     "Could not create a metadata-only reference")
        let paper = try unwrap(legacyStore.papers.first(where: { $0.id == paperID }), "Missing legacy paper")
        let oldURL = try unwrap(legacyStore.fileURL(for: paper), "Legacy PDF has no file URL")
        let savedPapers = legacyStore.papers
        let savedFolders = legacyStore.folders

        let store = LibraryStore(directory: directory, defaultStorageFolder: target)
        try expect(sameLocation(store.defaultStorageFolderURL, target), "The default destination override should be retained")
        await store.prepareStorageIfNeeded()
        try expect(store.errorMessage == nil && !store.isMovingStorage,
                   "Migration should finish successfully: \(store.errorMessage ?? "")")
        try expect(sameLocation(store.storageFolderURL, target), "Migration should select the Documents destination")
        try expect(store.papers == savedPapers && store.folders == savedFolders,
                   "Migration should preserve identity, metadata, folder assignments, dates, and ordering")
        let migratedURL = try unwrap(store.fileURL(for: paper), "Migrated PDF has no file URL")
        try expect(sameLocation(migratedURL.deletingLastPathComponent(), target),
                   "Readers must resolve PDFs from the new folder after migration")
        try expect(tryData(migratedURL) == sourceBytes && tryData(oldURL) == sourceBytes && tryData(source) == sourceBytes,
                   "Migration should copy exact PDF bytes and retain both legacy and original source files")
        let reference = try unwrap(store.papers.first(where: { $0.id == referenceID }), "Migration lost a reference")
        try expect(store.fileURL(for: reference) == nil && reference.doiURL != nil,
                   "Metadata-only records should keep their DOI without inventing a PDF")

        await store.prepareStorageIfNeeded()
        try expect(store.papers == savedPapers && tryData(migratedURL) == sourceBytes,
                   "A repeated preparation should preserve the completed migration")
        let reopened = LibraryStore(directory: directory, defaultStorageFolder: target)
        await reopened.prepareStorageIfNeeded()
        try expect(reopened.errorMessage == nil && reopened.papers == savedPapers && reopened.folders == savedFolders,
                   "Migrated records and folders should reopen intact")
        try expect(sameLocation(reopened.storageFolderURL, target)
                   && reopened.fileURL(for: paper).map { sameLocation($0, migratedURL) } == true,
                   "A restarted app should continue reading the migrated folder")
    }

    private static func testChosenFolderPersistenceAndFutureImports() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Library", isDirectory: true)
        let target = root.appendingPathComponent("Chosen Papers", isDirectory: true)
        let source = root.appendingPathComponent("paper.pdf")
        try makePDF(at: source, title: "Original title")
        let bytes = try Data(contentsOf: source)
        let store = LibraryStore(directory: directory)
        let firstID = try unwrap(store.importPDFs(from: [source]).first, "Could not import first paper")
        let firstPaper = try unwrap(store.papers.first(where: { $0.id == firstID }), "Missing first paper")
        let oldURL = try unwrap(store.fileURL(for: firstPaper), "Missing old file URL")
        let folderID = try unwrap(store.addFolder(named: "Later"), "Could not add folder")
        let referenceID = try unwrap(store.importMetadata(PaperMetadata(title: "Attach later", doi: "10.1234/later"), into: folderID),
                                     "Could not add reference for attachment")
        let beforeSwitch = store.papers
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let unrelatedURL = target.appendingPathComponent("user-notes.txt")
        let unrelatedBytes = Data("Existing user file".utf8)
        try unrelatedBytes.write(to: unrelatedURL)

        let didChange = await store.changeStorageFolder(to: target)
        try expect(didChange && store.errorMessage == nil && !store.isMovingStorage,
                   "Changing to a valid folder should finish successfully: \(store.errorMessage ?? "")")
        try expect(sameLocation(store.storageFolderURL, target) && store.papers == beforeSwitch,
                   "A location change should update storage without altering papers")
        try expect(tryData(oldURL) == bytes && tryData(unrelatedURL) == unrelatedBytes,
                   "Switching folders should preserve old PDFs and unrelated destination files")

        let localID = try unwrap(store.importPDFs(from: [source], into: folderID).first,
                                 "Local import failed in selected storage")
        let downloadID = try unwrap(store.importDownloadedPDF(from: source, metadata: PaperMetadata(title: "Downloaded paper")),
                                    "Downloaded import failed in selected storage")
        try expect(store.attachPDF(from: source, to: referenceID), "Attaching a PDF should work in selected storage")
        for id in [firstID, localID, downloadID, referenceID] {
            let paper = try unwrap(store.papers.first(where: { $0.id == id }), "An imported paper is missing")
            let url = try unwrap(store.fileURL(for: paper), "An imported paper has no PDF URL")
            try expect(sameLocation(url.deletingLastPathComponent(), target) && tryData(url) == bytes,
                       "Existing PDFs, local imports, downloads, and attachments must all use the selected folder")
        }
        let attached = try unwrap(store.papers.first(where: { $0.id == referenceID }), "Missing attached reference")
        try expect(attached.title == "Attach later" && attached.doi == "10.1234/later" && attached.folderID == folderID,
                   "Attachment should retain reference metadata and folder")
        let reopened = LibraryStore(directory: directory)
        await reopened.prepareStorageIfNeeded()
        try expect(reopened.errorMessage == nil && sameLocation(reopened.storageFolderURL, target)
                   && reopened.papers == store.papers && reopened.folders == store.folders,
                   "A selected folder and every paper should persist independently of the default location")
        try expect(tryData(source) == bytes, "No storage operation should modify the source PDF")
    }

    private static func testRejectedStorageChanges() async throws {
        for failure in ["missing", "invalid", "collision"] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appendingPathComponent("Library", isDirectory: true)
            let target = root.appendingPathComponent("Destination", isDirectory: true)
            let source = root.appendingPathComponent("paper.pdf")
            try makePDF(at: source, title: "A valid source")
            let store = LibraryStore(directory: directory)
            let ids = store.importPDFs(from: [source, source])
            try expect(ids.count == 2, "Could not seed safety test")
            let originalPapers = store.papers
            let originalLocation = store.storageFolderURL
            let libraryURL = directory.appendingPathComponent("library.json")
            let originalLibrary = try Data(contentsOf: libraryURL)
            let badPaper = try unwrap(store.papers.first(where: { $0.id == ids[0] }), "Missing source paper")
            let badURL = try unwrap(store.fileURL(for: badPaper), "Missing source file URL")
            let healthyPaper = try unwrap(store.papers.first(where: { $0.id == ids[1] }), "Missing healthy paper")
            let healthyURL = try unwrap(store.fileURL(for: healthyPaper), "Missing healthy file URL")
            let healthyBytes = try Data(contentsOf: healthyURL)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let unrelatedURL = target.appendingPathComponent("keep-me.txt")
            try Data("Unrelated file".utf8).write(to: unrelatedURL)
            if failure == "missing" {
                try FileManager.default.removeItem(at: badURL)
            } else if failure == "invalid" {
                try Data("Damaged PDF".utf8).write(to: badURL)
            } else {
                let collisionURL = target.appendingPathComponent(badURL.lastPathComponent)
                try makePDF(at: collisionURL, title: "Another user's existing PDF")
            }
            let destinationBefore = try snapshotFiles(in: target)
            let existingSourceBytes = try? Data(contentsOf: badURL)

            let didChange = await store.changeStorageFolder(to: target)
            try expect(!didChange && store.errorMessage != nil && !store.isMovingStorage,
                       "A \(failure) must fail without leaving a running move")
            try expect(sameLocation(store.storageFolderURL, originalLocation) && store.papers == originalPapers,
                       "A \(failure) must retain all current in-memory references")
            let libraryAfter = try Data(contentsOf: libraryURL)
            let destinationAfter = try snapshotFiles(in: target)
            try expect(libraryAfter == originalLibrary && destinationAfter == destinationBefore,
                       "A \(failure) must preserve the saved location and user files and remove tentative copies")
            try expect(tryData(healthyURL) == healthyBytes && (try? Data(contentsOf: badURL)) == existingSourceBytes,
                       "A failed \(failure) move must preserve every remaining source file")
        }
    }

    private static func testFailedSaveRollsBackCopies() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Library", isDirectory: true)
        let target = root.appendingPathComponent("Destination", isDirectory: true)
        let source = root.appendingPathComponent("paper.pdf")
        try makePDF(at: source)
        let store = LibraryStore(directory: directory)
        let paperID = try unwrap(store.importPDFs(from: [source]).first, "Could not seed failed-save test")
        let paper = try unwrap(store.papers.first(where: { $0.id == paperID }), "Missing source paper")
        let sourceURL = try unwrap(store.fileURL(for: paper), "Missing source file URL")
        let sourceBytes = try Data(contentsOf: sourceURL)
        let originalLocation = store.storageFolderURL
        let originalPapers = store.papers
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let userFile = target.appendingPathComponent("notes.txt")
        try Data("Keep these notes".utf8).write(to: userFile)
        let destinationBefore = try snapshotFiles(in: target)
        let libraryURL = directory.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: libraryURL)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: false)

        let didChange = await store.changeStorageFolder(to: target)
        let destinationAfter = try snapshotFiles(in: target)
        try expect(!didChange && store.errorMessage != nil && !store.isMovingStorage,
                   "A failed JSON save must fail the move and clear its busy state")
        try expect(sameLocation(store.storageFolderURL, originalLocation) && store.papers == originalPapers,
                   "A failed JSON save must not publish a new storage location or paper state")
        try expect(destinationAfter == destinationBefore && tryData(sourceURL) == sourceBytes,
                   "A failed JSON save must remove new copies while preserving source PDFs and existing user files")
    }

    private static func testCorruptLibraryIsProtected() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Library", isDirectory: true)
        let legacyFolder = directory.appendingPathComponent("Documents", isDirectory: true)
        let defaultTarget = root.appendingPathComponent("User Documents/Bib", isDirectory: true)
        let chosenTarget = root.appendingPathComponent("Chosen Papers", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        let legacyPDF = legacyFolder.appendingPathComponent("keep.pdf")
        try makePDF(at: legacyPDF)
        let legacyBytes = try Data(contentsOf: legacyPDF)
        let libraryURL = directory.appendingPathComponent("library.json")
        let corruptBytes = Data("{corrupt library".utf8)
        try corruptBytes.write(to: libraryURL)
        let store = LibraryStore(directory: directory, defaultStorageFolder: defaultTarget)
        try expect(store.errorMessage != nil, "A corrupt library must report its load failure")
        let locationBefore = store.storageFolderURL

        await store.prepareStorageIfNeeded()
        let didChange = await store.changeStorageFolder(to: chosenTarget)
        try expect(!didChange && store.errorMessage != nil && !store.isMovingStorage,
                   "A corrupt library must block both automatic and selected storage changes")
        try expect(sameLocation(store.storageFolderURL, locationBefore) && tryData(libraryURL) == corruptBytes
                   && tryData(legacyPDF) == legacyBytes,
                   "A corrupt library must preserve its original JSON and PDFs")
        try expect(!FileManager.default.fileExists(atPath: chosenTarget.path),
                   "A blocked storage change should not create a chosen destination")
    }

    private static func testUnavailableChosenFolder() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Library", isDirectory: true)
        let target = root.appendingPathComponent("Removable Papers", isDirectory: true)
        let disconnected = root.appendingPathComponent("Disconnected Papers", isDirectory: true)
        let unusedDefault = root.appendingPathComponent("Another Documents/Bib", isDirectory: true)
        let source = root.appendingPathComponent("source.pdf")
        try makePDF(at: source)
        let store = LibraryStore(directory: directory)
        let paperID = try unwrap(store.importPDFs(from: [source]).first, "Could not seed unavailable-storage test")
        let referenceID = try unwrap(store.importMetadata(PaperMetadata(title: "Attach when available", doi: "10.1234/reference")),
                                     "Could not create attachment reference")
        let changed = await store.changeStorageFolder(to: target)
        try expect(changed, "Could not set selected storage before disconnecting it")
        let savedPapers = store.papers
        let libraryURL = directory.appendingPathComponent("library.json")
        let savedLibrary = try Data(contentsOf: libraryURL)
        // Remove the original directory's identity: a bookmark can follow a simple rename.
        try FileManager.default.copyItem(at: target, to: disconnected)
        try FileManager.default.removeItem(at: target)

        let reopened = LibraryStore(directory: directory, defaultStorageFolder: unusedDefault)
        await reopened.prepareStorageIfNeeded()
        try expect(sameLocation(reopened.storageFolderURL, target) && reopened.papers == savedPapers,
                   "An unavailable selected folder must keep its location and loaded reference metadata")
        try expect(reopened.errorMessage != nil || reopened.storageMessage != nil,
                   "An unavailable selected folder should explain the storage problem")
        try expect(!FileManager.default.fileExists(atPath: target.path)
                   && !FileManager.default.fileExists(atPath: unusedDefault.path),
                   "Reopening must not silently recreate or replace unavailable selected storage")
        try expect(reopened.importPDFs(from: [source]).isEmpty && !reopened.attachPDF(from: source, to: referenceID),
                   "PDF imports and attachments must fail while selected storage is unavailable")
        try expect(reopened.papers == savedPapers && tryData(libraryURL) == savedLibrary,
                   "Failed imports into unavailable storage should preserve metadata and saved storage selection")
        try expect(!FileManager.default.fileExists(atPath: target.path),
                   "A failed import must not recreate an unavailable folder")
        let paper = try unwrap(reopened.papers.first(where: { $0.id == paperID }), "Missing unavailable paper")
        if let url = reopened.fileURL(for: paper) {
            try expect(sameLocation(url.deletingLastPathComponent(), target),
                       "An unavailable PDF URL must never redirect to a retained legacy copy")
        }
        try expect(FileManager.default.fileExists(atPath: disconnected.path),
                   "Unavailable-storage handling must leave the disconnected PDF copy untouched")
    }

    private static func makePDF(at url: URL, title: String = "Storage test paper") throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        let metadata = [kCGPDFContextTitle as String: title]
        let context = try unwrap(CGContext(url as CFURL, mediaBox: &mediaBox, metadata as CFDictionary),
                                 "Could not create test PDF")
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 30, y: 30, width: 240, height: 340))
        context.endPDFPage()
        context.closePDF()
    }

    private static func snapshotFiles(in directory: URL) throws -> [String: Data] {
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var result: [String: Data] = [:]
        for url in contents {
            result[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return result
    }

    private static func sameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path
            == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func tryData(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BibStorageTests-\(UUID().uuidString)")
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
