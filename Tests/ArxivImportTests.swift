import CoreGraphics
import Foundation
import PDFKit

/// Deterministic arXiv import tests. No requests reach the network.
@main
struct ArxivImportTests {
    static func main() async {
        do {
            try testReferencesAndRedirectPolicy()
            print("PASS: arXiv links, identifiers, versions, and redirect destinations are validated")
            try await testMetadataAndLatestVersion()
            print("PASS: Atom metadata is normalized and the PDF is pinned to the returned version")
            try await testMetadataFallbacks()
            print("PASS: Missing, invalid, mismatched, and unavailable metadata falls back to the requested PDF")
            try await testPDFErrorsAndCleanup()
            print("PASS: PDF errors reject the download and clean up temporary files")
            try await testCancellationAndRecovery()
            print("PASS: Active and queued imports can be cancelled without blocking subsequent imports")
            try await testSerializationAndPacing()
            print("PASS: Concurrent imports are serialized and metadata requests are paced")
            print("All arXiv import tests passed.")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func testReferencesAndRedirectPolicy() throws {
        let valid = [
            (" 1706.03762 \n", "1706.03762"),
            ("arXiv: 1706.03762v5", "1706.03762v5"),
            ("https://arxiv.org/abs/1706.03762", "1706.03762"),
            ("https://www.arxiv.org/pdf/1706.03762v5.pdf?download=1#page=2", "1706.03762v5"),
            ("http://export.arxiv.org/abs/0704.0001", "0704.0001"),
            ("https://arxiv.org/html/2401.00001v1", "2401.00001v1"),
            ("arxiv.org/abs/1706.03762/", "1706.03762"),
            ("www.arxiv.org/pdf/1706.03762v5.pdf/", "1706.03762v5"),
            ("export.arxiv.org/abs/0704.0001", "0704.0001"),
            ("https://arxiv.org/abs/1706.03762v5/", "1706.03762v5"),
            ("https://ARXIV.ORG/pdf/HEP-TH/9901001v2", "hep-th/9901001v2"),
            ("math.GT/0309136", "math.gt/0309136")
        ]
        for (input, expected) in valid {
            let reference = try ArxivReference(input)
            try expect(reference.id == expected, "Unexpected normalized identifier for \(input)")
            try expect(reference.pdfURL.absoluteString == "https://arxiv.org/pdf/\(expected)",
                       "PDF URLs must always use canonical HTTPS arXiv URLs")
        }
        let invalid = [
            "", " ", "1706.123", "1706.123456", "1700.03762", "1713.03762", "1706.03762v0",
            "1706.03762v-1", "1706.03762/extra", "hep-th/9913001", "../1706.03762",
            "https://example.org/abs/1706.03762", "https://arxiv.org.example.com/abs/1706.03762",
            "https://evil-arxiv.org/abs/1706.03762", "https://sub.arxiv.org/abs/1706.03762",
            "arxiv.org.example.com/abs/1706.03762", "evil-arxiv.org/abs/1706.03762",
            "https://arxiv.org/list/1706.03762", "https://arxiv.org/abs/1706.03762/more",
            "ftp://arxiv.org/abs/1706.03762", "file:///abs/1706.03762",
            "https://user@arxiv.org/abs/1706.03762", "https://user:password@arxiv.org/abs/1706.03762",
            "https://arxiv.org:443/abs/1706.03762", "https://arxiv.org:8080/abs/1706.03762"
        ]
        for input in invalid {
            do {
                _ = try ArxivReference(input)
                throw TestFailure(message: "Invalid reference was accepted: \(input)")
            } catch is TestFailure { throw TestFailure(message: "Invalid reference was accepted: \(input)") }
            catch { /* Expected reference validation error. */ }
        }
        for address in ["https://arxiv.org/pdf/1706.03762", "https://export.arxiv.org/api/query",
                        "https://browse.arxiv.org/pdf/1706.03762"] {
            try expect(ArxivNetworkPolicy.allows(URL(string: address)!), "Safe arXiv destination rejected")
        }
        for address in ["http://arxiv.org/pdf/1706.03762", "https://arxiv.org.example.com/file",
                        "https://example.com/file", "https://user@arxiv.org/file", "https://arxiv.org:443/file"] {
            try expect(!ArxivNetworkPolicy.allows(URL(string: address)!), "Unsafe redirect allowed: \(address)")
        }
    }

    private static func testMetadataAndLatestVersion() async throws {
        let environment = try Environment(metadata: Reply(bytes: feed(), mime: "application/atom+xml"))
        defer { environment.remove() }
        let download = try await environment.service.download(ArxivReference("1706.03762"))
        try expect(download.metadata == PaperMetadata(title: "A useful & readable paper", authors: "Ada Example, Grace Author",
                                                      year: "2017", venue: "Journal of Examples 42 (2018)", doi: "10.1234/example"),
                   "Atom title, authors, publication year, journal reference, and DOI should normalize whitespace")
        try expect(download.metadataWarning == nil, "Valid metadata should not display a warning")
        try expect(download.fileURL.lastPathComponent == "arXiv-1706.03762v5.pdf", "Latest PDF filename should retain its version")
        try expect(PDFDocument(url: download.fileURL)?.pageCount == 1, "Successful download should contain a readable PDF")
        let records = await environment.transport.records()
        try expect(records.count == 2, "A successful import should request metadata and then the PDF")
        let query = URLComponents(url: records[0].request.url!, resolvingAgainstBaseURL: false)?.queryItems
        try expect(query?.first(where: { $0.name == "id_list" })?.value == "1706.03762", "Metadata must request the entered ID")
        try expect(records[1].request.url?.absoluteString == "https://arxiv.org/pdf/1706.03762v5",
                   "An unversioned import must fetch the PDF matching its returned metadata")
        try expect(records.allSatisfy { $0.request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Bib/") == true },
                   "Requests should identify the app")
        download.removeTemporaryFiles()
        download.removeTemporaryFiles()
        try environment.expectClean()

        let legacy = try Environment(metadata: Reply(bytes: feed(id: "http://arxiv.org/abs/hep-th/9901001v2"), mime: "application/atom+xml"))
        defer { legacy.remove() }
        let legacyDownload = try await legacy.service.download(ArxivReference("hep-th/9901001v2"))
        try expect(legacyDownload.fileURL.lastPathComponent == "arXiv-hep-th_9901001v2.pdf",
                   "Legacy IDs should produce a single safe filename")
        legacyDownload.removeTemporaryFiles()
        try legacy.expectClean()
    }

    private static func testMetadataFallbacks() async throws {
        let cases: [(String, Reply, String)] = [
            ("network failure", Reply(bytes: Data(), networkFailure: true), "1706.03762"),
            ("HTTP failure", Reply(bytes: feed(), status: 503), "1706.03762"),
            ("empty response", Reply(bytes: Data()), "1706.03762"),
            ("malformed XML", Reply(bytes: Data("<feed><entry>broken".utf8)), "1706.03762"),
            ("empty feed", Reply(bytes: Data("<feed xmlns='http://www.w3.org/2005/Atom'/>".utf8)), "1706.03762"),
            ("wrong namespace", Reply(bytes: Data("<feed><entry><id>1706.03762</id><title>Wrong</title></entry></feed>".utf8)), "1706.03762"),
            ("wrong paper", Reply(bytes: feed(id: "http://arxiv.org/abs/2401.00001v1")), "1706.03762"),
            ("wrong version", Reply(bytes: feed()), "1706.03762v2"),
            ("missing version", Reply(bytes: feed(id: "http://arxiv.org/abs/1706.03762")), "1706.03762"),
            ("non-HTTP response", Reply(bytes: feed(), status: nil), "1706.03762"),
            ("unsafe redirect", Reply(bytes: feed(), finalURL: URL(string: "https://example.org/api")), "1706.03762")
        ]
        for (name, reply, input) in cases {
            let environment = try Environment(metadata: reply)
            defer { environment.remove() }
            let download = try await environment.service.download(ArxivReference(input))
            try expect(download.metadata == nil && download.metadataWarning?.isEmpty == false,
                       "\(name) should import the PDF with a metadata warning")
            let records = await environment.transport.records()
            try expect(records.last?.request.url?.absoluteString == "https://arxiv.org/pdf/\(input)",
                       "\(name) should preserve the requested paper and version")
            download.removeTemporaryFiles()
            try environment.expectClean()
        }
    }

    private static func testPDFErrorsAndCleanup() async throws {
        let bytes = try makePDF()
        let cases: [(String, Reply, String)] = [
            ("not found", Reply(bytes: bytes, status: 404), "could not find"),
            ("rate limited", Reply(bytes: bytes, status: 429), "too many requests"),
            ("server failure", Reply(bytes: bytes, status: 500), "HTTP 500"),
            ("HTML with a PDF header", Reply(bytes: bytes, mime: "text/html"), "readable PDF"),
            ("empty PDF", Reply(bytes: Data()), "readable PDF"),
            ("invalid bytes", Reply(bytes: Data("not a PDF".utf8)), "readable PDF"),
            ("forged PDF header", Reply(bytes: Data("%PDF-1.7\nnot an actual document".utf8)), "readable PDF"),
            ("unsafe redirect", Reply(bytes: bytes, finalURL: URL(string: "https://example.org/paper.pdf")), "unsupported address"),
            ("non-HTTP response", Reply(bytes: bytes, status: nil), "unexpected response"),
            ("network failure", Reply(bytes: bytes, networkFailure: true), "")
        ]
        for (name, reply, message) in cases {
            let environment = try Environment(metadata: Reply(bytes: feed()), pdf: reply)
            defer { environment.remove() }
            do {
                let unexpected = try await environment.service.download(ArxivReference("1706.03762"))
                unexpected.removeTemporaryFiles()
                throw TestFailure(message: "\(name) unexpectedly succeeded")
            } catch let error as TestFailure { throw error }
            catch {
                if reply.networkFailure {
                    try expect((error as? URLError)?.code == .notConnectedToInternet,
                               "Transport failures should retain their network error")
                } else {
                    try expect(error.localizedDescription.localizedCaseInsensitiveContains(message),
                               "\(name) should explain its failure: \(error.localizedDescription)")
                }
            }
            try environment.expectClean()
        }
    }

    private static func testCancellationAndRecovery() async throws {
        let environment = try Environment(metadata: Reply(bytes: feed()), pauseDownloads: true)
        defer { environment.remove() }
        let reference = try ArxivReference("1706.03762")
        let active = Task { try await environment.service.download(reference) }
        try await waitUntil { await environment.transport.downloadCount() == 1 }
        let queued = Task { try await environment.service.download(reference) }
        // Give the second task a chance to enter the service's continuation queue.
        try await Task.sleep(nanoseconds: 30_000_000)
        queued.cancel()
        try await expectCancelled(queued)
        let recordsWhilePaused = await environment.transport.records()
        try expect(recordsWhilePaused.count == 2, "A queued cancellation must not start additional network work")

        active.cancel()
        // This transport deliberately returns a file even after cancellation, exercising service cleanup.
        await environment.transport.resumeDownloads()
        try await expectCancelled(active)
        try environment.expectClean()

        let next = try await environment.service.download(reference)
        try expect(next.metadata != nil, "Cancelling an active transfer must release the service for the next import")
        next.removeTemporaryFiles()
        try environment.expectClean()
    }

    private static func testSerializationAndPacing() async throws {
        let environment = try Environment(metadata: Reply(bytes: feed()), interval: 0.15, pauseDownloads: true)
        defer { environment.remove() }
        let reference = try ArxivReference("1706.03762")
        let first = Task { try await environment.service.download(reference) }
        try await waitUntil { await environment.transport.downloadCount() == 1 }
        let second = Task { try await environment.service.download(reference) }
        try await Task.sleep(nanoseconds: 30_000_000)
        let beforeRelease = await environment.transport.records()
        try expect(beforeRelease.count == 2, "A second import must wait for the first PDF to finish")
        await environment.transport.resumeDownloads()
        let firstDownload = try await first.value
        let secondDownload = try await second.value
        firstDownload.removeTemporaryFiles()
        secondDownload.removeTemporaryFiles()
        let records = await environment.transport.records()
        try expect(records.map(\.kind) == [.metadata, .pdf, .metadata, .pdf], "Imports should serialize metadata and PDF pairs")
        let times = records.filter { $0.kind == .metadata }.map(\.time)
        try expect(times.count == 2 && times[1].timeIntervalSince(times[0]) >= 0.14,
                   "Metadata requests must respect the configured minimum interval")
        try environment.expectClean()
    }

    private static func expectCancelled(_ task: Task<ArxivDownload, Error>) async throws {
        do {
            let unexpected = try await task.value
            unexpected.removeTemporaryFiles()
            throw TestFailure(message: "A cancelled download unexpectedly completed")
        } catch is CancellationError { /* Expected. */ }
    }

    private static func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TestFailure(message: "Timed out waiting for the test transport")
    }

    private static func feed(id: String = "http://arxiv.org/abs/1706.03762v5") -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:arxiv="http://arxiv.org/schemas/atom">
          <entry>
            <id>\(id)</id>
            <title> A useful &amp;
              readable paper </title>
            <author><name> Ada   Example </name></author>
            <author><name>Grace Author</name></author>
            <published>2017-06-12T17:57:34Z</published>
            <arxiv:journal_ref>Journal of Examples
              42 (2018)</arxiv:journal_ref>
            <arxiv:doi> 10.1234/example </arxiv:doi>
          </entry>
        </feed>
        """.utf8)
    }

    private static func makePDF() throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { throw TestFailure(message: "Could not create PDF consumer") }
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw TestFailure(message: "Could not create PDF context")
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 100, height: 100))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private struct Environment {
        let root: URL
        let serviceRoot: URL
        let transportRoot: URL
        let transport: FakeTransport
        let service: ArxivImportService

        init(metadata: Reply, pdf: Reply? = nil, interval: TimeInterval = 0, pauseDownloads: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("BibArxivTests-\(UUID().uuidString)", isDirectory: true)
            serviceRoot = root.appendingPathComponent("Service", isDirectory: true)
            transportRoot = root.appendingPathComponent("Transport", isDirectory: true)
            try FileManager.default.createDirectory(at: serviceRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: transportRoot, withIntermediateDirectories: true)
            transport = FakeTransport(metadata: metadata, pdf: try pdf ?? Reply(bytes: makePDF()),
                                      directory: transportRoot, pauseDownloads: pauseDownloads)
            service = ArxivImportService(transport: transport, minimumRequestInterval: interval, temporaryRoot: serviceRoot)
        }

        func expectClean() throws {
            for directory in [serviceRoot, transportRoot] {
                let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                try expect(files.isEmpty, "Temporary files were left in \(directory.lastPathComponent): \(files)")
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private struct Reply: Sendable {
        let bytes: Data
        var status: Int? = 200
        var mime = "application/pdf"
        var finalURL: URL?
        var networkFailure = false

        func response(for request: URLRequest) -> URLResponse {
            let url = finalURL ?? request.url!
            if let status {
                return HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!
            }
            return URLResponse(url: url, mimeType: mime, expectedContentLength: bytes.count, textEncodingName: nil)
        }
    }

    private actor FakeTransport: ArxivHTTPTransport {
        enum Kind: Sendable { case metadata, pdf }
        struct Record: Sendable {
            let kind: Kind
            let request: URLRequest
            let time: Date
        }

        let metadata: Reply
        let pdf: Reply
        let directory: URL
        private var requests: [Record] = []
        private var pauseDownloads: Bool
        private var paused: [CheckedContinuation<Void, Never>] = []

        init(metadata: Reply, pdf: Reply, directory: URL, pauseDownloads: Bool) {
            self.metadata = metadata
            self.pdf = pdf
            self.directory = directory
            self.pauseDownloads = pauseDownloads
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(Record(kind: .metadata, request: request, time: Date()))
            if metadata.networkFailure { throw URLError(.notConnectedToInternet) }
            return (metadata.bytes, metadata.response(for: request))
        }

        func download(for request: URLRequest) async throws -> (URL, URLResponse) {
            requests.append(Record(kind: .pdf, request: request, time: Date()))
            if pdf.networkFailure { throw URLError(.notConnectedToInternet) }
            let file = directory.appendingPathComponent(UUID().uuidString)
            try pdf.bytes.write(to: file)
            if pauseDownloads { await withCheckedContinuation { paused.append($0) } }
            return (file, pdf.response(for: request))
        }

        func records() -> [Record] { requests }
        func downloadCount() -> Int { requests.filter { $0.kind == .pdf }.count }
        func resumeDownloads() {
            pauseDownloads = false
            let continuations = paused
            paused.removeAll()
            continuations.forEach { $0.resume() }
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(message: message) }
    }

    private struct TestFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
