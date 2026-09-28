import SwiftUI
import PDFKit

@MainActor
final class PDFReaderController: ObservableObject {
    @Published var currentPage = 1
    @Published var pageCount = 0
    @Published private(set) var canHighlight = false
    @Published private(set) var canRemoveHighlights = false
    @Published private(set) var allowsHighlighting = false
    @Published var errorMessage: String?
    weak var view: PDFView?
    private var highlightEditor: PDFHighlightEditor?
    private var selection: PDFSelection?

    func zoomIn() { view?.zoomIn(nil) }
    func zoomOut() { view?.zoomOut(nil) }
    func zoomToFit() { view?.autoScales = true }

    func openDocument(_ document: PDFDocument?, at url: URL) {
        selection = nil
        errorMessage = nil
        highlightEditor = document.map { PDFHighlightEditor(document: $0, url: url) }
        allowsHighlighting = document.map { !$0.isLocked && !$0.isEncrypted && $0.allowsCommenting } ?? false
        updatePage()
        updateSelection()
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
        if let page = view?.currentPage { currentPage = document.index(for: page) + 1 }
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
