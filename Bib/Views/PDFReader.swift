import SwiftUI
import PDFKit

@MainActor
final class PDFReaderController: ObservableObject {
    @Published var currentPage = 1
    @Published var pageCount = 0
    weak var view: PDFView?

    func zoomIn() { view?.zoomIn(nil) }
    func zoomOut() { view?.zoomOut(nil) }
    func zoomToFit() { view?.autoScales = true }

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
        updatePDFView(view, context: context)
        return view
    }

    @MainActor
    private func updatePDFView(_ view: PDFView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        view.document = PDFDocument(url: url)
        view.autoScales = true
        Task { @MainActor in controller.updatePage() }
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
