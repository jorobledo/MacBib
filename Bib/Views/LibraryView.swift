import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

private enum LibraryScope: Hashable {
    case all, unfiled, folder(UUID)

    var folderID: UUID? {
        if case .folder(let id) = self { return id }
        return nil
    }
}

private enum PaperSort: String, CaseIterable {
    case newest = "Recently added"
    case title = "Title"
    case year = "Year"
}

struct LibraryView: View {
    @ObservedObject var store: LibraryStore
    @StateObject private var pdfMetadataLookup = PDFMetadataLookup()
    @State private var scope: LibraryScope? = .all
    @State private var selectedPaperID: UUID?
    @State private var search = ""
    @State private var sort: PaperSort = .newest
    @State private var importing = false
    @State private var importingArxiv = false
    @State private var importingDOI = false
    @State private var showingStorage = false
    @State private var importNotice: String?
    @State private var pendingImportedPaperID: UUID?
    @State private var editingFolder = false
    @State private var folderToRename: PaperFolder?
    @State private var folderName = ""
    @State private var folderError: String?
    @State private var folderToDelete: PaperFolder?
    @State private var metadataSummaryPaper: Paper?
    @State private var paperToDelete: Paper?
    @State private var preferredColumn = NavigationSplitViewColumn.content

    private var currentScope: LibraryScope { scope ?? .all }

    private var scopeTitle: String {
        switch currentScope {
        case .all: return "All papers"
        case .unfiled: return "Unfiled"
        case .folder(let id): return store.folders.first { $0.id == id }?.name ?? "Folder"
        }
    }

    private var scopedPapers: [Paper] {
        store.papers.filter { paper in
            switch currentScope {
            case .all: return true
            case .unfiled: return paper.folderID == nil
            case .folder(let id): return paper.folderID == id
            }
        }
    }

