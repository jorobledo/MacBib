import Foundation
import PDFKit

/// DOI suffixes may contain punctuation. Encode them as a path, never as a query or fragment.
struct DOIReference: Equatable, Sendable {
    let id: String

    init(_ input: String) throws {
        var candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let hosts = ["doi.org", "www.doi.org", "dx.doi.org"]
        if hosts.contains(where: { candidate.lowercased().hasPrefix($0 + "/") }) {
            candidate = "https://" + candidate
        }
        if candidate.lowercased().hasPrefix("doi:") {
            candidate = String(candidate.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if candidate.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil {
            guard let components = URLComponents(string: candidate),
                  ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                  hosts.contains(components.host?.lowercased() ?? ""),
                  components.user == nil, components.password == nil, components.port == nil,
                  components.path.hasPrefix("/") else { throw DOIImportError.invalidReference }
            candidate = String(components.path.dropFirst())
        }
        guard candidate.utf8.count <= 2_048,
              candidate.range(of: #"^10\.[0-9]{4,9}/[^\s\p{Cc}]+$"#, options: .regularExpression) != nil else {
            throw DOIImportError.invalidReference
        }
        id = candidate
    }

    var url: URL { URL(string: "https://doi.org/" + encodedID(allowSlash: true))! }

    fileprivate var metadataURL: URL {
        URL(string: "https://api.crossref.org/works/" + encodedID(allowSlash: false))!
    }

    private func encodedID(allowSlash: Bool) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        if allowSlash { allowed.insert(charactersIn: "/") }
        return id.addingPercentEncoding(withAllowedCharacters: allowed)!
    }

    fileprivate func matches(_ value: String) -> Bool {
        guard let other = try? DOIReference(value) else { return false }
        return id.caseInsensitiveCompare(other.id) == .orderedSame
    }
}

struct DOIImportResult: Sendable {
    let metadata: PaperMetadata
    let fileURL: URL?
    let notice: String?
    fileprivate let temporaryDirectory: URL?

    /// The library copies downloaded PDFs. Call on both success and failed library imports.
    func removeTemporaryFiles() {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }
}

protocol DOIHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func download(for request: URLRequest) async throws -> (URL, URLResponse)
}

