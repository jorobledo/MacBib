import CoreGraphics
import Foundation
import PDFKit

/// Offline tests exercise actual metadata parsing, discovery, download validation, and cleanup.
@main
struct DOIImportTests {
    private static let doi = "10.1234/example"
    private static let resolver = "https://doi.org/10.1234/example"
    private static let pdfAddress = "https://publisher.org/article.pdf"

    static func main() async {
        do {
            try testReferences()
            print("PASS: DOI references preserve suffix punctuation and reject unsafe input and destinations")
            try await testCrossrefPDF()
            print("PASS: Crossref metadata and an accessible PDF are retrieved and temporary files are removable")
            try await testLandingPageDiscovery()
            print("PASS: Publisher landing pages supply relative, escaped, and HTTP Link PDF addresses")
            try await testCSLFallbackAndMetadataErrors()
            print("PASS: CSL fallback supports other DOI agencies and mismatched or unknown metadata is rejected")
            try await testMetadataOnlyFallbacks()
            print("PASS: Access restrictions, invalid PDFs, missing links, and network failures preserve metadata with accurate notices")
            try await testBoundedDiscoveryAndCancellation()
            print("PASS: Download discovery is bounded and cancellation removes all temporary files")
            print("All DOI import tests passed.")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func testReferences() throws {
        let valid = [
            (" 10.1234/example\n", "10.1234/example"),
            ("DOI: 10.1234/Example.(A);B", "10.1234/Example.(A);B"),
            ("https://doi.org/10.1234/Example%3Fone%23two?utm_source=test#reader", "10.1234/Example?one#two"),
            ("http://dx.doi.org/10.1234/ABC", "10.1234/ABC"),
            ("https://www.doi.org/10.1234/example", "10.1234/example"),
            ("doi.org/10.1234/abc", "10.1234/abc"),
            ("10.1234/a%2Fb", "10.1234/a%2Fb"),
            ("10.1234/name?key=value#part", "10.1234/name?key=value#part"),
            ("10.1234/http://example", "10.1234/http://example"),
            ("10.1234/résumé", "10.1234/résumé")
        ]
        for (input, expected) in valid {
            let reference = try DOIReference(input)
            try expect(reference.id == expected, "DOI suffix changed for \(input)")
            let components = URLComponents(url: reference.url, resolvingAgainstBaseURL: false)!
            try expect(components.scheme == "https" && components.host == "doi.org", "A DOI must use the canonical secure resolver")
            try expect(components.query == nil && components.fragment == nil, "Suffix punctuation must not create a query or fragment")
            try expect(components.path == "/" + expected, "The DOI path must round-trip its exact suffix")
        }
        for input in ["", "not a doi", "10.123/x", "10.1234/", "10.1234/two words", "10.1234/a\nb",
                      "https://example.org/10.1234/x", "https://doi.org.example.com/10.1234/x",
                      "https://user@doi.org/10.1234/x", "https://doi.org:443/10.1234/x",
                      "ftp://doi.org/10.1234/x", "https://doi.org/abs/10.1234/x"] {
            do {
                _ = try DOIReference(input)
                throw Failure(message: "Invalid DOI accepted: \(input)")
            } catch is Failure { throw Failure(message: "Invalid DOI accepted: \(input)") }
            catch { }
        }
        for address in ["http://publisher.org/a", "https://127.0.0.1/a", "https://[::1]/a", "https://localhost/a",
                        "https://machine.local/a", "https://10.0.0.1/a", "https://2130706433/a",
                        "file:///tmp/paper.pdf", "https://user:secret@publisher.org/a", "https://publisher.org:8443/a"] {
            try expect(!DOINetworkPolicy.allows(URL(string: address)!), "Unsafe outgoing address was allowed: \(address)")
        }
        try expect(DOINetworkPolicy.secureURL("http://publisher.org/paper.pdf")?.scheme == "https", "Legacy deposited links should be upgraded to HTTPS")
        try expect(DOINetworkPolicy.secureURL("javascript:alert(1)") == nil, "JavaScript links must be ignored")
    }

    private static func testCrossrefPDF() async throws {
        let environment = try Environment(metadata: [Reply.json(crossref())], downloads: [pdfAddress: Reply(bytes: makePDF())])
        defer { environment.remove() }
        let result = try await environment.service.importPaper(DOIReference(doi))
        try expect(result.metadata == PaperMetadata(title: "A useful & readable paper", authors: "Ada Example, Example Consortium",
                                                   year: "2021", venue: "Journal of Examples", doi: doi),
                   "Metadata should normalize title markup, authors, publication date, and venue")
        try expect(result.notice == nil && result.fileURL != nil, "An accessible PDF must import without a warning")
        try expect(PDFDocument(url: result.fileURL!)?.pageCount == 1, "Downloaded file must be an actual PDF")
        let requests = await environment.transport.requests()
        try expect(requests.count == 2, "A deposited PDF should not require an extra publisher-page request")
        try expect(requests[0].url?.absoluteString == "https://api.crossref.org/works/10.1234%2Fexample", "The full DOI must be encoded in the Crossref path")
        try expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Bib/") == true }, "Requests must identify the app")
        result.removeTemporaryFiles()
        result.removeTemporaryFiles()
        try environment.expectClean()
    }

    private static func testLandingPageDiscovery() async throws {
        let page = """
        <html><head>
        <meta content='10.1234/EXAMPLE' NAME='citation_doi'>
        <meta content='/article/download?format=pdf&amp;version=1' name='citation_pdf_url'>
        </head><body>Read this paper.</body></html>
        """
        let discovered = "https://publisher.org/article/download?format=pdf&version=1"
        let environment = try Environment(metadata: [Reply.json(crossref())], downloads: [
            pdfAddress: Reply.html("Sign in to access", status: 403),
            resolver: Reply.html(page, finalURL: "https://publisher.org/article/123"),
            discovered: Reply(bytes: makePDF())
        ])
        defer { environment.remove() }
        let result = try await environment.service.importPaper(DOIReference(doi))
        try expect(result.fileURL != nil && result.notice == nil, "A working landing-page link must recover from a stale or denied deposited link")
        let requests = await environment.transport.requests()
        try expect(requests.last?.url?.absoluteString == discovered, "Relative PDF addresses and HTML entities must resolve correctly")
        result.removeTemporaryFiles()
        try environment.expectClean()

        let pages: [(String, [String: String], String)] = [
            ("<meta NAME=citation_pdf_url CONTENT=/paper.pdf>", [:], "https://publisher.org/paper.pdf"),
            ("<link type='application/pdf' href='http://publisher.org/link.pdf'>", [:], "https://publisher.org/link.pdf"),
            ("<a href='/supplement.pdf'>Supplementary PDF</a><a href='/doi/pdf/10.1234/example'>Download PDF</a>", [:], "https://publisher.org/doi/pdf/10.1234/example"),
            ("<html>Paper</html>", ["Link": "</from-header.pdf>; rel=alternate; type=\"application/pdf\""], "https://publisher.org/from-header.pdf")
        ]
        for (html, headers, address) in pages {
            var landing = Reply.html(html, finalURL: "https://publisher.org/article")
            landing.headers = headers
            let test = try Environment(metadata: [Reply.json(crossref(links: []))], downloads: [resolver: landing, address: Reply(bytes: makePDF())])
            defer { test.remove() }
            let download = try await test.service.importPaper(DOIReference(doi))
            try expect(download.fileURL != nil, "Advertised PDF link was not found: \(html)")
            download.removeTemporaryFiles()
            try test.expectClean()
        }

        let related = try Environment(metadata: [Reply.json(crossref(links: []))], downloads: [
            resolver: Reply.html("""
                <meta name='citation_doi' content='10.1234/example'>
                <h1>Requested article</h1><p>Abstract only</p>
                <aside>Related research <a href='/related-paper.pdf'>Download PDF</a>
                <a href='/doi/pdf/10.1234/example-other'>PDF</a></aside>
                """, finalURL: "https://publisher.org/article"),
            "https://publisher.org/related-paper.pdf": Reply(bytes: makePDF()),
            "https://publisher.org/doi/pdf/10.1234/example-other": Reply(bytes: makePDF())
        ])
        defer { related.remove() }
        let metadataOnly = try await related.service.importPaper(DOIReference(doi))
        let relatedRequests = await related.transport.requests()
        try expect(metadataOnly.fileURL == nil && metadataOnly.metadata.doi == doi,
                   "A related paper's PDF must not be attached to the requested paper")
        try expect(relatedRequests.count == 2 && relatedRequests.last?.url?.absoluteString == resolver,
                   "Unassociated PDF anchors must not be requested, even when the page's citation_doi matches")
        try related.expectClean()
    }

    private static func testCSLFallbackAndMetadataErrors() async throws {
        let environment = try Environment(metadata: [Reply(bytes: Data(), status: 404), Reply.json(csl())], downloads: [resolver: Reply(bytes: makePDF())])
        defer { environment.remove() }
        let result = try await environment.service.importPaper(DOIReference(doi))
        try expect(result.metadata.title == "A DOI from another agency" && result.metadata.year == "2020", "CSL metadata was not imported")
        try expect(result.metadata.authors == "Grace Author", "CSL authors were not imported")
        let requests = await environment.transport.requests()
        try expect(requests[1].value(forHTTPHeaderField: "Accept") == "application/vnd.citationstyles.csl+json", "The resolver must request CSL metadata")
        try expect(result.fileURL != nil, "A DOI resolver may return a PDF directly")
        result.removeTemporaryFiles()
        try environment.expectClean()

        let cases: [(String, [Reply], String)] = [
            ("unknown DOI", [Reply(bytes: Data(), status: 404), Reply(bytes: Data(), status: 404)], "No paper was found"),
            ("mismatched DOI", [Reply.json(crossref(returnedDOI: "10.9999/wrong")), Reply.json(csl(returnedDOI: "10.9999/wrong"))], "Paper details"),
            ("invalid metadata", [Reply.html("<html>not metadata</html>"), Reply.json(["title": "No DOI"])], "Paper details"),
            ("metadata network failure", [Reply.failure(.notConnectedToInternet), Reply.failure(.timedOut)], "Paper details")
        ]
        for (name, replies, expected) in cases {
            let test = try Environment(metadata: replies, downloads: [:])
            defer { test.remove() }
            do {
                let unexpected = try await test.service.importPaper(DOIReference(doi))
                unexpected.removeTemporaryFiles()
                throw Failure(message: "\(name) must not create an unverified bibliographic record")
            } catch let failure as Failure { throw failure }
            catch { try expect(error.localizedDescription.contains(expected), "\(name) should explain the metadata failure") }
            let downloadCount = await test.transport.downloadCount()
            try expect(downloadCount == 0, "PDF discovery should not run without verified metadata")
            try test.expectClean()
        }
    }

    private static func testMetadataOnlyFallbacks() async throws {
        let cases: [(String, Reply, String, Bool)] = [
            ("subscription denied", Reply.html("Payment required", status: 402), "paid subscription", true),
            ("publisher block", Reply.html("Forbidden", status: 403), "block automatic", true),
            ("paywall HTML", Reply.html("<html><h1>Sign in to access this article</h1></html>"), "paid subscription", true),
            ("network timeout", Reply.failure(.timedOut), "connection failed or timed out", false),
            ("server unavailable", Reply(bytes: Data(), status: 503), "temporarily unavailable", false),
            ("no PDF", Reply.html("<html>Abstract only</html>"), "No readable PDF", true),
            ("HTML advertised as PDF", Reply(bytes: Data("<html>Not a PDF</html>".utf8), mime: "application/pdf"), "No readable PDF", true),
            ("corrupt PDF", Reply(bytes: Data("%PDF-1.7\nnot a document".utf8)), "No readable PDF", true),
            ("unsafe redirect", Reply(bytes: try makePDF(), finalURL: "https://127.0.0.1/paper.pdf"), "No readable PDF", true)
        ]
        for (name, reply, expected, mentionsAccess) in cases {
            let test = try Environment(metadata: [Reply.json(crossref(links: []))], downloads: [resolver: reply])
            defer { test.remove() }
            let result = try await test.service.importPaper(DOIReference(doi))
            try expect(result.fileURL == nil && result.metadata.doi == doi && result.metadata.title == "A useful & readable paper",
                       "\(name) should preserve bibliographic metadata without a file")
            try expect(result.notice?.contains(expected) == true,
                       "\(name) should provide a useful notice: \(result.notice ?? "nil")")
            if !mentionsAccess { try expect(result.notice?.contains("subscription") == false, "\(name) must not be misreported as a paywall") }
            result.removeTemporaryFiles()
            try test.expectClean()
        }

        // A redirected page for another paper must not attach that paper's PDF.
        let mismatch = try Environment(metadata: [Reply.json(crossref(links: []))], downloads: [
            resolver: Reply.html("<meta name='citation_doi' content='10.9999/wrong'><meta name='citation_pdf_url' content='https://publisher.org/wrong.pdf'>")
        ])
        defer { mismatch.remove() }
        let result = try await mismatch.service.importPaper(DOIReference(doi))
        let mismatchDownloadCount = await mismatch.transport.downloadCount()
        try expect(result.fileURL == nil && mismatchDownloadCount == 1, "A mismatched landing page must not supply a PDF")
        try mismatch.expectClean()

        // A plain sign-in navigation link is not evidence that this particular article is paid.
        let navigation = try Environment(metadata: [Reply.json(crossref(links: []))], downloads: [resolver: Reply.html("<nav>Sign in</nav><h1>Article abstract</h1>")])
        defer { navigation.remove() }
        let record = try await navigation.service.importPaper(DOIReference(doi))
        try expect(record.notice?.contains("did not allow") == false, "Normal navigation must not be reported as access denial")
        try navigation.expectClean()
    }

    private static func testBoundedDiscoveryAndCancellation() async throws {
        var downloads: [String: Reply] = [:]
        for index in 0..<12 {
            let url = index == 0 ? resolver : "https://publisher.org/\(index).pdf"
            downloads[url] = Reply.html("<meta name='citation_pdf_url' content='https://publisher.org/\(index + 1).pdf'>")
        }
        let bounded = try Environment(metadata: [Reply.json(crossref(links: []))], downloads: downloads)
        defer { bounded.remove() }
        let result = try await bounded.service.importPaper(DOIReference(doi))
        let boundedDownloadCount = await bounded.transport.downloadCount()
        try expect(result.fileURL == nil && boundedDownloadCount <= 6, "Discovery must not follow an unbounded chain of links")
        try bounded.expectClean()

        let cancelled = try Environment(metadata: [Reply.json(crossref())], downloads: [pdfAddress: Reply(bytes: makePDF())], pauseDownloads: true)
        defer { cancelled.remove() }
        let task = Task { try await cancelled.service.importPaper(DOIReference(doi)) }
        for _ in 0..<200 {
            if await cancelled.transport.downloadCount() > 0 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let cancelledDownloadCount = await cancelled.transport.downloadCount()
        try expect(cancelledDownloadCount == 1, "Download did not start")
        task.cancel()
        await cancelled.transport.resumeDownloads()
        do {
            let unexpected = try await task.value
            unexpected.removeTemporaryFiles()
            throw Failure(message: "A cancelled import must not return a PDF or metadata-only record")
        } catch is CancellationError { }
        try cancelled.expectClean()
    }

    private static func crossref(returnedDOI: String = doi, links: [[String: String]]? = nil) -> [String: Any] {
        ["message": ["DOI": returnedDOI, "title": [" A <i>useful</i> &amp; readable\n paper "],
                     "author": [["given": " Ada ", "family": "Example"], ["name": "Example Consortium"]],
                     "container-title": ["Journal of Examples"], "published-print": ["date-parts": [[2021, 2, 3]]],
                     "issued": ["date-parts": [[2020]]],
                     "link": links ?? [["URL": pdfAddress, "content-type": "application/pdf"]]]]
    }

    private static func csl(returnedDOI: String = doi) -> [String: Any] {
        ["DOI": returnedDOI, "title": "A DOI from another agency", "author": [["given": "Grace", "family": "Author"]],
         "issued": ["date-parts": [[2020]]], "container-title": "Another Journal"]
    }

    private static func makePDF() throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { throw Failure(message: "Cannot create PDF consumer") }
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw Failure(message: "Cannot create PDF context") }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 100, height: 100))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private struct Reply: Sendable {
        let bytes: Data
        var status = 200
        var mime = "application/pdf"
        var finalURL: String?
        var headers: [String: String] = [:]
        var failure: URLError.Code?

        static func json(_ object: [String: Any]) -> Reply {
            Reply(bytes: try! JSONSerialization.data(withJSONObject: object), mime: "application/json")
        }
        static func html(_ text: String, status: Int = 200, finalURL: String? = nil) -> Reply {
            Reply(bytes: Data(text.utf8), status: status, mime: "text/html", finalURL: finalURL)
        }
        static func failure(_ code: URLError.Code) -> Reply { Reply(bytes: Data(), failure: code) }

        func response(_ request: URLRequest) -> HTTPURLResponse {
            var fields = headers
            fields["Content-Type"] = mime
            return HTTPURLResponse(url: finalURL.flatMap(URL.init(string:)) ?? request.url!, statusCode: status,
                                   httpVersion: "HTTP/1.1", headerFields: fields)!
        }
    }

