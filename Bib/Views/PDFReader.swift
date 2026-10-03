import SwiftUI
import PDFKit

@MainActor
final class PDFReaderController: ObservableObject {
    @Published var currentPage = 1
    @Published var pageCount = 0
    @Published var searchText = ""
    @Published private(set) var searchResultCount = 0
    @Published private(set) var currentSearchResult = 0
    @Published private(set) var canHighlight = false
    @Published private(set) var canRemoveHighlights = false
    @Published private(set) var allowsHighlighting = false
    @Published var errorMessage: String?
    weak var view: PDFView?
    private var highlightEditor: PDFHighlightEditor?
    private var selection: PDFSelection?
    private let readingPositionKey: String
    private let defaults: UserDefaults
    private var isTrackingReadingPosition = false
    private var lastSavedPageIndex: Int?
    private var searchResults: [PDFSelection] = []

    init(paperID: UUID, defaults: UserDefaults = .standard) {
        readingPositionKey = "reader.lastPage.\(paperID.uuidString)"
        self.defaults = defaults
    }

    func zoomIn() { view?.zoomIn(nil) }
    func zoomOut() { view?.zoomOut(nil) }
    func zoomToFit() { view?.autoScales = true }

    func search() {
        guard let view, let document = view.document else {
            clearSearchResults()
            return
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clearSearchResults()
            return
        }

        view.clearSelection()
        searchResults = document.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
        searchResultCount = searchResults.count
        currentSearchResult = searchResults.isEmpty ? 0 : 1
        view.highlightedSelections = searchResults
        showCurrentSearchResult()
    }

    func findNext() {
        guard !searchResults.isEmpty else { return }
        currentSearchResult = currentSearchResult % searchResults.count + 1
        showCurrentSearchResult()
    }

    func findPrevious() {
        guard !searchResults.isEmpty else { return }
        currentSearchResult = (currentSearchResult + searchResults.count - 2) % searchResults.count + 1
        showCurrentSearchResult()
    }

    func endSearch() {
        searchText = ""
        clearSearchResults()
        view?.clearSelection()
        updateSelection()
    }

    private func showCurrentSearchResult() {
        guard currentSearchResult > 0, currentSearchResult <= searchResults.count, let view else { return }
        let selection = searchResults[currentSearchResult - 1]
        view.setCurrentSelection(selection, animate: true)
        view.go(to: selection)
    }

    private func clearSearchResults() {
        searchResults = []
        searchResultCount = 0
        currentSearchResult = 0
        view?.highlightedSelections = nil
        view?.clearSelection()
    }

    func openDocument(_ document: PDFDocument?, at url: URL) {
        clearSearchResults()
        selection = nil
        errorMessage = nil
        highlightEditor = document.map { PDFHighlightEditor(document: $0, url: url) }
        allowsHighlighting = document.map { !$0.isLocked && !$0.isEncrypted && $0.allowsCommenting } ?? false
        restoreReadingPosition(in: document)
        isTrackingReadingPosition = document != nil
        updatePage()
        updateSelection()
    }

    func prepareToOpenDocument() {
        isTrackingReadingPosition = false
        lastSavedPageIndex = nil
    }

    func updateSelection() {
        selection = view?.currentSelection?.copy() as? PDFSelection
        let hasText = !(selection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        canHighlight = allowsHighlighting && hasText
        canRemoveHighlights = canHighlight && selection.map { highlightEditor?.hasHighlights(in: $0) ?? false } == true
    }

    func highlightSelection(_ color: PDFHighlightColor) {
        guard canHighlight, let selection, let highlightEditor else { return }
        do {
            try highlightEditor.add(selection: selection, color: color)
            finishAnnotationChange(selection)
        } catch {
            refreshPages(in: selection)
            errorMessage = error.localizedDescription
        }
    }

    func removeHighlightsFromSelection() {
        guard canRemoveHighlights, let selection, let highlightEditor else { return }
        do {
            try highlightEditor.remove(selection: selection)
            finishAnnotationChange(selection)
        } catch {
            refreshPages(in: selection)
            errorMessage = error.localizedDescription
        }
    }

    private func finishAnnotationChange(_ selection: PDFSelection) {
        errorMessage = nil
        refreshPages(in: selection)
        view?.clearSelection()
        updateSelection()
    }

    private func refreshPages(in selection: PDFSelection) {
        for page in selection.pages { view?.annotationsChanged(on: page) }
    }

    func updatePage() {
        guard let document = view?.document else {
            currentPage = 1
            pageCount = 0
            return
        }
        pageCount = document.pageCount
        if let page = view?.currentPage {
            let pageIndex = document.index(for: page)
            currentPage = pageIndex + 1
            saveReadingPosition(pageIndex)
        }
    }

    private func restoreReadingPosition(in document: PDFDocument?) {
        guard let document, document.pageCount > 0,
              defaults.object(forKey: readingPositionKey) != nil else { return }
        let savedPageIndex = defaults.integer(forKey: readingPositionKey)
        let pageIndex = min(max(savedPageIndex, 0), document.pageCount - 1)
        if let page = document.page(at: pageIndex) {
            view?.go(to: page)
            lastSavedPageIndex = pageIndex
        }
    }

    private func saveReadingPosition(_ pageIndex: Int) {
        guard isTrackingReadingPosition, pageIndex >= 0, pageIndex != lastSavedPageIndex else { return }
        defaults.set(pageIndex, forKey: readingPositionKey)
        lastSavedPageIndex = pageIndex
    }
}

struct PDFReader {
    let url: URL
    @ObservedObject var controller: PDFReaderController

    @MainActor
    final class Coordinator: NSObject {
        var loadedURL: URL?
        let controller: PDFReaderController

        init(controller: PDFReaderController) { self.controller = controller }

        @objc func pageChanged(_ notification: Notification) {
            Task { @MainActor [weak self] in self?.controller.updatePage() }
        }

        @objc func selectionChanged(_ notification: Notification) {
            Task { @MainActor [weak self] in self?.controller.updateSelection() }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    @MainActor
    private func makePDFView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        #if os(macOS)
        view.backgroundColor = .underPageBackgroundColor
        #else
        view.backgroundColor = .secondarySystemBackground
        #endif
        controller.view = view
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged(_:)), name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.selectionChanged(_:)), name: .PDFViewSelectionChanged, object: view)
        updatePDFView(view, context: context)
        return view
    }

    @MainActor
    private func updatePDFView(_ view: PDFView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        controller.prepareToOpenDocument()
        let document = PDFDocument(url: url)
        view.document = document
        view.autoScales = true
        Task { @MainActor in
            guard view.document === document else { return }
            controller.openDocument(document, at: url)
        }
    }
}

#if os(macOS)
extension PDFReader: NSViewRepresentable {
    func makeNSView(context: Context) -> PDFView { makePDFView(context: context) }
    func updateNSView(_ view: PDFView, context: Context) { updatePDFView(view, context: context) }
}
#else
extension PDFReader: UIViewRepresentable {
    func makeUIView(context: Context) -> PDFView { makePDFView(context: context) }
    func updateUIView(_ view: PDFView, context: Context) { updatePDFView(view, context: context) }
}
#endif
