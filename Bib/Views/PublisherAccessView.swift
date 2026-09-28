import SwiftUI
import WebKit

/// Publisher sign-in lives in Bib's own persistent WebKit session.
struct PublisherAccessView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser: PublisherBrowserController

    init(store: LibraryStore, paper: Paper) {
        _browser = StateObject(wrappedValue: PublisherBrowserController(store: store, paper: paper))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sign in with your publisher or institution, then open the paper’s PDF to add it to Bib.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        Button(action: browser.goBack) {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(!browser.canGoBack || browser.isDownloading)
                        .accessibilityLabel("Go back")
                        Button(action: browser.reload) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(browser.isDownloading)
                        .accessibilityLabel("Reload publisher page")
                        Label(browser.currentURL?.host ?? "Publisher", systemImage: "lock")
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if browser.isLoading || browser.isDownloading {
                            ProgressView().controlSize(.small)
                        }
                        if let url = browser.currentURL {
                            Link(destination: url) {
                                Image(systemName: "arrow.up.right.square")
                            }
                            .accessibilityLabel("Open in your browser")
                            .help("Open in your browser")
                        }
                    }
                    .buttonStyle(.borderless)
                    if browser.isDownloading {
                        HStack {
                            Text("Downloading PDF…").font(.callout)
                            Spacer()
                            Button("Cancel download", action: browser.cancelDownload)
                                .font(.callout)
                        }
                    }
                    if let errorMessage = browser.errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding()
                Divider()
                PublisherWebView(webView: browser.webView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Publisher access")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
        .onChange(of: browser.didImportPDF) { _, imported in
            if imported { dismiss() }
        }
        #if os(macOS)
        .frame(minWidth: 720, idealWidth: 940, minHeight: 560, idealHeight: 720)
        #else
        .presentationDetents([.large])
        #endif
    }
}

