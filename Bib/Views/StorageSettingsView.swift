import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct StorageSettingsView: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFolder = false
    @State private var changingFolder = false
    @State private var errorMessage: String?

    private var isBusy: Bool { changingFolder || store.isMovingStorage }
    private var pdfCount: Int { store.papers.filter(\.hasPDF).count }
    private var metadataOnlyCount: Int { store.papers.count - pdfCount }
    private var isDefaultFolder: Bool {
        store.storageFolderURL.standardizedFileURL == store.defaultStorageFolderURL.standardizedFileURL
    }

    private var displayPath: String {
        #if os(iOS)
        if isDefaultFolder {
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
            return "Files → On My \(device) → Bib → Bib"
        }
        #endif
        return store.storageFolderURL.path
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("PDF folder") {
                    Text(displayPath)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(pdfCount) \(pdfCount == 1 ? "paper has" : "papers have") a PDF in this library.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if metadataOnlyCount > 0 {
                        Text("\(metadataOnlyCount) \(metadataOnlyCount == 1 ? "paper has" : "papers have") details only and no PDF to store.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Choose folder…", systemImage: "folder") {
                        errorMessage = nil
                        choosingFolder = true
                    }
                    #if os(macOS)
                    Button("Show in Finder", systemImage: "arrow.up.forward.square") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.storageFolderURL])
                    }
                    #endif
                    if !isDefaultFolder {
                        Button("Use Documents/Bib") { changeFolder(to: store.defaultStorageFolderURL) }
                    }
                } footer: {
                    Text("Bib reads PDFs and saves highlights in this folder. Choosing another folder copies and verifies all attached PDFs before switching. Previous copies stay in their original location; new imports go to the chosen folder.")
                }
                .disabled(isBusy)

                if isBusy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Copying and checking your papers…")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let message = store.storageMessage {
                    Label {
                        Text(message).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.callout)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Paper storage")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(isBusy)
                }
            }
        }
        .interactiveDismissDisabled(isBusy)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { changeFolder(to: url) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    errorMessage = error.localizedDescription
                }
            }
        }
        #if os(macOS)
        .frame(width: 540, height: 480)
        #else
        .presentationDetents([.large])
        #endif
    }

    private func changeFolder(to url: URL) {
        guard !isBusy else { return }
        errorMessage = nil
        changingFolder = true
        Task { @MainActor in
            defer { changingFolder = false }
            let changed = await store.changeStorageFolder(to: url)
            if !changed {
                errorMessage = store.errorMessage ?? "The paper folder could not be changed. Please try again."
                store.errorMessage = nil
            }
        }
    }
}
