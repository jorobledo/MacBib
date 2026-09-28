import SwiftUI
import PDFKit

struct PaperDetailView: View {
    @ObservedObject var store: LibraryStore
    let paper: Paper
    @State private var editingMetadata = false
    @StateObject private var reader = PDFReaderController()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(paper.title)
                    .font(.system(.title3, design: .serif, weight: .medium))
                    .lineLimit(2)
                    .textSelection(.enabled)
                let subtitle = [paper.authors, paper.year, paper.venue].filter { !$0.isEmpty }.joined(separator: " · ")
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(BibTheme.canvas)
            Divider()

            if FileManager.default.fileExists(atPath: store.fileURL(for: paper).path) {
                PDFReader(url: store.fileURL(for: paper), controller: reader)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                QuietPlaceholder(symbol: "doc.questionmark", title: "PDF not found", message: "The stored copy is missing. Import the original PDF again to continue reading.") {
                    Button("Paper details") { editingMetadata = true }
                }
            }

            Divider()
            HStack(spacing: 16) {
                Text(reader.pageCount > 0 ? "Page \(reader.currentPage) of \(reader.pageCount)" : "PDF")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button(action: reader.zoomOut) { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out")
                    .accessibilityLabel("Zoom out")
                Button("Fit", action: reader.zoomToFit)
                    .font(.caption)
                    .help("Fit page to window")
                Button(action: reader.zoomIn) { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in")
                    .accessibilityLabel("Zoom in")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(BibTheme.canvas)
        }
        .background(BibTheme.readerBackground)
        .navigationTitle("Reader")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { editingMetadata = true }) {
                    Label("Paper details", systemImage: "info.circle")
                }
                .help("Edit paper details and folder")
            }
        }
        .sheet(isPresented: $editingMetadata) {
            MetadataEditor(store: store, paper: paper)
        }
    }
}
