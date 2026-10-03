import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct PaperDetailView: View {
    @ObservedObject var store: LibraryStore
    let paper: Paper
    let sidebarsHidden: Bool
    let toggleSidebars: (() -> Void)?
    @State private var editingMetadata = false
    @State private var showingPublisher = false
    @State private var attachingPDF = false
    @State private var downloadTask: Task<Void, Never>?
    @State private var downloadMessage: String?
    @State private var showingPDFSearch = false
    @FocusState private var pdfSearchIsFocused: Bool
    @StateObject private var reader: PDFReaderController

    init(store: LibraryStore, paper: Paper, sidebarsHidden: Bool = false, toggleSidebars: (() -> Void)? = nil) {
        self.store = store
        self.paper = paper
        self.sidebarsHidden = sidebarsHidden
        self.toggleSidebars = toggleSidebars
        _reader = StateObject(wrappedValue: PDFReaderController(paperID: paper.id))
    }

    private var existingPDFURL: URL? {
        guard let url = store.fileURL(for: paper), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

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
                if let url = paper.doiURL {
                    Link("DOI: \(paper.doi)", destination: url)
                        .font(.caption)
                        .lineLimit(1)
                        .help("Open the DOI in your browser")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(BibTheme.canvas)
            Divider()

            if let url = existingPDFURL {
                if showingPDFSearch {
                    pdfSearchBar
                    Divider()
                }
                PDFReader(url: url, controller: reader)
                    .id(url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { missingPDF }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if existingPDFURL != nil {
                Divider()
                highlightToolbar
                Divider()
                HStack(spacing: 16) {
                    Text(reader.pageCount > 0 ? "Page \(reader.currentPage) of \(reader.pageCount)" : "PDF")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    #if os(macOS)
                    if let toggleSidebars {
                        Button(action: toggleSidebars) {
                            Image(systemName: sidebarsHidden ? "rectangle.split.3x1" : "rectangle")
                        }
                        .help(sidebarsHidden ? "Show library sidebars" : "Hide library sidebars")
                        .accessibilityLabel(sidebarsHidden ? "Show library sidebars" : "Hide library sidebars")
                    }
                    #endif
                    Button(action: showPDFSearch) {
                        Image(systemName: "magnifyingglass")
                    }
                    .help("Find in PDF (Command-F)")
                    .accessibilityLabel("Find in PDF")
                    .keyboardShortcut("f", modifiers: .command)
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
        }
        .background(BibTheme.readerBackground)
        .navigationTitle(paper.title)
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
        .sheet(isPresented: $showingPublisher) {
            PublisherAccessView(store: store, paper: paper)
        }
        .fileImporter(isPresented: $attachingPDF, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first, !store.attachPDF(from: url, to: paper.id) {
                    takeStoreError()
                }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { downloadMessage = error.localizedDescription }
            }
        }
        .alert("PDF download", isPresented: Binding(
            get: { downloadMessage != nil },
            set: { if !$0 { downloadMessage = nil } }
        )) {
            Button("OK", role: .cancel) { downloadMessage = nil }
        } message: {
            Text(downloadMessage ?? "Please try again.")
        }
        .alert("Couldn’t save highlights", isPresented: Binding(
            get: { reader.errorMessage != nil },
            set: { if !$0 { reader.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { reader.errorMessage = nil }
        } message: {
            Text(reader.errorMessage ?? "Please try again.")
        }
        .onDisappear { downloadTask?.cancel() }
    }

    private var pdfSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in PDF", text: $reader.searchText)
                .textFieldStyle(.roundedBorder)
                .focused($pdfSearchIsFocused)
                .onChange(of: reader.searchText) { _, _ in reader.search() }
                .onSubmit {
                    if reader.searchResultCount > 0 { reader.findNext() }
                }
            Text(searchResultDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 72, alignment: .trailing)
            Button(action: reader.findPrevious) { Image(systemName: "chevron.up") }
                .disabled(reader.searchResultCount == 0)
                .help("Previous match (Shift-Command-G)")
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button(action: reader.findNext) { Image(systemName: "chevron.down") }
                .disabled(reader.searchResultCount == 0)
                .help("Next match (Command-G)")
                .keyboardShortcut("g", modifiers: .command)
            Button(action: hidePDFSearch) { Image(systemName: "xmark") }
                .help("Close find")
                .accessibilityLabel("Close find")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(BibTheme.canvas)
        #if os(macOS)
        .onExitCommand(perform: hidePDFSearch)
        #endif
    }

    private var searchResultDescription: String {
        guard !reader.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard reader.searchResultCount > 0 else { return "No matches" }
        return "\(reader.currentSearchResult) of \(reader.searchResultCount)"
    }

    private func showPDFSearch() {
        showingPDFSearch = true
        DispatchQueue.main.async { pdfSearchIsFocused = true }
    }

    private func hidePDFSearch() {
        showingPDFSearch = false
        pdfSearchIsFocused = false
        reader.endSearch()
    }

    private var missingPDF: some View {
        QuietPlaceholder(
            symbol: paper.hasPDF ? "doc.questionmark" : "doc.text",
            title: paper.hasPDF ? "PDF not found" : "Paper details saved",
            message: paper.hasPDF
                ? "The stored copy is missing. Import the original PDF again to continue reading."
                : "This paper is in your library without a PDF. Open the publisher to use your subscription or institutional access, or attach a PDF you already have."
        ) {
            VStack(spacing: 12) {
                if !paper.hasPDF {
                    if paper.doiURL != nil {
                        Button("Open publisher & sign in", systemImage: "globe") { showingPublisher = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(downloadTask != nil)
                        if downloadTask != nil {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Looking for a PDF…").font(.caption)
                                Button("Cancel") { downloadTask?.cancel() }
                            }
                        } else {
                            Button("Try PDF download again", action: retryDownload)
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("Attach PDF…", systemImage: "paperclip") { attachingPDF = true }
                        .disabled(downloadTask != nil)
                }
                Button("Paper details") { editingMetadata = true }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func retryDownload() {
        guard downloadTask == nil, !paper.hasPDF else { return }
        let reference: DOIReference
        do { reference = try DOIReference(paper.doi) }
        catch { downloadMessage = error.localizedDescription; return }
        downloadTask = Task { @MainActor in
            defer { downloadTask = nil }
            do {
                let result = try await DOIImportService.shared.importPaper(reference)
                defer { result.removeTemporaryFiles() }
                try Task.checkCancellation()
                if let url = result.fileURL {
                    guard let current = store.papers.first(where: { $0.id == paper.id }),
                          let currentReference = try? DOIReference(current.doi),
                          currentReference.id.caseInsensitiveCompare(reference.id) == .orderedSame else {
                        downloadMessage = "This paper was removed or its DOI changed while downloading. The PDF was not attached. Try again with the current DOI."
                        return
                    }
                    if !store.attachPDF(from: url, to: paper.id) { takeStoreError() }
                } else {
                    downloadMessage = (result.notice ?? "No downloadable PDF was found.")
                        + "\n\nYour saved paper details and DOI link are unchanged."
                }
            } catch {
                if !Task.isCancelled, !(error is CancellationError) {
                    downloadMessage = error.localizedDescription
                }
            }
        }
    }

    private func takeStoreError() {
        downloadMessage = store.errorMessage ?? "The PDF could not be attached. Please try again."
        store.errorMessage = nil
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
