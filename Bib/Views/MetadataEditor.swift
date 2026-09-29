import SwiftUI

struct MetadataEditor: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var paper: Paper
    @State private var confirmingDelete = false
    @State private var saveError: String?
    @State private var metadataInput: String
    @State private var metadataTask: Task<Void, Never>?
    @State private var metadataMessage: String?
    @State private var metadataError: String?

    init(store: LibraryStore, paper: Paper) {
        self.store = store
        _paper = State(initialValue: paper)
        _metadataInput = State(initialValue: paper.doi)
    }

    private var isFetchingMetadata: Bool { metadataTask != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("DOI or paper URL", text: $metadataInput,
                              prompt: Text("10.1038/nature12373 or https://doi.org/…"))
                        .autocorrectionDisabled()
                        .onSubmit(fetchMetadata)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    Button(action: fetchMetadata) {
                        if isFetchingMetadata {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Fetching metadata…")
                            }
                        } else {
                            Label("Fetch metadata", systemImage: "arrow.down.circle")
                        }
                    }
                    .disabled(isFetchingMetadata || metadataInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let metadataMessage {
                        Text(metadataMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let metadataError {
                        Text(metadataError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Find metadata")
                } footer: {
                    Text("Paste a DOI, doi.org link, arXiv link, or a publisher URL containing a DOI. Retrieved details fill the fields below so you can review them before saving.")
                }

                Section("Paper") {
                    TextField("Title", text: $paper.title, axis: .vertical)
                        .lineLimit(2...5)
                    TextField("Authors", text: $paper.authors)
                    TextField("Year", text: $paper.year)
                    TextField("Journal / venue", text: $paper.venue)
                    TextField("DOI", text: $paper.doi)
                        .autocorrectionDisabled()
                    if let url = paper.doiURL {
                        Link("Open DOI", destination: url)
                    }
                    LabeledContent("PDF", value: paper.hasPDF ? "In library" : "Not downloaded")
                }
                Section("Organization") {
                    Picker("Folder", selection: $paper.folderID) {
                        Text("Unfiled").tag(nil as UUID?)
                        ForEach(store.folders) { folder in
                            Text(folder.name).tag(Optional(folder.id))
                        }
                    }
                    LabeledContent("Added", value: paper.addedAt.formatted(date: .abbreviated, time: .omitted))
                }
                Section {
                    Button("Remove from library", role: .destructive) { confirmingDelete = true }
                } footer: {
                    Text(paper.hasPDF ? "Bib keeps its own copy of your PDF. Your original file stays where it is." : "Paper details and the DOI link are saved even without a PDF.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Paper details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        metadataTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = paper
                        if let current = store.papers.first(where: { $0.id == paper.id }) {
                            // A download may have attached a PDF while these details were being edited.
                            updated.fileName = current.fileName
                        }
                        store.updatePaper(updated)
                        finishEditingIfSuccessful()
                    }
                    .disabled(isFetchingMetadata || paper.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Remove this paper?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Remove paper", role: .destructive) {
                    store.deletePaper(id: paper.id)
                    if store.papers.contains(where: { $0.id == paper.id }) {
                        finishEditingIfSuccessful()
                    } else {
                        dismiss()
                    }
                }
            } message: {
                Text(paper.hasPDF ? "This removes the paper and Bib’s stored PDF copy. Your original file is unchanged." : "This removes the paper details and DOI link from your library.")
            }
            .alert("Couldn’t save changes", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "Please try again.")
            }
        }
        .interactiveDismissDisabled(isFetchingMetadata)
        .onDisappear { metadataTask?.cancel() }
        #if os(macOS)
        .frame(width: 500, height: 680)
        #endif
    }

    private func fetchMetadata() {
        guard !isFetchingMetadata else { return }
        let source: MetadataSource
        do {
            source = try MetadataSource(metadataInput)
        } catch {
            metadataError = error.localizedDescription
            metadataMessage = nil
            return
        }
        metadataError = nil
        metadataMessage = nil
        metadataTask = Task { @MainActor in
            defer { metadataTask = nil }
            do {
                let metadata: PaperMetadata
                switch source {
                case .doi(let reference):
                    metadata = try await DOIImportService.shared.metadata(for: reference)
                case .arxiv(let reference):
                    metadata = try await ArxivImportService.shared.metadata(for: reference)
                }
                try Task.checkCancellation()
                apply(metadata)
                metadataMessage = "Metadata retrieved. Review the updated fields, then choose Save."
            } catch {
                if !Task.isCancelled, !(error is CancellationError) {
                    metadataError = error.localizedDescription
                }
            }
        }
    }

    private func apply(_ metadata: PaperMetadata) {
        if let title = nonempty(metadata.title) { paper.title = title }
        if let authors = nonempty(metadata.authors) { paper.authors = authors }
        if let year = nonempty(metadata.year) { paper.year = year }
        if let venue = nonempty(metadata.venue) { paper.venue = venue }
        if let doi = nonempty(metadata.doi) {
            paper.doi = doi
            metadataInput = doi
        }
    }

    private func nonempty(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func finishEditingIfSuccessful() {
        if let error = store.errorMessage {
            store.errorMessage = nil
            saveError = error
        } else {
            dismiss()
        }
    }
}

private enum MetadataSource: Sendable {
    case doi(DOIReference)
    case arxiv(ArxivReference)

    init(_ input: String) throws {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reference = try? DOIReference(input) {
            self = .doi(reference)
            return
        }
        if let reference = try? ArxivReference(input) {
            self = .arxiv(reference)
            return
        }
        if let components = URLComponents(string: input),
           ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
           components.user == nil, components.password == nil {
            let decoded = input.removingPercentEncoding ?? input
            if let range = decoded.range(of: #"10\.[0-9]{4,9}/[^?#&\s]+"#,
                                         options: [.regularExpression, .caseInsensitive]) {
                var candidate = String(decoded[range])
                while let last = candidate.last, ".,;:".contains(last) { candidate.removeLast() }
                if let reference = try? DOIReference(candidate) {
                    self = .doi(reference)
                    return
                }
            }
        }
        throw MetadataSourceError.invalidReference
    }
}

private enum MetadataSourceError: LocalizedError {
    case invalidReference

    var errorDescription: String? {
        "Enter a DOI, a doi.org link, an arXiv link, or a publisher URL that contains a DOI."
    }
}
