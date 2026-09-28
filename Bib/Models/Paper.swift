import Foundation

/// Retrieved paper details; blank values leave embedded PDF metadata intact during PDF import.
struct PaperMetadata: Equatable, Sendable {
    var title: String = ""
    var authors: String = ""
    var year: String = ""
    var venue: String = ""
    var doi: String = ""
}

struct Paper: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var authors: String
    var year: String
    var venue: String
    var doi: String
    var folderID: UUID?
    var fileName: String?
    let addedAt: Date

    var hasPDF: Bool { fileName != nil }

    /// Always build the resolver URL ourselves so edited metadata cannot become an arbitrary link.
    var doiURL: URL? {
        var identifier = doi.trimmingCharacters(in: .whitespacesAndNewlines)
        if identifier.lowercased().hasPrefix("doi:") {
            identifier = String(identifier.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if identifier.lowercased().hasPrefix("http://") || identifier.lowercased().hasPrefix("https://") {
            guard let source = URLComponents(string: identifier),
                  let host = source.host?.lowercased(),
                  ["doi.org", "dx.doi.org", "www.doi.org"].contains(host),
                  source.user == nil, source.password == nil, source.port == nil else { return nil }
            identifier = String(source.path.drop(while: { $0 == "/" }))
        }
        guard identifier.range(of: #"^10\.\d{4,9}/\S+$"#, options: .regularExpression) != nil,
              identifier.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            return nil
        }
        var resolver = URLComponents()
        resolver.scheme = "https"
        resolver.host = "doi.org"
        resolver.path = "/" + identifier
        return resolver.url
    }

    init(
        id: UUID = UUID(),
        title: String,
        authors: String = "",
        year: String = "",
        venue: String = "",
        doi: String = "",
        folderID: UUID? = nil,
        fileName: String? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.year = year
        self.venue = venue
        self.doi = doi
        self.folderID = folderID
        self.fileName = fileName
        self.addedAt = addedAt
    }
}

struct PaperFolder: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}
