import Foundation
import PDFKit
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Accept a paper identifier or a link; requests always use canonical HTTPS URLs.
struct ArxivReference: Equatable, Sendable {
    let id: String

    init(_ input: String) throws {
        var candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let officialHosts = ["arxiv.org", "www.arxiv.org", "export.arxiv.org"]
        if officialHosts.contains(where: { candidate.lowercased().hasPrefix($0 + "/") }) {
            candidate = "https://" + candidate
        }
        if candidate.lowercased().hasPrefix("arxiv:") {
            candidate = String(candidate.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if candidate.contains("://") {
            guard let components = URLComponents(string: candidate),
                  let scheme = components.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  let host = components.host?.lowercased(),
                  officialHosts.contains(host),
                  components.user == nil, components.password == nil, components.port == nil else {
                throw ArxivImportError.invalidReference
            }
            let path = components.path
            guard let prefix = ["/abs/", "/pdf/", "/html/"].first(where: { path.hasPrefix($0) }) else {
                throw ArxivImportError.invalidReference
            }
            candidate = String(path.dropFirst(prefix.count))
        }
        if candidate.hasSuffix("/") { candidate = String(candidate.dropLast()) }
        if candidate.hasSuffix(".pdf") { candidate = String(candidate.dropLast(4)) }
        let pattern = #"^(?:[0-9]{2}(?:0[1-9]|1[0-2])\.[0-9]{4,5}|[a-z][a-z0-9.-]*/[0-9]{2}(?:0[1-9]|1[0-2])[0-9]{3})(?:v[1-9][0-9]*)?$"#
        guard candidate.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else {
            throw ArxivImportError.invalidReference
        }
        id = candidate.lowercased()
    }

    var pdfURL: URL { URL(string: "https://arxiv.org/pdf/\(id)")! }

    fileprivate var baseID: String {
        guard let range = id.range(of: #"v[1-9][0-9]*$"#, options: .regularExpression) else { return id }
        return String(id[..<range.lowerBound])
    }

    fileprivate var hasVersion: Bool { id != baseID }

    fileprivate var metadataURL: URL {
        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = [URLQueryItem(name: "id_list", value: id), URLQueryItem(name: "max_results", value: "1")]
        return components.url!
    }
}

struct ArxivDownload: Sendable {
    let fileURL: URL
    let metadata: PaperMetadata?
    let metadataWarning: String?
    fileprivate let temporaryDirectory: URL

    /// The library copies this file. Call after that copy, including failed imports.
    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

/// An injectable transport keeps network/error tests deterministic without live arXiv requests.
protocol ArxivHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func download(for request: URLRequest) async throws -> (URL, URLResponse)
}

actor ArxivImportService {
    static let shared = ArxivImportService()

    private let transport: any ArxivHTTPTransport
    private let minimumRequestInterval: TimeInterval
    private let temporaryRoot: URL
    private var lastMetadataRequest: Date?
    private var downloading = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(
        transport: (any ArxivHTTPTransport)? = nil,
        minimumRequestInterval: TimeInterval = 3,
        temporaryRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.transport = transport ?? ArxivURLSessionTransport()
        self.minimumRequestInterval = max(0, minimumRequestInterval)
        self.temporaryRoot = temporaryRoot
    }

    /// Share pacing and serialization with arXiv imports, without downloading another PDF.
    func metadata(for reference: ArxivReference) async throws -> PaperMetadata {
        try await acquireDownload()
        defer { releaseDownload() }
        let entry = try await metadataEntry(for: reference)
        try Task.checkCancellation()
        return entry.metadata
    }

    private func metadataEntry(for reference: ArxivReference) async throws -> ArxivFeedParser.Entry {
        if let lastMetadataRequest {
            let delay = minimumRequestInterval - Date().timeIntervalSince(lastMetadataRequest)
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        }
        try Task.checkCancellation()
        lastMetadataRequest = Date()
        let (data, response) = try await transport.data(for: request(reference.metadataURL))
        try Task.checkCancellation()
        try validateResponse(response)
        let entry = try ArxivFeedParser.read(data)
        let returnedReference = try ArxivReference(entry.id)
        guard returnedReference.hasVersion, returnedReference.baseID == reference.baseID,
              !reference.hasVersion || returnedReference.id == reference.id else {
            throw ArxivImportError.mismatchedMetadata
        }
        return entry
    }

    /// Serialize transfers and pace API calls to respect arXiv's API access policy.
    func download(_ reference: ArxivReference) async throws -> ArxivDownload {
        try await acquireDownload()
        defer { releaseDownload() }
        try Task.checkCancellation()

        let directory = temporaryRoot.appendingPathComponent("Bib-arXiv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var resolvedReference = reference
            var metadata: PaperMetadata?
            var warning: String?
            do {
                let entry = try await metadataEntry(for: reference)
                let returnedReference = try ArxivReference(entry.id)
                resolvedReference = returnedReference
                metadata = entry.metadata
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                warning = "The PDF was imported, but arXiv metadata was unavailable. "
                    + "Bib used the PDF's embedded details where available; you can edit them."
            }
            try Task.checkCancellation()

            let (downloadURL, response) = try await transport.download(for: request(resolvedReference.pdfURL))
            defer { try? FileManager.default.removeItem(at: downloadURL) }
            try Task.checkCancellation()
            try validateResponse(response)
            try validatePDF(at: downloadURL, response: response)
            let fileName = "arXiv-\(resolvedReference.id.replacingOccurrences(of: "/", with: "_")).pdf"
            let fileURL = directory.appendingPathComponent(fileName)
            try FileManager.default.moveItem(at: downloadURL, to: fileURL)
            try Task.checkCancellation()
            return ArxivDownload(fileURL: fileURL, metadata: metadata, metadataWarning: warning,
                                 temporaryDirectory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("Bib/1.0 (native paper library)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw ArxivImportError.invalidResponse }
        guard let url = response.url, ArxivNetworkPolicy.allows(url) else { throw ArxivImportError.unsafeRedirect }
        guard response.statusCode == 200 else { throw ArxivImportError.httpStatus(response.statusCode) }
    }

    private func validatePDF(at url: URL, response: URLResponse) throws {
        let mime = response.mimeType?.lowercased() ?? ""
        guard mime != "text/html", mime != "application/xhtml+xml" else { throw ArxivImportError.invalidPDF }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 1_024) ?? Data()
        guard header.range(of: Data("%PDF-".utf8)) != nil,
              let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
            throw ArxivImportError.invalidPDF
        }
    }

    private func acquireDownload() async throws {
        try Task.checkCancellation()
        if !downloading {
            downloading = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func releaseDownload() {
        if waiters.isEmpty { downloading = false }
        else { waiters.removeFirst().continuation.resume() }
    }
}

/// Applied before following redirects as well as to the final response.
enum ArxivNetworkPolicy {
    static func allows(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.user == nil,
              components.password == nil, components.port == nil,
              let host = components.host?.lowercased() else { return false }
        return host == "arxiv.org" || host.hasSuffix(".arxiv.org")
    }
}

private final class ArxivRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(ArxivNetworkPolicy.allows) == true ? request : nil)
    }
}

private final class ArxivURLSessionTransport: ArxivHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: ArxivRedirectDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) { try await session.data(for: request) }
    func download(for request: URLRequest) async throws -> (URL, URLResponse) { try await session.download(for: request) }
}

private enum ArxivImportError: LocalizedError {
    case invalidReference, invalidResponse, unsafeRedirect, invalidPDF, invalidMetadata, mismatchedMetadata
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidReference:
            "Enter an arXiv paper link, such as https://arxiv.org/abs/1706.03762, or its arXiv ID."
        case .invalidResponse:
            "arXiv returned an unexpected response. Please try again."
        case .unsafeRedirect:
            "arXiv redirected to an unsupported address. Please try another arXiv paper link."
        case .invalidPDF:
            "arXiv did not return a readable PDF. Check the paper link and try again."
        case .invalidMetadata, .mismatchedMetadata:
            "arXiv's metadata could not be verified for this paper."
        case .httpStatus(404):
            "arXiv could not find a PDF for this paper. Check the link and try again."
        case .httpStatus(429):
            "arXiv is receiving too many requests. Please try again shortly."
        case .httpStatus(let status):
            "arXiv could not provide this paper (HTTP \(status)). Please try again later."
        }
    }
}

