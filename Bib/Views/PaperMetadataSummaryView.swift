import SwiftUI

struct PaperMetadataSummaryView: View {
    @ObservedObject var store: LibraryStore
    let paper: Paper
    @Environment(\.dismiss) private var dismiss
    @State private var editingMetadata = false

    private var currentPaper: Paper {
        store.papers.first(where: { $0.id == paper.id }) ?? paper
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Bibliographic metadata") {
                    metadataRow("Title", value: currentPaper.title)
                    metadataRow("Authors", value: currentPaper.authors)
                    metadataRow("Year", value: currentPaper.year)
                    metadataRow("Journal / venue", value: currentPaper.venue)
                }

                Section("Identifiers and access") {
                    metadataRow("DOI", value: currentPaper.doi)
                    if let url = currentPaper.doiURL {
                        Link(destination: url) {
                            Label("Open paper online", systemImage: "safari")
                        }
                    } else {
                        Text("No online link is available because this paper has no valid DOI.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Library") {
                    LabeledContent("PDF", value: currentPaper.hasPDF ? "In library" : "Not downloaded")
                    LabeledContent("Added", value: currentPaper.addedAt.formatted(date: .abbreviated, time: .omitted))
                }

                Section {
                    Button("Edit or fetch metadata…", systemImage: "arrow.down.doc") {
                        editingMetadata = true
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Paper metadata")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $editingMetadata) {
                MetadataEditor(store: store, paper: currentPaper)
            }
        }
        #if os(macOS)
        .frame(width: 520, height: 520)
        #endif
    }

    @ViewBuilder
    private func metadataRow(_ label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(value.isEmpty ? "Not available" : value)
                .foregroundStyle(value.isEmpty ? .secondary : .primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
