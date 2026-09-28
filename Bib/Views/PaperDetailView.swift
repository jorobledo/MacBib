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
            highlightToolbar
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
        .alert("Couldn’t save highlights", isPresented: Binding(
            get: { reader.errorMessage != nil },
            set: { if !$0 { reader.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { reader.errorMessage = nil }
        } message: {
            Text(reader.errorMessage ?? "Please try again.")
        }
    }

    private var highlightToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Label(reader.canHighlight ? "Highlight" : "Select text", systemImage: "highlighter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Spacer(minLength: 8)
                highlightActions
            }
            highlightActions
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .background(BibTheme.canvas)
        .help(reader.allowsHighlighting
              ? "Select text in the PDF, then choose a highlight color. Select highlighted text and use the eraser to remove it."
              : "Highlighting is unavailable for encrypted or protected PDFs.")
    }

    private var highlightActions: some View {
        HStack(spacing: 2) {
            ForEach(PDFHighlightColor.allCases) { color in
                Button {
                    reader.highlightSelection(color)
                } label: {
                    Circle()
                        .fill(highlightSwatch(color))
                        .frame(width: 19, height: 19)
                        .overlay { Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1) }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!reader.canHighlight)
                .accessibilityLabel("Highlight selected text in \(color.rawValue)")
                .help("Highlight selected text in \(color.rawValue)")
            }
            Divider().frame(height: 20).padding(.horizontal, 6)
            Button(action: reader.removeHighlightsFromSelection) {
                Image(systemName: "eraser")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!reader.canRemoveHighlights)
            .accessibilityLabel("Remove highlights from selected text")
            .help("Remove Bib highlights from the selected text")
        }
        .buttonStyle(.borderless)
    }

    private func highlightSwatch(_ color: PDFHighlightColor) -> Color {
        #if os(macOS)
        Color(nsColor: color.color.withAlphaComponent(1))
        #else
        Color(uiColor: color.color.withAlphaComponent(1))
        #endif
    }
}