private final class ArxivFeedParser: NSObject, XMLParserDelegate {
    struct Entry {
        var id = ""
        var title = ""
        var authors: [String] = []
        var published = ""
        var venue = ""
        var doi = ""

        var metadata: PaperMetadata {
            let year = published.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T"#, options: .regularExpression) == nil
                ? "" : String(published.prefix(4))
            return PaperMetadata(title: title, authors: authors.joined(separator: ", "), year: year,
                                 venue: venue, doi: doi)
        }
    }

    private struct Element {
        let name: String
        let namespace: String?
        var text = ""
    }

    private static let atom = "http://www.w3.org/2005/Atom"
    private static let arxiv = "http://arxiv.org/schemas/atom"
    private var elements: [Element] = []
    private var entries: [Entry] = []
    private var current: Entry?

    static func read(_ data: Data) throws -> Entry {
        guard !data.isEmpty, data.count < 2_000_000 else { throw ArxivImportError.invalidMetadata }
        let delegate = ArxivFeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.entries.count == 1, let entry = delegate.entries.first,
              !entry.id.isEmpty, !entry.title.isEmpty else { throw ArxivImportError.invalidMetadata }
        return entry
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        elements.append(Element(name: elementName, namespace: namespaceURI))
        if elements.count == 2, elementName == "entry", namespaceURI == Self.atom,
           elements[0].name == "feed", elements[0].namespace == Self.atom {
            current = Entry()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !elements.isEmpty else { return }
        elements[elements.count - 1].text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        guard let element = elements.popLast(), current != nil else { return }
        let value = element.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if elements.count == 2, elements.last?.name == "entry" {
            if element.namespace == Self.atom {
                switch element.name {
                case "id": current?.id = value
                case "title": current?.title = value
                case "published": current?.published = value
                default: break
                }
            } else if element.namespace == Self.arxiv {
                if element.name == "journal_ref" { current?.venue = value }
                if element.name == "doi" { current?.doi = value }
            }
        } else if elements.count == 3, elements.last?.name == "author", elements.last?.namespace == Self.atom,
                  element.name == "name",
                  element.namespace == Self.atom, !value.isEmpty {
            current?.authors.append(value)
        } else if elements.count == 1, element.name == "entry", element.namespace == Self.atom,
                  let entry = current {
            entries.append(entry)
            current = nil
        }
    }
}
