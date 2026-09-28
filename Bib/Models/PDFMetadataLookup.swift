import Combine
import Foundation

/// Enrich saved local imports without keeping access to the originals or blocking the reader.
@MainActor
final class PDFMetadataLookup: ObservableObject {
    typealias Lookup = @Sendable (URL, String, String) async throws -> PaperMetadata?

    @Published private(set) var isSearching = false
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    @Published var notice: String?

    private let lookup: Lookup
    private var pending: [Paper] = []
    private var unavailableCount = 0
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(lookup: @escaping Lookup = { url, title, authors in
        try await PDFMetadataService.shared.lookup(fileURL: url, fallbackTitle: title, fallbackAuthors: authors)
    }) {
        self.lookup = lookup
    }

    /// Additional imports join the current queue. Each snapshot protects edits made during lookup.
    func enqueue(paperIDs: [UUID], in store: LibraryStore) {
        let papers = paperIDs.compactMap { id in store.papers.first { $0.id == id && $0.hasPDF } }
        guard !papers.isEmpty else { return }
        notice = nil
        if !isSearching {
            completedCount = 0
            totalCount = 0
            unavailableCount = 0
        }
        pending.append(contentsOf: papers)
        totalCount += papers.count
        guard !isSearching else { return }
        isSearching = true
        let run = UUID()
        generation = run
        task = Task { await process(in: store, run: run) }
    }

    func cancel(showNotice: Bool = true) {
        guard isSearching else { return }
        generation = UUID()
        task?.cancel()
        task = nil
        pending.removeAll()
        isSearching = false
        if showNotice { notice = "Metadata search stopped. Your imported PDFs are saved in the library." }
    }

    private func process(in store: LibraryStore, run: UUID) async {
        defer {
            if generation == run {
                isSearching = false
                task = nil
            }
        }
        while !pending.isEmpty {
            guard generation == run, !Task.isCancelled else { return }
            let original = pending.removeFirst()
            do {
                try await waitForStorage(in: store)
                guard let current = store.papers.first(where: { $0.id == original.id }),
                      let url = store.fileURL(for: current) else {
                    completedCount += 1
                    continue
                }
                // A folder migration may release the store's lease while extraction is running.
                let storageURL = store.storageFolderURL
                let hasAccess = storageURL.startAccessingSecurityScopedResource()
                defer { if hasAccess { storageURL.stopAccessingSecurityScopedResource() } }
                let metadata = try await lookup(url, original.title, original.authors)
                try Task.checkCancellation()
                guard generation == run else { return }
                try await waitForStorage(in: store)
                // A paper removed while the request was running must stay removed.
                if store.papers.contains(where: { $0.id == original.id }) {
                    if let metadata {
                        _ = store.applyRetrievedMetadata(metadata, to: original)
                    } else {
                        unavailableCount += 1
                    }
                }
            } catch {
                guard generation == run, !Task.isCancelled else { return }
                if store.papers.contains(where: { $0.id == original.id }) { unavailableCount += 1 }
            }
            completedCount += 1
        }
        if unavailableCount > 0 {
            let subject = unavailableCount == 1 ? "1 imported PDF" : "\(unavailableCount) imported PDFs"
            notice = "Online details weren’t available for \(subject). Your PDFs are saved; you can edit their details using Paper details."
        }
    }

    private func waitForStorage(in store: LibraryStore) async throws {
        while store.isMovingStorage {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try Task.checkCancellation()
    }
}