actor DOIImportService {
    static let shared = DOIImportService()

    private let transport: any DOIHTTPTransport
    private let temporaryRoot: URL
    private let importTimeLimit: TimeInterval
    private let maximumPDFRequests = 6

    init(transport: (any DOIHTTPTransport)? = nil,
         temporaryRoot: URL = FileManager.default.temporaryDirectory,
         importTimeLimit: TimeInterval = 120) {
        self.transport = transport ?? DOIURLSessionTransport()
        self.temporaryRoot = temporaryRoot
        self.importTimeLimit = max(1, importTimeLimit)
    }

    /// Retrieve details for a PDF the user already has, without discovering or downloading a PDF.
    func metadata(for reference: DOIReference) async throws -> PaperMetadata {
        try Task.checkCancellation()
        let record = try await metadata(for: reference, deadline: Date().addingTimeInterval(min(35, importTimeLimit)))
        try Task.checkCancellation()
        return record.metadata
    }

    /// Crossref relevance scores are not identity checks; callers must verify the returned titles.
    func searchMetadata(title: String) async throws -> [PaperMetadata] {
        try Task.checkCancellation()
        var components = URLComponents(string: "https://api.crossref.org/works")!
        components.queryItems = [URLQueryItem(name: "query.title", value: String(title.prefix(350))),
                                 URLQueryItem(name: "rows", value: "5")]
        let request = try makeRequest(components.url!, accept: "application/json",
                                      deadline: Date().addingTimeInterval(min(25, importTimeLimit)))
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        let http = try validatedResponse(response)
        guard http.statusCode == 200 else { throw DOIImportError.metadataHTTP(http.statusCode) }
        guard data.count <= DOIResourceLimits.metadataBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let items = message["items"] as? [[String: Any]] else { throw DOIImportError.metadataUnavailable }
        return items.prefix(5).compactMap { item in
            guard let id = item["DOI"] as? String, let reference = try? DOIReference(id),
                  let bytes = try? JSONSerialization.data(withJSONObject: ["message": item]) else { return nil }
            return try? DOIMetadataRecord(data: bytes, reference: reference, crossref: true).metadata
        }
    }

    /// A valid metadata record survives a failed PDF download. Cancellation never imports a record.
    func importPaper(_ reference: DOIReference) async throws -> DOIImportResult {
        try Task.checkCancellation()
        let deadline = Date().addingTimeInterval(importTimeLimit)
        let record = try await metadata(for: reference, deadline: deadline)
        try Task.checkCancellation()
        let directory = temporaryRoot.appendingPathComponent("Bib-DOI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var keepDirectory = false
        defer { if !keepDirectory { try? FileManager.default.removeItem(at: directory) } }

        var failures = DownloadFailures()
        var visited = Set<String>()
        var candidates = record.pdfURLs
        // Resolve the DOI even when a deposited PDF link fails: landing pages often advertise a newer link.
        candidates.append(reference.url)
        var requests = 0
        while !candidates.isEmpty && requests < maximumPDFRequests {
            try Task.checkCancellation()
            let url = candidates.removeFirst()
            guard visited.insert(url.absoluteString).inserted else { continue }
            requests += 1
            do {
                let request = try makeRequest(url, accept: "application/pdf, text/html;q=0.9, */*;q=0.1", deadline: deadline)
                let (downloadURL, response) = try await transport.download(for: request)
                defer { try? FileManager.default.removeItem(at: downloadURL) }
                try Task.checkCancellation()
                let http = try validatedResponse(response)
                guard http.statusCode == 200 else {
                    failures.record(status: http.statusCode)
                    continue
                }
                let size = try downloadURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= DOIResourceLimits.pdfBytes else { failures.tooLarge = true; continue }
                let prefix = try readPrefix(downloadURL, count: 1_024)
                let mime = http.mimeType?.lowercased() ?? ""
                if mime != "text/html", mime != "application/xhtml+xml",
                   prefix.range(of: Data("%PDF-".utf8)) != nil,
                   let document = PDFDocument(url: downloadURL), !document.isLocked, document.pageCount > 0 {
                    let file = directory.appendingPathComponent("manuscript.pdf")
                    try FileManager.default.moveItem(at: downloadURL, to: file)
                    try Task.checkCancellation()
                    keepDirectory = true
                    return DOIImportResult(metadata: record.metadata, fileURL: file, notice: nil, temporaryDirectory: directory)
                }

                // Parsing is bounded even when a publisher returns a large page or mislabels HTML as a PDF.
                let bytes = try readPrefix(downloadURL, count: DOIResourceLimits.metadataBytes)
                if let html = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1),
                   html.contains("<") {
                    let landing = DOILandingPage(html: html, url: http.url!, reference: reference)
                    failures.accessDenied = failures.accessDenied || landing.accessDenied
                    if landing.matchesReference {
                        let discovered = landing.pdfURLs + DOILandingPage.headerPDFs(http)
                        candidates.insert(contentsOf: discovered.filter { !visited.contains($0.absoluteString) }.prefix(8), at: 0)
                    }
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                failures.record(error: error)
            }
        }
        try Task.checkCancellation()
        return DOIImportResult(metadata: record.metadata, fileURL: nil, notice: failures.notice, temporaryDirectory: nil)
    }

    private func metadata(for reference: DOIReference, deadline: Date) async throws -> DOIMetadataRecord {
        var firstError: Error?
        do {
            let request = try makeRequest(reference.metadataURL, accept: "application/json", deadline: deadline)
            let (data, response) = try await transport.data(for: request)
            try Task.checkCancellation()
            let http = try validatedResponse(response)
            guard http.statusCode == 200 else { throw DOIImportError.metadataHTTP(http.statusCode) }
            return try DOIMetadataRecord(data: data, reference: reference, crossref: true)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            firstError = error
        }
        // DOI content negotiation also supports DataCite and other registration agencies.
        do {
            let request = try makeRequest(reference.url, accept: "application/vnd.citationstyles.csl+json", deadline: deadline)
            let (data, response) = try await transport.data(for: request)
            try Task.checkCancellation()
            let http = try validatedResponse(response)
            guard http.statusCode == 200 else { throw DOIImportError.metadataHTTP(http.statusCode) }
            return try DOIMetadataRecord(data: data, reference: reference, crossref: false)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if case DOIImportError.metadataHTTP(404) = error { throw DOIImportError.notFound }
            if let network = error as? URLError { throw DOIImportError.metadataNetwork(network.localizedDescription) }
            if let network = firstError as? URLError { throw DOIImportError.metadataNetwork(network.localizedDescription) }
            throw DOIImportError.metadataUnavailable
        }
    }

    private func makeRequest(_ url: URL, accept: String, deadline: Date) throws -> URLRequest {
        guard DOINetworkPolicy.allows(url) else { throw DOIImportError.unsafeURL }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw URLError(.timedOut) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: min(25, remaining))
        request.setValue("Bib/1.0 (native paper library)", forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return request
    }

    private func validatedResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse, let url = http.url else { throw DOIImportError.invalidResponse }
        guard DOINetworkPolicy.allows(url) else { throw DOIImportError.unsafeURL }
        return http
    }

    private func readPrefix(_ file: URL, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return try handle.read(upToCount: count) ?? Data()
    }
}