    private var visiblePapers: [Paper] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = scopedPapers.filter { paper in
            query.isEmpty || [paper.title, paper.authors, paper.year, paper.venue, paper.doi]
                .contains { $0.localizedStandardContains(query) }
        }
        return matching.sorted { lhs, rhs in
            switch sort {
            case .newest: return lhs.addedAt > rhs.addedAt
            case .title: return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            case .year:
                if lhs.year != rhs.year { return lhs.year.localizedStandardCompare(rhs.year) == .orderedDescending }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
        } content: {
            paperList
                .navigationSplitViewColumnWidth(min: 260, ideal: 330, max: 440)
        } detail: {
            if let paper = store.papers.first(where: { $0.id == selectedPaperID }) {
                PaperDetailView(store: store, paper: paper)
                    .id(paper.id)
            } else {
                QuietPlaceholder(
                    symbol: "book.closed",
                    title: "A little space to think.",
                    message: "Choose a paper from your library and settle into reading."
                ) {
                    if store.papers.isEmpty {
                        Button("Open the welcome paper", action: importWelcome)
                            .buttonStyle(.borderless)
                            .foregroundStyle(BibTheme.accent)
                    }
                }
                .background(BibTheme.canvas)
                .navigationTitle("Bib")
            }
        }
        .navigationSplitViewStyle(.balanced)
        .disabled(store.isMovingStorage)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                let imported = store.importPDFs(from: urls, into: currentScope.folderID)
                pdfMetadataLookup.enqueue(paperIDs: imported, in: store)
                if let first = imported.first {
                    search = ""
                    selectedPaperID = first
                    preferredColumn = .detail
                }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { store.errorMessage = error.localizedDescription }
            }
        }
        .sheet(isPresented: $editingFolder) { folderEditor }
        .sheet(isPresented: $importingArxiv) {
            ArxivImportView(store: store, initialFolderID: currentScope.folderID) { id, folderID, warning in
                showImportedPaper(id, in: folderID)
                importNotice = warning == nil ? nil : "The PDF was imported, but arXiv’s paper details weren’t available. You can edit them using Paper details."
            }
        }
        .sheet(isPresented: $importingDOI) {
            DOIImportView(store: store, initialFolderID: currentScope.folderID) { id, folderID in
                importNotice = nil
                showImportedPaper(id, in: folderID)
            }
        }
        .sheet(isPresented: $showingStorage) { StorageSettingsView(store: store) }
        .sheet(item: $metadataSummaryPaper) { paper in
            PaperMetadataSummaryView(paper: paper)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if pdfMetadataLookup.isSearching {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Looking up paper details online… \(pdfMetadataLookup.completedCount + 1) of \(pdfMetadataLookup.totalCount)")
                        .font(.caption)
                    Spacer(minLength: 0)
                    Button("Cancel search") { pdfMetadataLookup.cancel() }
                }
                .padding(12)
                .background(.regularMaterial)
            }
            if let notice = pdfMetadataLookup.notice {
                HStack(spacing: 12) {
                    Image(systemName: "info.circle")
                    Text(notice).font(.caption)
                    Spacer(minLength: 0)
                    Button { pdfMetadataLookup.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss metadata notice")
                }
                .padding(12)
                .background(.regularMaterial)
            }
            if let message = store.storageMessage {
                HStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark")
                    Text(message).font(.caption)
                    Spacer(minLength: 0)
                    Button("Paper storage…") { showingStorage = true }
                }
                .padding(12)
                .background(.regularMaterial)
            }
            if let importNotice {
                HStack(spacing: 12) {
                    Image(systemName: "info.circle")
                    Text(importNotice).font(.caption)
                    Spacer(minLength: 0)
                    Button { self.importNotice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss import notice")
                }
                .padding(12)
                .background(.regularMaterial)
            }
        }
        .alert("Couldn’t complete that", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "Please try again.")
        }
        .confirmationDialog("Delete folder?", isPresented: Binding(
            get: { folderToDelete != nil },
            set: { if !$0 { folderToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete folder", role: .destructive) {
                if let folder = folderToDelete {
                    store.deleteFolder(id: folder.id)
                    if !store.folders.contains(where: { $0.id == folder.id }) { scope = .all }
                }
                folderToDelete = nil
            }
        } message: {
            Text("The papers in this folder will stay in your library as unfiled papers.")
        }
        .confirmationDialog("Remove paper?", isPresented: Binding(
            get: { paperToDelete != nil },
            set: { if !$0 { paperToDelete = nil } }
        ), titleVisibility: .visible) {
            if let paper = paperToDelete {
                Button("Remove “\(paper.title)”", role: .destructive) {
                    store.deletePaper(id: paper.id)
                    if !store.papers.contains(where: { $0.id == paper.id }) {
                        selectedPaperID = nil
                    }
                    paperToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { paperToDelete = nil }
        } message: {
            if paperToDelete?.hasPDF == true {
                Text("This removes the paper from the library and every folder, and deletes Bib’s stored PDF copy. Your original PDF is unchanged.")
            } else {
                Text("This removes the paper and its metadata from the library and every folder.")
            }
        }
        .onChange(of: scope) { _, _ in
            selectedPaperID = pendingImportedPaperID
            pendingImportedPaperID = nil
            search = ""
            if selectedPaperID != nil { preferredColumn = .detail }
        }
        .onChange(of: store.papers) { _, _ in
            if let id = selectedPaperID, !scopedPapers.contains(where: { $0.id == id }) { selectedPaperID = nil }
        }
        .onDisappear { pdfMetadataLookup.cancel(showNotice: false) }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                sidebarLogo
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                Text("bib")
                    .font(.system(size: 32, weight: .semibold, design: .serif))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 24)

            List(selection: $scope) {
                Section("Library") {
                    NavigationLink(value: LibraryScope.all) {
                        sidebarRow("All papers", symbol: "tray.full", count: store.papers.count)
                    }
                    NavigationLink(value: LibraryScope.unfiled) {
                        sidebarRow("Unfiled", symbol: "doc", count: store.papers.filter { $0.folderID == nil }.count)
                    }
                    .modifier(PaperDropTarget(store: store, folderID: nil))
                }
                Section {
                    ForEach(store.folders) { folder in
                        NavigationLink(value: LibraryScope.folder(folder.id)) {
                            sidebarRow(folder.name, symbol: "folder", count: store.papers.filter { $0.folderID == folder.id }.count)
                        }
                        .modifier(PaperDropTarget(store: store, folderID: folder.id))
                        .contextMenu {
                            Button("Rename folder", systemImage: "pencil") { beginFolderEdit(folder) }
                            Button("Delete folder", systemImage: "trash", role: .destructive) { folderToDelete = folder }
                        }
                    }
                    if store.folders.isEmpty {
                        Text("A place for every topic.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    HStack {
                        Text("Folders")
                        Spacer()
                        Button(action: { beginFolderEdit(nil) }) { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            .help("New folder")
                            .accessibilityLabel("New folder")
                            .keyboardShortcut("n", modifiers: [.command, .shift])
                    }
                }
            }
            .listStyle(.sidebar)

            Button { showingStorage = true } label: {
                HStack(spacing: 6) {
                    if store.isMovingStorage {
                        ProgressView().controlSize(.small)
                        Text("Copying papers…")
                    } else {
                        Image(systemName: "folder")
                        Text("Paper storage…")
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(20)
            .help("Choose where Bib stores PDFs")
        }
        .navigationTitle("Library")
        #if os(macOS)
        .toolbar(removing: .sidebarToggle)
        #endif
    }

    private var sidebarLogo: Image {
        #if os(macOS)
        Image(nsImage: NSApplication.shared.applicationIconImage)
        #else
        Image("BibLogo")
        #endif
    }

    private func sidebarRow(_ name: String, symbol: String, count: Int) -> some View {
        HStack {
            Label(name, systemImage: symbol)
                .lineLimit(1)
            Spacer()
            Text(count.formatted())
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 5)
    }

    private var paperList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(visiblePapers.count) \(visiblePapers.count == 1 ? "paper" : "papers")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                addPapersMenu
                Button {
                    paperToDelete = visiblePapers.first { $0.id == selectedPaperID }
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(!visiblePapers.contains { $0.id == selectedPaperID })
                .help("Remove the selected paper from the library")
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(PaperSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sort papers")
                .accessibilityLabel("Sort papers")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            Divider()

            if visiblePapers.isEmpty {
                QuietPlaceholder(
                    symbol: search.isEmpty ? "doc.badge.plus" : "magnifyingglass",
                    title: search.isEmpty ? "Your reading starts here." : "No matching papers",
                    message: search.isEmpty ? "Add a PDF to keep your papers and ideas together." : "Try a title, author, year, journal, or DOI."
                ) {
                    if search.isEmpty {
                        VStack(spacing: 12) {
                            Button("Import papers…", systemImage: "plus") { importing = true }
                                .buttonStyle(.borderedProminent)
                            Button("Import from arXiv…", systemImage: "link") { importingArxiv = true }
                                .buttonStyle(.borderless)
                            Button("Import by DOI…", systemImage: "number") { importingDOI = true }
                                .buttonStyle(.borderless)
                            if store.papers.isEmpty {
                                Button("Try a sample paper", action: importWelcome)
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                            }
                        }
                    } else {
                        Button("Clear search") { search = "" }
                            .buttonStyle(.borderless)
                    }
                }
            } else {
                List(selection: $selectedPaperID) {
                    ForEach(visiblePapers) { paper in
                        NavigationLink(value: paper.id) {
                            PaperRow(paper: paper)
                        }
                        .contentShape(Rectangle())
                        .draggable(PaperDragItem(id: paper.id)) {
                            Label(paper.title, systemImage: "doc.text")
                                .lineLimit(2)
                                .padding(12)
                                .frame(maxWidth: 260, alignment: .leading)
                                .background(BibTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .contextMenu {
                            Button("View metadata…", systemImage: "info.circle") {
                                metadataSummaryPaper = paper
                            }
                            if let url = paper.doiURL {
                                Link(destination: url) {
                                    Label("Open paper online", systemImage: "safari")
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 12))
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(BibTheme.canvas)
        .navigationTitle(scopeTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $search, prompt: "Search papers")
    }

    private var addPapersMenu: some View {
        Menu {
            Button("Import PDFs…", systemImage: "doc.badge.plus") { importing = true }
                .keyboardShortcut("i", modifiers: .command)
            Button("Import from arXiv…", systemImage: "link") { importingArxiv = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Import by DOI…", systemImage: "number") { importingDOI = true }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Paper storage…", systemImage: "folder") { showingStorage = true }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Import PDFs, an arXiv link, or a DOI")
    }

    private var folderEditor: some View {
        NavigationStack {
            Form {
                TextField("Folder name", text: $folderName)
                    .onSubmit(saveFolder)
            }
            .formStyle(.grouped)
            .navigationTitle(folderToRename == nil ? "New folder" : "Rename folder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { editingFolder = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: saveFolder)
                        .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Couldn’t save folder", isPresented: Binding(
                get: { folderError != nil },
                set: { if !$0 { folderError = nil } }
            )) {
                Button("OK", role: .cancel) { folderError = nil }
            } message: {
                Text(folderError ?? "Please try again.")
            }
        }
        #if os(macOS)
        .frame(width: 380, height: 180)
        #else
        .presentationDetents([.medium])
        #endif
    }

    private func beginFolderEdit(_ folder: PaperFolder?) {
        folderToRename = folder
        folderName = folder?.name ?? ""
        folderError = nil
        editingFolder = true
    }

    private func saveFolder() {
        guard !folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let folder = folderToRename {
            store.renameFolder(id: folder.id, to: folderName)
        } else if let id = store.addFolder(named: folderName) {
            scope = .folder(id)
        }
        if let error = store.errorMessage {
            store.errorMessage = nil
            folderError = error
        } else {
            editingFolder = false
        }
    }

    private func importWelcome() {
        guard let url = Bundle.main.url(forResource: "Welcome", withExtension: "pdf") else {
            store.errorMessage = "The welcome PDF is missing from the app bundle. You can import any PDF instead."
            return
        }
        if let id = store.importPDFs(from: [url], into: currentScope.folderID).first {
            selectedPaperID = id
            preferredColumn = .detail
        }
    }

    private func showImportedPaper(_ id: UUID, in folderID: UUID?) {
        let destination = folderID.map(LibraryScope.folder) ?? .all
        search = ""
        if scope != destination {
            pendingImportedPaperID = id
            scope = destination
        } else {
            selectedPaperID = id
            preferredColumn = .detail
        }
    }
}

private struct PaperRow: View {
    let paper: Paper

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(BibTheme.accent)
                .frame(width: 36, height: 46)
                .background(BibTheme.softAccent, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(paper.title)
                    .font(.system(.body, design: .serif, weight: .semibold))
                    .lineLimit(3)
                if !paper.authors.isEmpty {
                    Text(paper.authors)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(paper.hasPDF ? "PDF" : "No PDF")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    if !paper.year.isEmpty { Text(paper.year) }
                    if !paper.venue.isEmpty { Text(paper.venue).lineLimit(1) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }
}
