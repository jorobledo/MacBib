import Foundation

/// Metadata retrieved alongside a PDF; blank values leave embedded PDF metadata intact.
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
    let fileName: String
    let addedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        authors: String = "",
        year: String = "",
        venue: String = "",
        doi: String = "",
        folderID: UUID? = nil,
        fileName: String,
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