private struct DOIMetadataRecord {
    let metadata: PaperMetadata
    let pdfURLs: [URL]

    init(data: Data, reference: DOIReference, crossref: Bool) throws {
        guard data.count <= DOIResourceLimits.metadataBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = crossref ? object["message"] as? [String: Any] : object,
              let doi = record["DOI"] as? String ?? record["doi"] as? String,
              reference.matches(doi) else { throw DOIImportError.metadataUnavailable }
        func text(_ key: String) -> String {
            let value = record[key] as? String ?? (record[key] as? [String])?.first ?? ""
            return DOIText.cleaned(value)
        }
        let authors = (record["author"] as? [[String: Any]] ?? []).compactMap { author -> String? in
            let value = author["literal"] as? String ?? author["name"] as? String
                ?? [author["given"] as? String, author["family"] as? String].compactMap { $0 }.joined(separator: " ")
            let name = DOIText.cleaned(value)
            return name.isEmpty ? nil : name
        }.joined(separator: ", ")
        var year = ""
        for key in ["published-print", "published-online", "published", "issued"] {
            if let date = record[key] as? [String: Any],
               let parts = date["date-parts"] as? [[Int]], let first = parts.first?.first, first > 0 {
                year = String(first)
                break
            }
        }
        let title = text("title")
        metadata = PaperMetadata(title: title.isEmpty ? reference.id : title, authors: authors,
                                 year: year, venue: text("container-title"), doi: reference.id)
        let links = record["link"] as? [[String: Any]] ?? []
        pdfURLs = links.compactMap { link in
            guard let address = link["URL"] as? String,
                  (link["content-type"] as? String)?.lowercased() == "application/pdf"
                    || URL(string: address)?.path.lowercased().hasSuffix(".pdf") == true else { return nil }
            return DOINetworkPolicy.secureURL(address)
        }.prefix(3).map { $0 }
    }
}

/// No credentials, local addresses, custom ports, or insecure outgoing requests, including redirects.
enum DOINetworkPolicy {
    static func allows(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased(), host.utf8.count <= 253,
              host.range(of: #"^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil else { return false }
        let reserved = ["localhost", "local", "internal", "lan", "home", "test", "invalid", "onion"]
        return !reserved.contains(where: { host == $0 || host.hasSuffix("." + $0) })
    }

    static func secureURL(_ address: String, relativeTo base: URL? = nil) -> URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)?.absoluteURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if components.scheme?.lowercased() == "http" { components.scheme = "https" }
        components.fragment = nil
        guard let secure = components.url, allows(secure) else { return nil }
        return secure
    }
}

private enum DOIResourceLimits {
    static let metadataBytes = 4 * 1_024 * 1_024
    static let pdfBytes = 100 * 1_024 * 1_024
}

private final class DOITransferDelegate: NSObject, URLSessionDownloadDelegate {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var exceeded = false

    init(maximumBytes: Int = DOIResourceLimits.pdfBytes) { self.maximumBytes = maximumBytes }

