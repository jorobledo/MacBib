import SwiftUI

struct DOIImportView: View {
    @ObservedObject var store: LibraryStore
    let onImported: (UUID, UUID?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var selectedFolderID: UUID?
    @State private var errorMessage: String?
    @State private var downloadNotice: String?
    @State private var imported = false
    @State private var importTask: Task<Void, Never>?
    @FocusState private var linkIsFocused: Bool

    init(store: LibraryStore, initialFolderID: UUID?, onImported: @escaping (UUID, UUID?) -> Void) {
        self.store = store
        self.onImported = onImported
        _selectedFolderID = State(initialValue: initialFolderID)
    }

    private var isImporting: Bool { importTask != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("DOI or DOI link", text: $link, prompt: Text("10.1371/journal.pone.0000308"))
                        .autocorrectionDisabled()
                        .focused($linkIsFocused)
                        .onSubmit(startImport)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                } footer: {
                    Text("Bib will retrieve the paper details and try to download its PDF. If the PDF is unavailable, the details and DOI link will still be saved.")
                }

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
                } footer: {
                    Text("Papers added to a folder also appear in All papers. If a publisher requires sign-in, you can sign in from the saved paper.")
                }

                if isImporting {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Retrieving paper details and looking for a PDF…")
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
            .disabled(isImporting || imported)
            .formStyle(.grouped)
            .navigationTitle("Import by DOI")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(imported ? "Done" : "Cancel") {
                        importTask?.cancel()
                        importTask = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: startImport)
                        .disabled(isImporting || imported || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("PDF not downloaded", isPresented: Binding(
                get: { downloadNotice != nil },
                set: { if !$0 { downloadNotice = nil } }
            )) {
                Button("View paper") { dismiss() }
            } message: {
                Text("The paper details and DOI link were saved to your library.\n\n" + (downloadNotice ?? ""))
            }
        }
        .interactiveDismissDisabled(isImporting || imported)
        .onAppear { linkIsFocused = true }
        .onDisappear { importTask?.cancel() }
        .onChange(of: link) { _, _ in errorMessage = nil }
        #if os(macOS)
        .frame(width: 520, height: 410)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    private func startImport() {
        guard !isImporting, !imported else { return }
        let reference: DOIReference
        do {
            reference = try DOIReference(link)
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
            defer { importTask = nil }
            do {
                let result = try await DOIImportService.shared.importPaper(reference)
                defer { result.removeTemporaryFiles() }
                try Task.checkCancellation()
                let id: UUID?
                if let url = result.fileURL {
                    id = store.importDownloadedPDF(from: url, metadata: result.metadata, into: folderID)
                } else {
                    id = store.importMetadata(result.metadata, into: folderID)
                }
                guard let id else {
                    errorMessage = store.errorMessage ?? "The paper could not be saved. Please try again."
                    store.errorMessage = nil
                    return
                }
                imported = true
                onImported(id, folderID)
                if result.fileURL == nil {
                    downloadNotice = result.notice ?? "No downloadable PDF was found. You can open the publisher to sign in or attach a PDF later."
                } else {
                    dismiss()
                }
            } catch {
                if !Task.isCancelled, !(error is CancellationError) {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
