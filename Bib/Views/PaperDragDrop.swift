import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let bibPaper = UTType(exportedAs: "local.bib.paper-reference", conformingTo: .data)
}

/// Transfer only an ID so a drop always uses the paper's current saved metadata.
struct PaperDragItem: Codable, Transferable, Sendable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .bibPaper)
    }
}

struct PaperDropTarget: ViewModifier {
    let store: LibraryStore
    let folderID: UUID?
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .fill(BibTheme.accent.opacity(isTargeted ? 0.16 : 0))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(BibTheme.accent.opacity(isTargeted ? 0.8 : 0), lineWidth: 1.5)
                    }
                    .allowsHitTesting(false)
            }
            .onDrop(of: [.bibPaper], delegate: PaperFolderDropDelegate(
                store: store, folderID: folderID, isTargeted: $isTargeted
            ))
    }
}

private struct PaperFolderDropDelegate: DropDelegate {
    let store: LibraryStore
    let folderID: UUID?
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.bibPaper])
    }

    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = info.itemProviders(for: [.bibPaper])
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            await PaperDropTransfer.move(providers, into: folderID, store: store)
        }
        return true
    }
}

@MainActor
enum PaperDropTransfer {
    /// Decode the whole drop before committing; a malformed item cannot cause a partial move.
    @discardableResult
    static func move(_ providers: [NSItemProvider], into folderID: UUID?, store: LibraryStore) async -> Bool {
        do {
            var ids: [UUID] = []
            for provider in providers {
                let item: PaperDragItem = try await withCheckedThrowingContinuation { continuation in
                    _ = provider.loadTransferable(type: PaperDragItem.self) { result in
                        continuation.resume(with: result)
                    }
                }
                ids.append(item.id)
            }
            return store.movePapers(ids: ids, to: folderID)
        } catch {
            store.errorMessage = "The dragged paper could not be read. Please drag it from your library again."
            return false
        }
    }
}