    private actor FakeTransport: DOIHTTPTransport {
        private var metadata: [Reply]
        private let downloads: [String: Reply]
        private let directory: URL
        private var records: [URLRequest] = []
        private var count = 0
        private var paused: [CheckedContinuation<Void, Never>] = []
        private var pauseDownloads: Bool

        init(metadata: [Reply], downloads: [String: Reply], directory: URL, pauseDownloads: Bool) {
            self.metadata = metadata
            self.downloads = downloads
            self.directory = directory
            self.pauseDownloads = pauseDownloads
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            records.append(request)
            guard !metadata.isEmpty else { throw Failure(message: "Unexpected metadata request") }
            let reply = metadata.removeFirst()
            if let failure = reply.failure { throw URLError(failure) }
            return (reply.bytes, reply.response(request))
        }

        func download(for request: URLRequest) async throws -> (URL, URLResponse) {
            records.append(request)
            count += 1
            let reply = downloads[request.url!.absoluteString] ?? Reply(bytes: Data(), status: 404)
            if let failure = reply.failure { throw URLError(failure) }
            let file = directory.appendingPathComponent(UUID().uuidString)
            try reply.bytes.write(to: file)
            if pauseDownloads { await withCheckedContinuation { paused.append($0) } }
            return (file, reply.response(request))
        }

        func requests() -> [URLRequest] { records }
        func downloadCount() -> Int { count }
        func resumeDownloads() {
            pauseDownloads = false
            let continuations = paused
            paused.removeAll()
            continuations.forEach { $0.resume() }
        }
    }

    private struct Environment {
        let root: URL
        let serviceRoot: URL
        let transportRoot: URL
        let transport: FakeTransport
        let service: DOIImportService

        init(metadata: [Reply], downloads: [String: Reply], pauseDownloads: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("BibDOITests-\(UUID().uuidString)", isDirectory: true)
            serviceRoot = root.appendingPathComponent("Service", isDirectory: true)
            transportRoot = root.appendingPathComponent("Transport", isDirectory: true)
            try FileManager.default.createDirectory(at: serviceRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: transportRoot, withIntermediateDirectories: true)
            transport = FakeTransport(metadata: metadata, downloads: downloads, directory: transportRoot, pauseDownloads: pauseDownloads)
            service = DOIImportService(transport: transport, temporaryRoot: serviceRoot)
        }

        func expectClean() throws {
            for directory in [serviceRoot, transportRoot] {
                let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                try expect(contents.isEmpty, "Leaked temporary files in \(directory.lastPathComponent): \(contents)")
            }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
