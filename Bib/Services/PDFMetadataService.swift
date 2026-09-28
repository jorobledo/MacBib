import Foundation
import PDFKit

/// Looks up bibliographic details for an existing file; the PDF itself never leaves the device.
actor PDFMetadataService {
    static let shared = PDFMetadataService()

    private let doiService: DOIImportService
    private let arxivService: ArxivImportService

    init(doiService: DOIImportService = .shared, arxivService: ArxivImportService = .shared) {
        self.doiService = doiService
        self.arxivService = arxivService
    }

    func lookup(fileURL: URL, fallbackTitle: String, fallbackAuthors: String) async throws -> PaperMetadata? {
        try Task.checkCancellation()
        // PDFKit access stays on this actor, away from the main actor and the reader's PDFDocument.
        guard let document = PDFDocument(url: fileURL), !document.isLocked, document.pageCount > 0 else { return nil }
        var attributes: [String: String] = [:]
        for (key, value) in document.documentAttributes ?? [:] {
            let name = String(describing: key).lowercased()
            guard ["title", "author", "subject", "keywords"].contains(name)
                    || name.contains("doi") || name.contains("arxiv") || name.contains("identifier") else { continue }
            if let string = value as? String { attributes[name] = String(string.prefix(4_000)) }
            else if let strings = value as? [String] {
                attributes[name] = String(strings.prefix(20).map { String($0.prefix(200)) }.joined(separator: "\n").prefix(4_000))
            }
        }
        let evidence = PDFMetadataEvidence(attributes: attributes,
                                           firstPageText: String((document.page(at: 0)?.string ?? "").prefix(12_000)),
                                           fallbackTitle: fallbackTitle, fallbackAuthors: fallbackAuthors)
        try Task.checkCancellation()
        if let reference = evidence.arxiv {
            return try await arxivService.metadata(for: reference)
        }
        if let reference = evidence.doi {
            return try await doiService.metadata(for: reference)
        }
        guard let title = evidence.title else { return nil }
        let candidates = try await doiService.searchMetadata(title: title)
        try Task.checkCancellation()
        return PDFMetadataMatch.select(candidates, title: title, authors: evidence.authors)
    }
}

/// A single-page, bounded extraction avoids treating the paper's bibliography as its identity.
struct PDFMetadataEvidence {
    let doi: DOIReference?
    let arxiv: ArxivReference?
    let title: String?
    let authors: String

    init(attributes: [String: String], firstPageText: String, fallbackTitle: String, fallbackAuthors: String) {
        let page = Self.beforeReferences(String(firstPageText.prefix(12_000)))
        let identifierFields = attributes.filter {
            $0.key.contains("doi") || $0.key.contains("arxiv") || $0.key.contains("identifier")
        }.sorted { $0.key < $1.key }.prefix(10).map { String($0.value.prefix(4_000)) }.joined(separator: "\n")
        let descriptiveFields = ["title", "subject", "keywords"].compactMap { attributes[$0] }
            .map { String($0.prefix(4_000)) }.joined(separator: "\n")
        let metadata = identifierFields + "\n" + descriptiveFields
        doi = Self.singleDOI(in: identifierFields, standalone: false)
            ?? Self.singleDOI(in: descriptiveFields, standalone: false)
            ?? Self.singleDOI(in: page, standalone: true)
        arxiv = Self.singleArxiv(in: metadata, standalone: false)
            ?? Self.singleArxiv(in: page, standalone: true)
            ?? (try? ArxivReference(fallbackTitle.replacingOccurrences(of: "_", with: "/")))
        title = Self.plausibleTitle(attributes["title"] ?? "")
            ?? Self.plausibleTitle(fallbackTitle)
            ?? Self.pageTitle(page)
        authors = String((attributes["author"] ?? fallbackAuthors).prefix(500))
    }

    private static func beforeReferences(_ text: String) -> String {
        guard let range = text.range(of: #"(?im)^\s*(?:\d+[. ]+)?(?:references|bibliography|literature cited)\s*[:.]?\s*$"#,
                                     options: .regularExpression) else { return text }
        return String(text[..<range.lowerBound])
    }

    private static func singleDOI(in text: String, standalone: Bool) -> DOIReference? {
        let pattern = #"(?i)(?:(?:https?://)?(?:www\.|dx\.)?doi\.org/)?10\.[0-9]{4,9}/[^\s<>\"“”]+"#
        var found: [DOIReference] = []
        for line in text.components(separatedBy: .newlines) {
            for match in matches(pattern, in: line) {
                let prefix = String(line[..<match.lowerBound]).trimmingCharacters(in: .whitespaces)
                if standalone {
                    // Citations in prose (even on page one) are not the document's DOI.
                    let lead = prefix.lowercased()
                    guard lead.isEmpty || lead.range(of: #"^(?:doi\s*:?\s*|digital object identifier\s*:\s*)$"#,
                                                                    options: .regularExpression) != nil else { continue }
                    guard line.count <= 300 else { continue }
                }
                let candidate = trimCitationPunctuation(String(line[match]))
                guard let reference = try? DOIReference(candidate) else { continue }
                if !found.contains(where: { $0.id.caseInsensitiveCompare(reference.id) == .orderedSame }) { found.append(reference) }
            }
        }
        return found.count == 1 ? found.first : nil
    }

