import SwiftUI

@main
struct BibApp: App {
    @StateObject private var library = LibraryStore()

    var body: some Scene {
        WindowGroup {
            LibraryView(store: library)
                .tint(BibTheme.accent)
                .task { await library.prepareStorageIfNeeded() }
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 580)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.automatic)
        #endif
    }
}
