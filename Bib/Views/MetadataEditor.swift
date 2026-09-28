import SwiftUI

struct MetadataEditor: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State var paper: Paper
    @State private var confirmingDelete = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Paper") {
                    TextField("Title", text: $paper.title, axis: .vertical)
                        .lineLimit(2...5)
                    TextField("Authors", text: $paper.authors)
                    TextField("Year", text: $paper.year)
                    TextField("Journal / venue", text: $paper.venue)
                    TextField("DOI", text: $paper.doi)
                        .autocorrectionDisabled()
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
                    Text("Bib keeps its own copy of your PDF. Your original file stays where it is.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Paper details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.updatePaper(paper)
                        finishEditingIfSuccessful()
                    }
                    .disabled(paper.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                Text("This removes the paper and Bib’s stored PDF copy. Your original file is unchanged.")
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
        #if os(macOS)
        .frame(width: 480, height: 540)
        #endif
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
