import CoreGraphics
import Foundation

/// Offline coordinator tests: delayed responses make edits, cancellation, and queued imports observable.
@main
@MainActor
struct PDFMetadataLookupTests {
    static func main() async {
        do {
            try await testSavedCopiesAndQueuedImports()
            print("PASS: Metadata lookup uses saved PDFs and includes imports added to an active queue")
            try await testUnavailableResultsKeepImports()
            print("PASS: Failed and unmatched lookups retain imports while successful results persist")
            try await testCancellationAndNewImport()
            print("PASS: Cancellation drops queued work and late responses cannot affect a new import")
            try await testEditsAndDeletionDuringLookup()
            print("PASS: Delayed metadata preserves user edits and moves without restoring deleted papers")
            print("All PDF metadata lookup tests passed.")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func testSavedCopiesAndQueuedImports() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("first.pdf")
        try makePDF(at: source, title: "Embedded title", author: "Embedded author")
        let sourceBytes = try Data(contentsOf: source)
        let directory = root.appendingPathComponent("Library")
        let store = LibraryStore(directory: directory)
        let firstID = try unwrap(store.importPDFs(from: [source]).first, "First PDF did not import")
        let referenceID = try unwrap(store.importMetadata(PaperMetadata(title: "Reference only")),
                                     "Could not create metadata-only reference")
        let first = try paper(firstID, in: store)
        let managedURL = try unwrap(store.fileURL(for: first), "First PDF has no managed URL")
        try FileManager.default.removeItem(at: source)

        let probe = LookupProbe()
        let lookup = PDFMetadataLookup { try await probe.lookup(url: $0, title: $1, authors: $2) }
        lookup.enqueue(paperIDs: [firstID, referenceID, UUID()], in: store)
        try expect(lookup.isSearching && lookup.totalCount == 1 && lookup.completedCount == 0,
                   "Only existing records with PDFs should start a search")
        try await waitUntil("First lookup did not start") { await probe.count == 1 }
        let request = try unwrap(await probe.request(at: 0), "First request is missing")
        try expect(request.url == managedURL && request.bytes == sourceBytes && request.url != source,
                   "Retrieval must read the managed copy after the source is removed")
        try expect(request.title == "Embedded title" && request.authors == "Embedded author",
                   "Retrieval should receive the imported PDF's fallback title and authors")

        let secondSource = root.appendingPathComponent("Second filename.pdf")
        try makePDF(at: secondSource)
        let secondID = try unwrap(store.importPDFs(from: [secondSource]).first, "Second PDF did not import")
        try FileManager.default.removeItem(at: secondSource)
        lookup.enqueue(paperIDs: [secondID], in: store)
        try expect(lookup.totalCount == 2 && lookup.completedCount == 0,
                   "A second import should join the current progress total")
        await probe.resolve(0, with: .success(PaperMetadata(title: "Retrieved first", year: "2025")))
        try await waitUntil("Queued lookup did not start") { await probe.count == 2 }
        try expect(lookup.isSearching && lookup.completedCount == 1,
                   "Finishing one request must not finish the active queue")
        let secondRequest = try unwrap(await probe.request(at: 1), "Second request is missing")
        try expect(secondRequest.title == "Second filename", "Filename fallbacks should reach metadata search")
        await probe.resolve(1, with: .success(PaperMetadata(title: "Retrieved second", doi: "10.1234/second")))
        try await waitUntil("Queued lookups did not finish") { !lookup.isSearching }
        try expect(lookup.completedCount == 2 && lookup.totalCount == 2 && lookup.notice == nil,
                   "All-success progress should finish without an unavailable notice")
        try expect(try paper(firstID, in: store).title == "Retrieved first",
                   "The first response should enrich the saved import")
        try expect(try paper(secondID, in: store).doi == "10.1234/second",
                   "The queued response should enrich its own import")
        let afterBytes = try Data(contentsOf: managedURL)
        try expect(afterBytes == sourceBytes && LibraryStore(directory: directory).papers == store.papers,
                   "Retrieved metadata should persist without changing PDF bytes")
    }

    private static func testUnavailableResultsKeepImports() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("paper.pdf")
        try makePDF(at: source, title: "Local title", author: "Local author")
        let store = LibraryStore(directory: root.appendingPathComponent("Library"))
        let ids = store.importPDFs(from: [source, source, source])
        try expect(ids.count == 3, "Could not create mixed-result imports")
        let originals = store.papers
        let probe = LookupProbe()
        let lookup = PDFMetadataLookup { try await probe.lookup(url: $0, title: $1, authors: $2) }
        lookup.enqueue(paperIDs: ids, in: store)
        try await waitUntil("First mixed-result request did not start") { await probe.count == 1 }
        await probe.resolve(0, with: .success(nil))
        try await waitUntil("Error request did not start") { await probe.count == 2 }
        await probe.resolve(1, with: .failure(URLError(.notConnectedToInternet)))
        try await waitUntil("Success after error did not start") { await probe.count == 3 }
        await probe.resolve(2, with: .success(PaperMetadata(title: "Online title", authors: "Online author")))
        try await waitUntil("Mixed-result lookups did not finish") { !lookup.isSearching }
        try expect(lookup.completedCount == 3 && lookup.totalCount == 3,
                   "Unmatched and failed requests should still finish their progress entries")
        try expect(lookup.notice?.contains("2 imported PDFs") == true,
                   "The notice should count unavailable metadata separately from successful matches")
        for id in ids.prefix(2) {
            try expect(try paper(id, in: store) == originals.first(where: { $0.id == id }),
                       "Unavailable metadata must preserve the original record")
        }
        try expect(try paper(ids[2], in: store).title == "Online title" && store.errorMessage == nil,
                   "A lookup failure must not prevent subsequent success or become an import failure")
        for saved in store.papers {
            let url = try unwrap(store.fileURL(for: saved), "An import lost its PDF URL")
            try expect(FileManager.default.fileExists(atPath: url.path), "All local PDFs must remain saved")
        }

        lookup.enqueue(paperIDs: [ids[0]], in: store)
        try expect(lookup.notice == nil && lookup.completedCount == 0 && lookup.totalCount == 1,
                   "A later batch should clear stale notices and progress")
        try await waitUntil("Later batch did not start") { await probe.count == 4 }
        await probe.resolve(3, with: .success(nil))
        try await waitUntil("Later batch did not finish") { !lookup.isSearching }
        try expect(lookup.notice?.contains("1 imported PDF.") == true,
                   "A new batch should count only its own unavailable result")
    }