@MainActor
private final class PublisherBrowserController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    @Published private(set) var currentURL: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var isLoading = false
    @Published private(set) var isDownloading = false
    @Published private(set) var didImportPDF = false
    @Published private(set) var errorMessage: String?

    let webView: WKWebView
    private let store: LibraryStore
    private let paperID: UUID
    private let initialURL: URL?
    private var isActive = false
    private var hasStarted = false
    private var observations: [NSKeyValueObservation] = []
    private var activeDownload: WKDownload?
    private var downloadDirectory: URL?
    private var downloadURL: URL?

    init(store: LibraryStore, paper: Paper) {
        self.store = store
        paperID = paper.id
        initialURL = paper.doiURL
        currentURL = paper.doiURL
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.url) { [weak self] _, _ in
                Task { @MainActor in self?.updateNavigationState() }
            },
            webView.observe(\.canGoBack) { [weak self] _, _ in
                Task { @MainActor in self?.updateNavigationState() }
            },
            webView.observe(\.isLoading) { [weak self] _, _ in
                Task { @MainActor in self?.updateNavigationState() }
            }
        ]
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        isActive = true
        guard let initialURL, Self.permits(initialURL) else {
            errorMessage = "Add a valid DOI in Paper details to open the publisher."
            return
        }
        webView.load(URLRequest(url: initialURL))
    }

    func stop() {
        isActive = false
        webView.stopLoading()
        cancelDownload()
    }

    func goBack() { webView.goBack() }
    func reload() { webView.reload() }

    func cancelDownload() {
        let download = activeDownload
        let directory = downloadDirectory
        activeDownload = nil
        downloadDirectory = nil
        downloadURL = nil
        isDownloading = false
        download?.delegate = nil
        // Wait until WebKit has stopped writing before deleting the temporary directory.
        if let download {
            download.cancel { _ in
                if let directory { try? FileManager.default.removeItem(at: directory) }
            }
        } else if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func updateNavigationState() {
        guard isActive else { return }
        if let url = webView.url, Self.permits(url) { currentURL = url }
        canGoBack = webView.canGoBack
        isLoading = webView.isLoading
    }

    /// Navigation stays on public HTTPS sites, including publisher and institutional login hosts.
    private static func permits(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased(), host.contains("."),
              !host.hasSuffix("."),
              ![".local", ".localhost", ".internal", ".home", ".test", ".invalid"].contains(where: host.hasSuffix),
              host.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil,
              host.range(of: #"^[0-9.]+$"#, options: .regularExpression) == nil else {
            return false
        }
        return true
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard isActive, let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.absoluteString == "about:blank" {
            decisionHandler(.allow)
            return
        }
        guard Self.permits(url) else {
            errorMessage = "This link cannot be opened in Bib. Publisher access requires a public HTTPS website."
            decisionHandler(.cancel)
            return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
        } else if navigationAction.targetFrame == nil {
            // Keep user-initiated popups and target=_blank links in this visible browser.
            decisionHandler(.cancel)
            webView.load(navigationAction.request)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard isActive, let url = navigationResponse.response.url,
              Self.permits(url) || url.absoluteString == "about:blank" else {
            if isActive {
                errorMessage = "The publisher redirected to a link that Bib cannot open. A public HTTPS link is required."
            }
            decisionHandler(.cancel)
            return
        }
        let response = navigationResponse.response
        let mime = response.mimeType?.lowercased() ?? ""
        let isPDF = mime == "application/pdf" || mime == "application/x-pdf"
        let isPDFFile = (response.suggestedFilename as NSString?)?.pathExtension.lowercased() == "pdf"
            || url.pathExtension.lowercased() == "pdf"
        decisionHandler(isPDF || (mime == "application/octet-stream" && isPDFFile) ? .download : .allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if isActive, let url = navigationAction.request.url, Self.permits(url) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if isActive { errorMessage = nil }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportNavigationError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportNavigationError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if isActive { errorMessage = "The publisher page stopped responding. Reload the page to try again." }
    }

    private func reportNavigationError(_ error: Error) {
        guard isActive else { return }
        let failure = error as NSError
        // WebKit cancels navigation when it hands a PDF response to WKDownload.
        guard !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled),
              !(failure.domain == "WebKitErrorDomain" && failure.code == 102) else { return }
        errorMessage = "The publisher page could not be loaded. \(error.localizedDescription)"
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        receive(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        receive(download)
    }

    private func receive(_ download: WKDownload) {
        guard isActive, activeDownload == nil else {
            download.cancel(nil)
            return
        }
        activeDownload = download
        download.delegate = self
        isDownloading = true
        errorMessage = nil
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard isActive, activeDownload === download else {
            completionHandler(nil)
            return
        }
        guard let sourceURL = response.url, Self.permits(sourceURL) else {
            errorMessage = "The PDF download requires a public HTTPS link."
            completionHandler(nil)
            cancelDownload()
            return
        }
        if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            errorMessage = [401, 402, 403].contains(response.statusCode)
                ? "The publisher has not granted access to this PDF. Sign in with an account or institution that includes the paper, then try again."
                : "The publisher could not provide the PDF (HTTP \(response.statusCode))."
            completionHandler(nil)
            cancelDownload()
            return
        }
        let mime = response.mimeType?.lowercased() ?? ""
        let isPDFFile = (suggestedFilename as NSString).pathExtension.lowercased() == "pdf"
            || sourceURL.pathExtension.lowercased() == "pdf"
        guard mime == "application/pdf" || mime == "application/x-pdf"
                || ((mime.isEmpty || mime == "application/octet-stream") && isPDFFile) else {
            errorMessage = "The publisher returned a web page or another file instead of a PDF. Sign in, then use the paper’s PDF download link."
            completionHandler(nil)
            cancelDownload()
            return
        }
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Bib-publisher-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let destination = directory.appendingPathComponent("paper.pdf")
            downloadDirectory = directory
            downloadURL = destination
            completionHandler(destination)
        } catch {
            errorMessage = "The PDF could not be saved temporarily. \(error.localizedDescription)"
            completionHandler(nil)
            cancelDownload()
        }
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        guard isActive, activeDownload === download,
              let url = request.url, Self.permits(url) else {
            decisionHandler(.cancel)
            if isActive, activeDownload === download {
                errorMessage = "The publisher redirected the PDF to a link that Bib cannot open. A public HTTPS link is required."
                cancelDownload()
            }
            return
        }
        decisionHandler(.allow)
    }

    func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(isActive && activeDownload === download ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard isActive, activeDownload === download, let downloadURL else { return }
        if let currentPaper = store.papers.first(where: { $0.id == paperID }),
           currentPaper.doiURL?.absoluteString.lowercased() != initialURL?.absoluteString.lowercased() {
            errorMessage = "This paper’s DOI changed while the publisher was open. Close this window and open the publisher again."
            finishDownload()
            return
        }
        let attached = store.attachPDF(from: downloadURL, to: paperID)
        if !attached {
            errorMessage = store.errorMessage ?? "The downloaded file could not be added as a PDF."
            store.errorMessage = nil
        }
        finishDownload()
        if attached { didImportPDF = true }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard activeDownload === download else { return }
        if isActive { errorMessage = "The PDF download failed. \(error.localizedDescription)" }
        finishDownload()
    }

    private func finishDownload() {
        activeDownload?.delegate = nil
        activeDownload = nil
        if let downloadDirectory { try? FileManager.default.removeItem(at: downloadDirectory) }
        downloadDirectory = nil
        downloadURL = nil
        isDownloading = false
    }
}

#if os(macOS)
private struct PublisherWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
private struct PublisherWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
