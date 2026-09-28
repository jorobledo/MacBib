import CoreGraphics
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Exercises the same item-provider boundary used by dragging a paper in SwiftUI.
@main
@MainActor
struct PaperDragDropTests {
    static func main() async {
        do {
            try await testTransferRoundTripAndPersistence()
            print("PASS: Drag providers move current paper metadata and persist folder assignments")
            try await testMalformedAndUnrelatedProviders()
            print("PASS: Malformed and unrelated drag providers cannot partially move papers")
            try await testStalePaperAndFolder()
            print("PASS: Deleted papers and folders reject drops without changing the library")
            print("All drag-and-drop tests passed.")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func testTransferRoundTripAndPersistence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let providers = fixture.ids.prefix(2).map(provider)
        try expect(providers.allSatisfy {
            $0.registeredTypeIdentifiers.contains(UTType.bibPaper.identifier)
        }, "Paper drag providers must advertise the app's custom type")
        let decoded: PaperDragItem = try await withCheckedThrowingContinuation { continuation in
            _ = providers[0].loadTransferable(type: PaperDragItem.self) { result in
                continuation.resume(with: result)
            }
        }
        try expect(decoded.id == fixture.ids[0], "The transferred ID must survive item-provider encoding")

        // The user can edit metadata while a drag is in progress.
        var edited = try unwrap(fixture.store.papers.first(where: { $0.id == decoded.id }), "Missing paper")
        edited.title = "Title changed after dragging started"
        edited.authors = "Updated author"
        edited.year = "2026"
        edited.venue = "Updated journal"
        edited.doi = "10.0000/updated"
        fixture.store.updatePaper(edited)
        let before = fixture.store.papers
        let expected = before.map { paper in
            var updated = paper
            if fixture.ids.prefix(2).contains(paper.id) { updated.folderID = fixture.folderID }
            return updated
        }

        let moved = await PaperDropTransfer.move(providers, into: fixture.folderID, store: fixture.store)
        try expect(moved && fixture.store.papers == expected,
                   "Decoded drag providers should move only their papers and retain current metadata")
        let reopened = LibraryStore(directory: fixture.directory)
        try expect(reopened.errorMessage == nil && reopened.papers == expected,
                   "Dropped papers must keep their folders and metadata after reopening")
        let unfiled = await PaperDropTransfer.move(providers, into: nil, store: reopened)
        try expect(unfiled && LibraryStore(directory: fixture.directory).papers == before,
                   "Dropping papers on Unfiled must persistently remove only their folder assignments")
    }

    private static func testMalformedAndUnrelatedProviders() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try Snapshot(fixture)
        let malformed = NSItemProvider()
        malformed.registerDataRepresentation(forTypeIdentifier: UTType.bibPaper.identifier,
                                              visibility: .all) { completion in
            completion(Data("{\"id\":\"invalid-uuid\"}".utf8), nil)
            return nil
        }
        let movedMalformed = await PaperDropTransfer.move(
            [provider(fixture.ids[0]), malformed], into: fixture.folderID, store: fixture.store
        )
        try expect(!movedMalformed && fixture.store.errorMessage != nil,
                   "A malformed provider must fail the entire drop with an explanation")
        try before.expectUnchanged(fixture)

        fixture.store.errorMessage = nil
        let text = NSItemProvider(object: fixture.ids[0].uuidString as NSString)
        try expect(!text.hasItemConformingToTypeIdentifier(UTType.bibPaper.identifier),
                   "Plain text must not advertise itself as a Bib paper")
        let movedText = await PaperDropTransfer.move([text], into: fixture.folderID, store: fixture.store)
        try expect(!movedText && fixture.store.errorMessage != nil,
                   "An unrelated plain-text provider must be rejected, even when it contains a paper ID")
        try before.expectUnchanged(fixture)
    }

    private static func testStalePaperAndFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let providers = fixture.ids.prefix(2).map(provider)
        fixture.store.deletePaper(id: fixture.ids[1])
        let afterDeletion = try Snapshot(fixture)
        let movedStale = await PaperDropTransfer.move(providers, into: fixture.folderID, store: fixture.store)
        try expect(!movedStale && fixture.store.errorMessage != nil,
                   "A paper deleted during a drag must reject the whole drop")
        try afterDeletion.expectUnchanged(fixture)

        fixture.store.deleteFolder(id: fixture.folderID)
        let afterFolderDeletion = try Snapshot(fixture)
        let movedToDeleted = await PaperDropTransfer.move(
            [providers[0]], into: fixture.folderID, store: fixture.store
        )
        try expect(!movedToDeleted && fixture.store.errorMessage != nil,
                   "A folder deleted during a drag must reject the drop")
        try afterFolderDeletion.expectUnchanged(fixture)
    }

    private static func provider(_ id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.register(PaperDragItem(id: id))
        return provider
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let directory: URL
        let store: LibraryStore
        let folderID: UUID
        let ids: [UUID]

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("BibDragTests-\(UUID().uuidString)")
            directory = root.appendingPathComponent("Library")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("paper.pdf")
            var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
            let context = try unwrap(CGContext(source as CFURL, mediaBox: &mediaBox, nil),
                                     "Could not create a test PDF")
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0.8, alpha: 1))
            context.fill(CGRect(x: 30, y: 30, width: 240, height: 340))
            context.endPDFPage()
            context.closePDF()
            store = LibraryStore(directory: directory)
            folderID = try unwrap(store.addFolder(named: "Reading"), "Could not add test folder")
            ids = store.importPDFs(from: [source, source, source])
            try expect(ids.count == 3, "Could not import test papers")
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @MainActor
    private struct Snapshot {
        let papers: [Paper]
        let folders: [PaperFolder]
        let savedLibrary: Data

        init(_ fixture: Fixture) throws {
            papers = fixture.store.papers
            folders = fixture.store.folders
            savedLibrary = try Data(contentsOf: fixture.directory.appendingPathComponent("library.json"))
        }

        func expectUnchanged(_ fixture: Fixture) throws {
            let current = try Data(contentsOf: fixture.directory.appendingPathComponent("library.json"))
            try expect(fixture.store.papers == papers && fixture.store.folders == folders && current == savedLibrary,
                       "A rejected drop must preserve in-memory and saved library state")
        }
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
