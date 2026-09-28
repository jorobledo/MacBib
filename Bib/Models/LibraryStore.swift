import Combine
import Foundation
import PDFKit

/// Owns a local library and copies imported PDFs so their original locations can change.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var papers: [Paper] = []
    @Published private(set) var folders: [PaperFolder] = []
    @Published var errorMessage: String?

    private let directory: URL
    private let documentsURL: URL
    private let libraryURL: URL
    private let fileManager = FileManager.default
    private var loadError: String?

    private struct Library: Codable {
        let version: Int
        var papers: [Paper]
        var folders: [PaperFolder]
    }

    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Bib", isDirectory: true)
        self.directory = root
        documentsURL = root.appendingPathComponent("Documents", isDirectory: true)
        libraryURL = root.appendingPathComponent("library.json")

        do {
            try fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: libraryURL.path) {
                let data = try Data(contentsOf: libraryURL)
                let library = try JSONDecoder().decode(Library.self, from: data)
                try validate(library)
                papers = library.papers
                folders = library.folders
            }
        } catch {
            let message = "Your library could not be opened. Its saved data has been left untouched. "
                + "Resolve the problem at \(root.path), then reopen Bib. \(error.localizedDescription)"
            loadError = message
            errorMessage = message
        }
    }

    func fileURL(for paper: Paper) -> URL? {
        guard let fileName = paper.fileName, isValidFileName(fileName) else { return nil }
        return documentsURL.appendingPathComponent(fileName)
    }

    /// Each file is imported independently; one bad PDF does not discard successful imports.
    @discardableResult
    func importPDFs(from urls: [URL], into folderID: UUID? = nil) -> [UUID] {
        importPDFs(from: urls, metadata: nil, into: folderID)
    }

    /// Copy a completed download and save its metadata together, before publishing it.
    @discardableResult
    func importDownloadedPDF(from url: URL, metadata: PaperMetadata?, into folderID: UUID? = nil) -> UUID? {
        importPDFs(from: [url], metadata: metadata, into: folderID).first
    }

    /// Keep the reference even when a publisher does not provide an accessible PDF.
    @discardableResult
    func importMetadata(_ metadata: PaperMetadata, into folderID: UUID? = nil) -> UUID? {
        guard canEdit() else { return nil }
        guard folderExists(folderID) else {
            errorMessage = "The destination folder no longer exists. Choose another folder and try again."
            return nil
        }
        guard let title = metadata.title.nonemptyTrimmed ?? metadata.doi.nonemptyTrimmed else {
            errorMessage = "Give the paper a title or DOI before importing."
            return nil
        }
        let paper = Paper(
            title: title,
            authors: metadata.authors.trimmed,
            year: metadata.year.trimmed,
            venue: metadata.venue.trimmed,
            doi: metadata.doi.trimmed,
            folderID: folderID
        )
        return commit(papers: [paper] + papers, folders: folders) ? paper.id : nil
    }

    /// Attach a copy to the latest saved reference without replacing metadata or folder edits.
    @discardableResult
    func attachPDF(from sourceURL: URL, to paperID: UUID) -> Bool {
        guard canEdit() else { return false }
        guard let index = papers.firstIndex(where: { $0.id == paperID }) else {
            errorMessage = "This paper no longer exists. Choose another paper and try again."
            return false
        }
        guard !papers[index].hasPDF else {
            errorMessage = "This paper already has a PDF."
            return false
        }

        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }
        do {
            _ = try validatedPDF(at: sourceURL)
            let fileName = UUID().uuidString + ".pdf"
            let destinationURL = documentsURL.appendingPathComponent(fileName)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            var updatedPapers = papers
            updatedPapers[index].fileName = fileName
            guard commit(papers: updatedPapers, folders: folders) else {
                let saveError = errorMessage ?? "The library could not be saved."
                do {
                    try fileManager.removeItem(at: destinationURL)
                } catch {
                    errorMessage = saveError + " An unused copy also remains at \(destinationURL.path)."
                }
                return false
            }
            return true
        } catch {
            errorMessage = "\(sourceURL.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    private func importPDFs(from urls: [URL], metadata: PaperMetadata?, into folderID: UUID?) -> [UUID] {
        guard canEdit() else { return [] }
        guard folderExists(folderID) else {
            errorMessage = "The destination folder no longer exists. Choose another folder and try again."
            return []
        }

        var importedIDs: [UUID] = []
        var failures: [String] = []

        for sourceURL in urls {
            let hasAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
            }

            do {
                let document = try validatedPDF(at: sourceURL)

                let attributes = document.documentAttributes ?? [:]
                let embeddedTitle = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?.nonemptyTrimmed
                let embeddedAuthors = (attributes[PDFDocumentAttribute.authorAttribute] as? String)?.trimmed ?? ""
                let fileName = UUID().uuidString + ".pdf"
                let paper = Paper(
                    title: metadata?.title.nonemptyTrimmed
                        ?? embeddedTitle
                        ?? sourceURL.deletingPathExtension().lastPathComponent,
                    authors: metadata?.authors.nonemptyTrimmed ?? embeddedAuthors,
                    year: metadata?.year.trimmed ?? "",
                    venue: metadata?.venue.trimmed ?? "",
                    doi: metadata?.doi.trimmed ?? "",
                    folderID: folderID,
                    fileName: fileName
                )
                let destinationURL = documentsURL.appendingPathComponent(fileName)
                try fileManager.copyItem(at: sourceURL, to: destinationURL)

                if commit(papers: [paper] + papers, folders: folders) {
                    importedIDs.append(paper.id)
                } else {
                    let saveError = errorMessage ?? "The library could not be saved."
                    do {
                        try fileManager.removeItem(at: destinationURL)
                        failures.append("\(sourceURL.lastPathComponent): \(saveError)")
                    } catch {
                        failures.append("\(sourceURL.lastPathComponent): \(saveError) "
                            + "An unused copy also remains at \(destinationURL.path).")
                    }
                }
            } catch {
                failures.append("\(sourceURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n\n")
        return importedIDs
    }

    @discardableResult
    func addFolder(named name: String) -> UUID? {
        guard canEdit(), let name = validFolderName(name) else { return nil }
        let folder = PaperFolder(name: name)
        return commit(papers: papers, folders: folders + [folder]) ? folder.id : nil
    }

    func renameFolder(id: UUID, to name: String) {
        guard canEdit(), let index = folders.firstIndex(where: { $0.id == id }) else { return }
        guard let name = validFolderName(name, excluding: id) else { return }
        var updatedFolders = folders
        updatedFolders[index].name = name
        commit(papers: papers, folders: updatedFolders)
    }

    /// Removing a folder keeps its papers and moves them back to the unfiled library.
    func deleteFolder(id: UUID) {
        guard canEdit(), folders.contains(where: { $0.id == id }) else { return }
        let updatedPapers = papers.map { paper in
            var updated = paper
            if updated.folderID == id { updated.folderID = nil }
            return updated
        }
        commit(papers: updatedPapers, folders: folders.filter { $0.id != id })
    }

    func updatePaper(_ paper: Paper) {
        guard canEdit(), let index = papers.firstIndex(where: { $0.id == paper.id }) else { return }
        guard !paper.title.trimmed.isEmpty else {
            errorMessage = "Give the paper a title before saving."
            return
        }
        guard folderExists(paper.folderID) else {
            errorMessage = "The selected folder no longer exists. Choose another folder and try again."
            return
        }
        guard paper.fileName == papers[index].fileName,
              paper.addedAt == papers[index].addedAt else {
            errorMessage = "The paper's managed file and import date cannot be changed."
            return
        }
        var updatedPapers = papers
        var updated = paper
        updated.title = updated.title.trimmed
        updated.authors = updated.authors.trimmed
        updated.year = updated.year.trimmed
        updated.venue = updated.venue.trimmed
        updated.doi = updated.doi.trimmed
        updatedPapers[index] = updated
        commit(papers: updatedPapers, folders: folders)
    }

    /// Move current records together so stale drag data cannot replace newer metadata.
    @discardableResult
    func movePapers(ids: [UUID], to folderID: UUID?) -> Bool {
        guard canEdit() else { return false }
        let selectedIDs = Set(ids)
        guard !selectedIDs.isEmpty else {
            errorMessage = "Choose at least one paper to move."
            return false
        }
        guard folderExists(folderID) else {
            errorMessage = "The destination folder no longer exists. Choose another folder and try again."
            return false
        }
        guard selectedIDs.isSubset(of: Set(papers.map(\.id))) else {
            errorMessage = "One or more selected papers no longer exist. Select the papers again and try another move."
            return false
        }

        var updatedPapers = papers
        var changed = false
        for index in updatedPapers.indices where selectedIDs.contains(updatedPapers[index].id) {
            if updatedPapers[index].folderID != folderID {
                updatedPapers[index].folderID = folderID
                changed = true
            }
        }
        guard changed else {
            errorMessage = nil
            return true
        }
        return commit(papers: updatedPapers, folders: folders)
    }

    func deletePaper(id: UUID) {
        guard canEdit(), let paper = papers.first(where: { $0.id == id }) else { return }
        // Persist first: a failed save must never remove a PDF that is still in the library.
        guard commit(papers: papers.filter { $0.id != id }, folders: folders) else { return }
        guard let url = fileURL(for: paper) else { return }
        if fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                errorMessage = "The paper was removed from the library, but its unused PDF copy "
                    + "could not be deleted at \(url.path). \(error.localizedDescription)"
            }
        }
    }

    private func canEdit() -> Bool {
        if let loadError {
            errorMessage = loadError
            return false
        }
        return true
    }

    private func folderExists(_ id: UUID?) -> Bool {
        id == nil || folders.contains(where: { $0.id == id })
    }

    private func validatedPDF(at sourceURL: URL) throws -> PDFDocument {
        guard sourceURL.isFileURL,
              sourceURL.pathExtension.lowercased() == "pdf",
              let document = PDFDocument(url: sourceURL) else {
            throw StoreError.invalidPDF
        }
        guard !document.isLocked else { throw StoreError.lockedPDF }
        guard document.pageCount > 0 else { throw StoreError.emptyPDF }
        return document
    }

    private func isValidFileName(_ fileName: String) -> Bool {
        !fileName.isEmpty
            && !fileName.contains("\\")
            && !fileName.contains("\0")
            && fileName == (fileName as NSString).lastPathComponent
            && (fileName as NSString).pathExtension.lowercased() == "pdf"
    }

    private func validFolderName(_ name: String, excluding id: UUID? = nil) -> String? {
        let name = name.trimmed
        guard !name.isEmpty else {
            errorMessage = "Enter a name for the folder."
            return nil
        }
        guard !folders.contains(where: {
            $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else {
            errorMessage = "A folder named “\(name)” already exists."
            return nil
        }
        return name
    }

    /// Publish new state only after its atomic disk write succeeds.
    @discardableResult
    private func commit(papers: [Paper], folders: [PaperFolder]) -> Bool {
        guard canEdit() else { return false }
        do {
            let library = Library(version: 1, papers: papers, folders: folders)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(library)
            try data.write(to: libraryURL, options: .atomic)
            self.papers = papers
            self.folders = folders
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Your change could not be saved. The library has not been changed. "
                + error.localizedDescription
            return false
        }
    }

    private func validate(_ library: Library) throws {
        guard library.version == 1 else { throw StoreError.unsupportedVersion }
        let folderIDs = Set(library.folders.map(\.id))
        let fileNames = library.papers.compactMap(\.fileName)
        guard Set(library.papers.map(\.id)).count == library.papers.count,
              folderIDs.count == library.folders.count,
              Set(fileNames).count == fileNames.count,
              library.papers.allSatisfy({ paper in
                  (paper.fileName.map(isValidFileName) ?? true)
                      && (paper.folderID == nil || folderIDs.contains(paper.folderID!))
              }) else {
            throw StoreError.invalidLibrary
        }
    }

    private enum StoreError: LocalizedError {
        case invalidPDF, lockedPDF, emptyPDF, unsupportedVersion, invalidLibrary

        var errorDescription: String? {
            switch self {
            case .invalidPDF: "This file could not be opened as a PDF."
            case .lockedPDF: "This PDF is password protected. Import an unlocked copy."
            case .emptyPDF: "This PDF does not contain any pages."
            case .unsupportedVersion: "This library uses an unsupported data format."
            case .invalidLibrary: "The saved library contains invalid or inconsistent records."
            }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var nonemptyTrimmed: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }
}