    var exceededLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exceeded
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, let secure = DOINetworkPolicy.secureURL(url.absoluteString) else {
            completionHandler(nil)
            return
        }
        var redirected = request
        redirected.url = secure
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
            lock.lock()
            exceeded = true
            lock.unlock()
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

private final class DOIURLSessionTransport: DOIHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    init() {
        // Default storage retains cookies set by publishers in this app. Safari's sessions are separate.
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 45
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: DOITransferDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (file, response) = try await limitedDownload(for: request, maximumBytes: DOIResourceLimits.metadataBytes)
        defer { try? FileManager.default.removeItem(at: file) }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= DOIResourceLimits.metadataBytes else { throw DOIImportError.responseTooLarge }
        return (try Data(contentsOf: file), response)
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        try await limitedDownload(for: request, maximumBytes: DOIResourceLimits.pdfBytes)
    }

    private func limitedDownload(for request: URLRequest, maximumBytes: Int) async throws -> (URL, URLResponse) {
        let delegate = DOITransferDelegate(maximumBytes: maximumBytes)
        do { return try await session.download(for: request, delegate: delegate) }
        catch {
            if delegate.exceededLimit { throw DOIImportError.responseTooLarge }
            throw error
        }
    }
}

private struct DownloadFailures {
    var accessDenied = false
    var networkFailed = false
    var serverFailed = false
    var tooLarge = false

    mutating func record(status: Int) {
        if [401, 402, 403].contains(status) { accessDenied = true }
        if status == 429 || status >= 500 { serverFailed = true }
    }

    mutating func record(error: Error) {
        if error is URLError { networkFailed = true }
        if case DOIImportError.responseTooLarge = error { tooLarge = true }
    }

    var notice: String {
        let reason: String
        if accessDenied {
            reason = "The publisher did not allow the PDF download. Access may require a paid subscription, an institutional connection, or signing in on the publisher’s website. Some publishers also block automatic downloads."
        } else if networkFailed {
            reason = "The PDF could not be downloaded because a connection failed or timed out. Open the DOI link to try again later."
        } else if serverFailed {
            reason = "The publisher is temporarily unavailable or is limiting downloads. Open the DOI link to try again later."
        } else if tooLarge {
            reason = "The PDF exceeds Bib’s 100 MB download limit. You can download it from the DOI link and import it yourself."
        } else {
            reason = "No readable PDF could be downloaded. Access may require a subscription or sign-in, or the publisher may not provide a direct PDF link."
        }
        return reason
    }
}

/// Extract only publisher-advertised PDF links; do not guess paid URLs or follow unrelated pages.
private struct DOILandingPage {
    let pdfURLs: [URL]
    let matchesReference: Bool
    let accessDenied: Bool