    private static func testCancellationAndNewImport() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("paper.pdf")
        try makePDF(at: source, title: "Local title")
        let store = LibraryStore(directory: root.appendingPathComponent("Library"))
        let oldIDs = store.importPDFs(from: [source, source])
        try expect(oldIDs.count == 2, "Could not create imports for cancellation")
        let originals = store.papers
        let probe = LookupProbe()
        let lookup = PDFMetadataLookup { try await probe.lookup(url: $0, title: $1, authors: $2) }
        lookup.enqueue(paperIDs: oldIDs, in: store)
        try await waitUntil("Cancelable request did not start") { await probe.count == 1 }
        lookup.cancel()
        try expect(!lookup.isSearching && lookup.notice?.contains("stopped") == true,
                   "Cancellation should stop progress immediately and explain that PDFs are saved")
        try expect(store.papers == originals, "Cancellation must keep all local imports unchanged")

        let newID = try unwrap(store.importPDFs(from: [source]).first, "New import after cancellation failed")
        lookup.enqueue(paperIDs: [newID], in: store)
        try await waitUntil("New lookup waited for a canceled response") { await probe.count == 2 }
        try expect(lookup.isSearching && lookup.totalCount == 1 && lookup.completedCount == 0 && lookup.notice == nil,
                   "A new batch should run independently of a canceled request")
        // The fake provider deliberately ignores cancellation, like a response already in flight.
        await probe.resolve(0, with: .success(PaperMetadata(title: "Late canceled response")))
        await probe.resolve(1, with: .success(PaperMetadata(title: "New response")))
        try await waitUntil("New lookup did not finish") { !lookup.isSearching }
        try expect(lookup.completedCount == 1 && lookup.totalCount == 1 && lookup.notice == nil,
                   "A canceled task must not alter the new batch's completion state")
        let requestCount = await probe.count
        try expect(requestCount == 2, "Cancellation should discard old queued work")
        for original in originals {
            try expect(try paper(original.id, in: store) == original,
                       "Canceled results must not update earlier imports")
        }
        try expect(try paper(newID, in: store).title == "New response",
                   "Only the new response should enrich the new import")
        try expect(LibraryStore(directory: store.directoryURL).papers == store.papers,
                   "Cancellation and restart should leave a coherent saved library")
    }

    private static func testEditsAndDeletionDuringLookup() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("paper.pdf")
        try makePDF(at: source, title: "Local title", author: "Local author")
        let directory = root.appendingPathComponent("Library")
        let store = LibraryStore(directory: directory)
        let folderID = try unwrap(store.addFolder(named: "Reading"), "Could not create destination folder")
        let ids = store.importPDFs(from: [source, source])
        try expect(ids.count == 2, "Could not create imports for concurrent edits")
        let original = try paper(ids[0], in: store)
        let deletedURL = try unwrap(store.fileURL(for: paper(ids[1], in: store)), "Missing PDF to delete")
        let probe = LookupProbe()
        let lookup = PDFMetadataLookup { try await probe.lookup(url: $0, title: $1, authors: $2) }
        lookup.enqueue(paperIDs: ids, in: store)
        try await waitUntil("Editable request did not start") { await probe.count == 1 }
        var edited = original
        edited.title = "User title"
        edited.year = "1999"
        store.updatePaper(edited)
        try expect(store.movePapers(ids: [edited.id], to: folderID), "Could not move paper during lookup")
        await probe.resolve(0, with: .success(PaperMetadata(title: "Online title", authors: "Online author",
                                                         year: "2026", venue: "Online journal", doi: "10.1234/online")))
        try await waitUntil("Second request did not start") { await probe.count == 2 }
        let current = try paper(edited.id, in: store)
        try expect(current.title == "User title" && current.year == "1999" && current.folderID == folderID,
                   "Lookup must preserve metadata and folder changes made while awaiting a response")
        try expect(current.authors == "Online author" && current.venue == "Online journal" && current.doi == "10.1234/online",
                   "Unedited metadata fields should still receive online values")
        try expect(current.fileName == original.fileName && current.addedAt == original.addedAt,
                   "Enrichment must retain the imported PDF and its original identity")
        store.deletePaper(id: ids[1])
        await probe.resolve(1, with: .success(PaperMetadata(title: "Deleted response")))
        try await waitUntil("Deleted paper's request did not finish") { !lookup.isSearching }
        try expect(store.papers == [current] && !FileManager.default.fileExists(atPath: deletedURL.path),
                   "A delayed response must not restore a deleted paper or its PDF")
        try expect(lookup.completedCount == 2 && lookup.notice == nil,
                   "A removed paper should finish quietly without an unavailable metadata notice")
        try expect(LibraryStore(directory: directory).papers == [current],
                   "Concurrent edits and deletion should survive reopening")
    }

    private static func waitUntil(_ message: String, condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()) {
            guard Date() < deadline else { throw TestFailure(message: message) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private static func paper(_ id: UUID, in store: LibraryStore) throws -> Paper {
        try unwrap(store.papers.first { $0.id == id }, "Missing paper \(id)")
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BibLookupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw TestFailure(message: message) }
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

private actor LookupProbe {
    struct Request: Sendable {
        let url: URL
        let title: String
        let authors: String
        let bytes: Data
    }

    private var requests: [Request] = []
    private var continuations: [Int: CheckedContinuation<PaperMetadata?, Error>] = [:]

    var count: Int { requests.count }

    func request(at index: Int) -> Request? {
        requests.indices.contains(index) ? requests[index] : nil
    }

    func lookup(url: URL, title: String, authors: String) async throws -> PaperMetadata? {
        let request = Request(url: url, title: title, authors: authors, bytes: try Data(contentsOf: url))
        return try await withCheckedThrowingContinuation { continuation in
            let index = requests.count
            requests.append(request)
            continuations[index] = continuation
        }
    }

    func resolve(_ index: Int, with result: Result<PaperMetadata?, Error>) {
        continuations.removeValue(forKey: index)?.resume(with: result)
    }
}
