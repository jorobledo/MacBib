import SwiftUI

struct ArxivImportView: View {
    @ObservedObject var store: LibraryStore
    let onImported: (UUID, UUID?, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var selectedFolderID: UUID?
    @State private var errorMessage: String?
    @State private var importTask: Task<Void, Never>?
    @FocusState private var linkIsFocused: Bool

    init(store: LibraryStore, initialFolderID: UUID?, onImported: @escaping (UUID, UUID?, String?) -> Void) {
        self.store = store
        self.onImported = onImported
        _selectedFolderID = State(initialValue: initialFolderID)
    }

    private var isImporting: Bool { importTask != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("arXiv link or ID", text: $link, prompt: Text("https://arxiv.org/abs/1706.03762"))
                        .autocorrectionDisabled()
                        .focused($linkIsFocused)
                        .onSubmit(startImport)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                } footer: {
                    Text("Paste an arXiv paper link. Bib will download the PDF and fill in the available paper details.")
                }
                .disabled(isImporting)

                Section {
                    Picker("Add to", selection: $selectedFolderID) {
                        Text("All papers (no folder)").tag(nil as UUID?)
                        ForEach(store.folders) { folder in
                            Text(folder.name).tag(Optional(folder.id))
                        }
                        if let id = selectedFolderID, !store.folders.contains(where: { $0.id == id }) {
                            Text("Folder no longer exists").tag(Optional(id))
                        }
                    }
                    .disabled(isImporting)
                } footer: {
                    Text("Papers added to a folder also appear in All papers.")
                }

                if isImporting {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Downloading from arXiv…")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Import from arXiv")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        importTask?.cancel()
                        importTask = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: startImport)
                        .disabled(isImporting || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(isImporting)
        .onAppear { linkIsFocused = true }
        .onDisappear { importTask?.cancel() }
        .onChange(of: link) { _, _ in errorMessage = nil }
        #if os(macOS)
        .frame(width: 500, height: 380)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    private func startImport() {
        guard !isImporting else { return }
        let reference: ArxivReference
        do {
            reference = try ArxivReference(link)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let folderID = selectedFolderID
        guard folderID == nil || store.folders.contains(where: { $0.id == folderID }) else {
            errorMessage = "This folder no longer exists. Choose All papers or another folder."
            return
        }
        errorMessage = nil
        linkIsFocused = false
        importTask = Task { @MainActor in
            do {
                let download = try await ArxivImportService.shared.download(reference)
                defer { download.removeTemporaryFiles() }
                try Task.checkCancellation()
                guard let id = store.importDownloadedPDF(from: download.fileURL, metadata: download.metadata, into: folderID) else {
                    errorMessage = store.errorMessage ?? "The paper could not be added to your library."
                    store.errorMessage = nil
                    importTask = nil
                    return
                }
                importTask = nil
                onImported(id, folderID, download.metadataWarning)
                dismiss()
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
                importTask = nil
            }
        }
    }
}
