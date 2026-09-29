import SwiftUI

struct PaperMetadataSummaryView: View {
    let paper: Paper
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Bibliographic metadata") {
                    metadataRow("Title", value: paper.title)
                    metadataRow("Authors", value: paper.authors)
                    metadataRow("Year", value: paper.year)
                    metadataRow("Journal / venue", value: paper.venue)
                }

                Section("Identifiers and access") {
                    metadataRow("DOI", value: paper.doi)
                    if let url = paper.doiURL {
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
                    LabeledContent("PDF", value: paper.hasPDF ? "In library" : "Not downloaded")
                    LabeledContent("Added", value: paper.addedAt.formatted(date: .abbreviated, time: .omitted))
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
