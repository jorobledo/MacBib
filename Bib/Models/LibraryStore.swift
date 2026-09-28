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

    func fileURL(for paper: Paper) -> URL {
        documentsURL.appendingPathComponent(paper.fileName)
    }

    /// Each file is imported independently; one bad PDF does not discard successful imports.
    @discardableResult
    func importPDFs(from urls: [URL], into folderID: UUID? = nil) -> [UUID] {
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
                guard sourceURL.isFileURL,
                      sourceURL.pathExtension.lowercased() == "pdf",
                      let document = PDFDocument(url: sourceURL) else {
                    throw StoreError.invalidPDF
                }
                guard !document.isLocked else { throw StoreError.lockedPDF }
                guard document.pageCount > 0 else { throw StoreError.emptyPDF }

                let attributes = document.documentAttributes ?? [:]
                let metadataTitle = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?.trimmed ?? ""
                let title = metadataTitle.isEmpty
                    ? sourceURL.deletingPathExtension().lastPathComponent
                    : metadataTitle
                let paper = Paper(
                    title: title,
                    authors: (attributes[PDFDocumentAttribute.authorAttribute] as? String)?.trimmed ?? "",
                    folderID: folderID,
                    fileName: UUID().uuidString + ".pdf"
                )
                let destinationURL = fileURL(for: paper)
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
        let url = fileURL(for: paper)
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
        guard Set(library.papers.map(\.id)).count == library.papers.count,
              folderIDs.count == library.folders.count,
              Set(library.papers.map(\.fileName)).count == library.papers.count,
              library.papers.allSatisfy({ paper in
                  !paper.fileName.isEmpty
                      && paper.fileName == (paper.fileName as NSString).lastPathComponent
                      && (paper.fileName as NSString).pathExtension.lowercased() == "pdf"
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
}