    private static func singleArxiv(in text: String, standalone: Bool) -> ArxivReference? {
        let pattern = #"(?i)(?:arxiv\s*:\s*|(?:https?://)?(?:www\.|export\.)?arxiv\.org/(?:abs|pdf|html)/)(?:[0-9]{4}\.[0-9]{4,5}|[a-z][a-z0-9.-]*/[0-9]{7})(?:v[1-9][0-9]*)?(?:\.pdf)?"#
        var found: [ArxivReference] = []
        for line in text.components(separatedBy: .newlines) {
            for match in matches(pattern, in: line) {
                if standalone, !line[..<match.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty { continue }
                let value = String(line[match]).replacingOccurrences(of: #"(?i)^arxiv\s*:\s*"#, with: "arxiv:", options: .regularExpression)
                guard let reference = try? ArxivReference(value) else { continue }
                if !found.contains(reference) { found.append(reference) }
            }
        }
        // Explicit arXiv metadata often stores the bare ID in an identifier field.
        if found.isEmpty, let reference = try? ArxivReference(text) { return reference }
        return found.count == 1 ? found.first : nil
    }

    private static func trimCitationPunctuation(_ text: String) -> String {
        var value = text.trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
        for (open, close) in [("(", ")"), ("[", "]"), ("{", "}")] {
            while value.hasSuffix(close), value.filter({ String($0) == close }).count > value.filter({ String($0) == open }).count {
                value.removeLast()
            }
        }
        return value
    }

    private static func matches(_ pattern: String, in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(20)
            .compactMap { Range($0.range, in: text) }
    }

    static func plausibleTitle(_ source: String) -> String? {
        guard source.count <= 350 else { return nil }
        var title = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.lowercased().hasSuffix(".pdf") { title.removeLast(4) }
        title = title.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let normalized = PDFMetadataMatch.normalized(title)
        let words = normalized.split(separator: " ")
        let meaningful = words.filter { $0.count >= 3 && $0.rangeOfCharacter(from: .letters) != nil }
        guard title.count >= 18, words.count >= 3, words.count <= 45, meaningful.count >= 3,
              !normalized.hasPrefix("microsoft word"), !normalized.hasPrefix("untitled"),
              !normalized.hasPrefix("latex"), !normalized.hasPrefix("arxiv"),
              !normalized.hasPrefix("doi "),
              !["document", "manuscript", "paper", "scan"].contains(normalized),
              title.range(of: #"(?i)(https?://|\.docx?\b|\.tex\b|10\.[0-9]{4,9}/)"#, options: .regularExpression) == nil else { return nil }
        return title
    }

    private static func pageTitle(_ page: String) -> String? {
        for source in page.components(separatedBy: .newlines).prefix(12) {
            let line = source.trimmingCharacters(in: .whitespaces)
            let normalized = PDFMetadataMatch.normalized(line)
            if normalized == "abstract" || normalized.hasPrefix("abstract ") || normalized == "introduction" { break }
            guard !line.contains("@"),
                  !["journal of ", "proceedings of ", "published ", "copyright ", "accepted ", "received ", "university ", "department "]
                    .contains(where: { normalized.hasPrefix($0) }) else { continue }
            if let title = plausibleTitle(line) { return title }
        }
        return nil
    }
}

enum PDFMetadataMatch {
    static func select(_ candidates: [PaperMetadata], title: String, authors: String) -> PaperMetadata? {
        let expected = normalized(title)
        let expectedAuthors = authorNames(authors)
        var matches: [PaperMetadata] = []
        var seen = Set<String>()
        for candidate in candidates {
            guard normalized(candidate.title) == expected,
                  seen.insert(candidate.doi.lowercased()).inserted else { continue }
            let returnedAuthors = authorNames(candidate.authors)
            if !expectedAuthors.isEmpty, !returnedAuthors.isEmpty,
               expectedAuthors.isDisjoint(with: returnedAuthors) { continue }
            matches.append(candidate)
        }
        // Crossref may contain multiple papers or editions with the same title. Do not guess.
        return matches.count == 1 ? matches.first : nil
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func authorNames(_ value: String) -> Set<String> {
        Set(value.components(separatedBy: CharacterSet(charactersIn: ",;"))
            .compactMap { normalized($0).split(separator: " ").last.map(String.init) }
            .filter { $0.count > 2 && !["unknown", "author", "authors", "anonymous"].contains($0) })
    }
}