    init(html: String, url: URL, reference: DOIReference) {
        let source = html.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        let tags = DOIText.matches(#"(?is)<(?:meta|link)\b[^>]*>"#, in: source)
        var discovered: [URL] = []
        var identifiers: [String] = []
        for tag in tags {
            let attributes = DOIText.attributes(tag)
            let name = (attributes["name"] ?? attributes["property"] ?? "").lowercased()
            if ["citation_doi", "dc.identifier", "dc.identifier.doi", "prism.doi"].contains(name),
               let content = attributes["content"], (try? DOIReference(content)) != nil { identifiers.append(content) }
            if name == "citation_pdf_url", let content = attributes["content"],
               let pdf = DOINetworkPolicy.secureURL(content, relativeTo: url) { discovered.append(pdf) }
            if attributes["type"]?.lowercased() == "application/pdf", let href = attributes["href"],
               let pdf = DOINetworkPolicy.secureURL(href, relativeTo: url) { discovered.append(pdf) }
        }
        matchesReference = identifiers.isEmpty || identifiers.contains(where: reference.matches)
        for anchor in DOIText.matches(#"(?is)<a\b[^>]*>[\s\S]*?</a\s*>"#, in: source).prefix(3_000) {
            guard let end = anchor.firstIndex(of: ">") else { continue }
            let attributes = DOIText.attributes(String(anchor[...end]))
            guard let href = attributes["href"], let pdf = DOINetworkPolicy.secureURL(href, relativeTo: url) else { continue }
            let label = DOIText.cleaned(anchor).lowercased()
            let path = pdf.path.lowercased()
            let supplement = ["supplement", "supporting", "appendix"].contains { label.contains($0) || path.contains($0) }
            let pdfPath = path.hasSuffix(".pdf") || path.contains("/pdf/") || path.contains("/epdf/") || path.contains("/pdfft")
            // A landing page can also advertise PDFs for recommended papers. A generic anchor
            // needs an exact DOI association; the page's own citation_doi is not enough.
            let components = URLComponents(url: pdf, resolvingAgainstBaseURL: false)
            let associatedPath = components?.path.lowercased().hasSuffix("/" + reference.id.lowercased()) == true
            let associatedQuery = components?.queryItems?.contains { item in
                item.value?.caseInsensitiveCompare(reference.id) == .orderedSame
            } == true
            if !supplement, pdfPath, associatedPath || associatedQuery,
               label.contains("pdf") || label.contains("download") { discovered.append(pdf) }
        }
        // arXiv's DOI landing page is stable and explicitly identifies the same manuscript.
        if ["arxiv.org", "www.arxiv.org"].contains(url.host?.lowercased() ?? ""), url.path.hasPrefix("/abs/") {
            let path = url.path.replacingOccurrences(of: "/abs/", with: "/pdf/", range: url.path.startIndex..<url.path.index(url.path.startIndex, offsetBy: 5))
            if let pdf = DOINetworkPolicy.secureURL(path, relativeTo: url) { discovered.append(pdf) }
        }
        pdfURLs = Array(discovered.prefix(8))
        let lower = DOIText.cleaned(source).lowercased()
        accessDenied = ["purchase access", "purchase this article", "rent this article", "subscription required",
                        "subscribe to access", "sign in to access", "log in to access", "you do not have access",
                        "access through your institution", "verify you are human", "enable javascript and cookies",
                        "checking your browser", "access denied"].contains(where: lower.contains)
    }

    static func headerPDFs(_ response: HTTPURLResponse) -> [URL] {
        guard let header = response.value(forHTTPHeaderField: "Link"), let base = response.url else { return [] }
        return header.components(separatedBy: ",").compactMap { part in
            guard part.lowercased().contains("application/pdf"), let start = part.firstIndex(of: "<"),
                  let end = part[start...].firstIndex(of: ">"), start < end else { return nil }
            return DOINetworkPolicy.secureURL(String(part[part.index(after: start)..<end]), relativeTo: base)
        }
    }
}

private enum DOIText {
    static func matches(_ pattern: String, in value: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = value as NSString
        return expression.matches(in: value, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range) }
    }

    static func attributes(_ tag: String) -> [String: String] {
        let pattern = #"([\w:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let source = tag as NSString
        var result: [String: String] = [:]
        for match in expression.matches(in: tag, range: NSRange(location: 0, length: source.length)) {
            let name = source.substring(with: match.range(at: 1)).lowercased()
            for index in 2...4 where match.range(at: index).location != NSNotFound {
                result[name] = decoded(source.substring(with: match.range(at: index)))
                break
            }
        }
        return result
    }

    static func cleaned(_ text: String) -> String {
        decoded(text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func decoded(_ text: String) -> String {
        var result = text
        let entities = ["&quot;": "\"", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (name, value) in entities { result = result.replacingOccurrences(of: name, with: value) }
        for entity in matches(#"&#(?:[xX][0-9a-fA-F]+|[0-9]+);"#, in: result) {
            let digits = String(entity.dropFirst(2).dropLast())
            let hex = digits.lowercased().hasPrefix("x")
            if let value = UInt32(hex ? String(digits.dropFirst()) : digits, radix: hex ? 16 : 10),
               let scalar = Unicode.Scalar(value) { result = result.replacingOccurrences(of: entity, with: String(scalar)) }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}

enum DOIImportError: LocalizedError {
    case invalidReference, unsafeURL, invalidResponse, responseTooLarge, metadataUnavailable, notFound
    case metadataHTTP(Int)
    case metadataNetwork(String)

    var errorDescription: String? {
        switch self {
        case .invalidReference: return "Enter a DOI such as 10.1038/nature12373 or a link from doi.org."
        case .unsafeURL: return "The publisher returned an unsupported download address."
        case .invalidResponse: return "The publisher returned an unexpected response."
        case .responseTooLarge: return "The response exceeds Bib’s download size limit."
        case .metadataUnavailable: return "Paper details could not be retrieved for this DOI. Check the DOI or try again later."
        case .notFound: return "No paper was found for this DOI. Check the DOI and try again."
        case .metadataHTTP(let status): return "The metadata service returned HTTP \(status). Try again later."
        case .metadataNetwork(let message): return "Paper details could not be retrieved. \(message)"
        }
    }
}
