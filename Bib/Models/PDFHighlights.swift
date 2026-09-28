import CryptoKit
import Foundation
import PDFKit

#if os(macOS)
import AppKit
typealias PDFHighlightNativeColor = NSColor
#else
import UIKit
typealias PDFHighlightNativeColor = UIColor
#endif

enum PDFHighlightColor: String, CaseIterable, Identifiable {
    case yellow, green, blue, pink

    var id: String { rawValue }

    var color: PDFHighlightNativeColor {
        switch self {
        // Highlight annotations use multiply blending. Opaque pastel colors also
        // retain their appearance when PDFKit serializes and reopens the file.
        case .yellow: return PDFHighlightNativeColor(red: 1, green: 0.92, blue: 0.48, alpha: 1)
        case .green: return PDFHighlightNativeColor(red: 0.62, green: 0.88, blue: 0.66, alpha: 1)
        case .blue: return PDFHighlightNativeColor(red: 0.64, green: 0.81, blue: 1, alpha: 1)
        case .pink: return PDFHighlightNativeColor(red: 1, green: 0.69, blue: 0.80, alpha: 1)
        }
    }
}

/// Edits only Bib's annotations in a library's managed PDF copy.
@MainActor
final class PDFHighlightEditor {
    let document: PDFDocument
    private let url: URL
    private var savedFingerprint: SHA256.Digest?
    private static let annotationAuthor = "Bib"

    init(document: PDFDocument, url: URL) {
        self.document = document
        self.url = url
        savedFingerprint = (try? Data(contentsOf: url)).map { SHA256.hash(data: $0) }
    }

    func add(selection: PDFSelection, color: PDFHighlightColor) throws {
        try requireEditableDocument()
        let lines = try selectedLines(in: selection)
        var additions: [PageAnnotation] = []
        var removals: [PageAnnotation] = []

        for line in lines {
            // Replace an identical line selection so recoloring never stacks marks.
            // Other selections, including imported highlights, remain independent.
            for annotation in line.page.annotations where isOwnHighlight(annotation)
                && sameBounds(annotation.bounds, line.bounds) {
                removals.append(PageAnnotation(page: line.page, annotation: annotation))
            }
            let annotation = PDFAnnotation(bounds: line.bounds, forType: .highlight, withProperties: nil)
            annotation.color = color.color
            annotation.userName = Self.annotationAuthor
            annotation.modificationDate = Date()
            // PDFKit expects Z-ordered points relative to the annotation's origin.
            let width = line.bounds.width
            let height = line.bounds.height
            annotation.quadrilateralPoints = [
                pointValue(CGPoint(x: 0, y: height)), pointValue(CGPoint(x: width, y: height)),
                pointValue(.zero), pointValue(CGPoint(x: width, y: 0))
            ]
            additions.append(PageAnnotation(page: line.page, annotation: annotation))
        }
        try save(additions: additions, removals: removals)
    }

    /// Selecting any part of a Bib highlight removes that line's entire mark.
    func remove(selection: PDFSelection) throws {
        try requireEditableDocument()
        let lines = try selectedLines(in: selection)
        let removals = highlights(intersecting: lines)
        guard !removals.isEmpty else { return }
        try save(additions: [], removals: removals)
    }

    func hasHighlights(in selection: PDFSelection) -> Bool {
        guard let lines = try? selectedLines(in: selection) else { return false }
        return !highlights(intersecting: lines).isEmpty
    }

    private struct SelectedLine {
        let page: PDFPage
        let bounds: CGRect
    }

    private struct PageAnnotation {
        let page: PDFPage
        let annotation: PDFAnnotation
    }

    private func selectedLines(in selection: PDFSelection) throws -> [SelectedLine] {
        guard !selection.pages.isEmpty,
              selection.pages.allSatisfy({ $0.document === document }) else {
            throw HighlightError.noSelection
        }
        var result: [SelectedLine] = []
        for line in selection.selectionsByLine() {
            guard let text = line.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            for page in line.pages {
                guard page.document === document else { throw HighlightError.noSelection }
                let bounds = line.bounds(for: page)
                guard !bounds.isNull, !bounds.isInfinite, !bounds.isEmpty,
                      bounds.minX.isFinite, bounds.minY.isFinite,
                      bounds.width.isFinite, bounds.height.isFinite else { continue }
                if !result.contains(where: { $0.page === page && sameBounds($0.bounds, bounds) }) {
                    result.append(SelectedLine(page: page, bounds: bounds))
                }
            }
        }
        guard !result.isEmpty else { throw HighlightError.noSelection }
        return result
    }

    private func isOwnHighlight(_ annotation: PDFAnnotation) -> Bool {
        annotation.type == "Highlight" && annotation.userName == Self.annotationAuthor
    }

    private func sameBounds(_ first: CGRect, _ second: CGRect) -> Bool {
        // PDF serialization can round coordinates slightly.
        abs(first.minX - second.minX) < 0.25 && abs(first.minY - second.minY) < 0.25
            && abs(first.width - second.width) < 0.25 && abs(first.height - second.height) < 0.25
    }

    private func highlights(intersecting lines: [SelectedLine]) -> [PageAnnotation] {
        var result: [PageAnnotation] = []
        var seen = Set<ObjectIdentifier>()
        for line in lines {
            for annotation in line.page.annotations where isOwnHighlight(annotation) {
                let overlap = annotation.bounds.intersection(line.bounds)
                if !overlap.isNull, overlap.width > 0.1, overlap.height > 0.1,
                   seen.insert(ObjectIdentifier(annotation)).inserted {
                    result.append(PageAnnotation(page: line.page, annotation: annotation))
                }
            }
        }
        return result
    }

    private func requireEditableDocument() throws {
        // Rewriting encrypted PDFs can discard protection, even when unlocked.
        guard !document.isLocked, !document.isEncrypted, document.allowsCommenting else {
            throw HighlightError.protectedDocument
        }
    }

    private func requireUnchangedFile() throws {
        guard let savedFingerprint, let data = try? Data(contentsOf: url) else {
            throw HighlightError.missingFile
        }
        guard SHA256.hash(data: data) == savedFingerprint else {
            throw HighlightError.changedFile
        }
    }

    private func save(additions: [PageAnnotation], removals: [PageAnnotation]) throws {
        try requireUnchangedFile()
        for item in removals { item.page.removeAnnotation(item.annotation) }
        for item in additions { item.page.addAnnotation(item.annotation) }

        do {
            guard let data = document.dataRepresentation() else { throw HighlightError.encodingFailed }
            // Check again after serialization, then atomically replace the existing file.
            // Separate open windows cannot overwrite one another's saved highlights.
            try requireUnchangedFile()
            try data.write(to: url, options: .atomic)
            savedFingerprint = SHA256.hash(data: data)
        } catch {
            for item in additions { item.page.removeAnnotation(item.annotation) }
            for item in removals { item.page.addAnnotation(item.annotation) }
            throw error
        }
    }

    private func pointValue(_ point: CGPoint) -> NSValue {
        #if os(macOS)
        return NSValue(point: point)
        #else
        return NSValue(cgPoint: point)
        #endif
    }

    private enum HighlightError: LocalizedError {
        case noSelection, protectedDocument, missingFile, changedFile, encodingFailed

        var errorDescription: String? {
            switch self {
            case .noSelection:
                return "Select text in this paper to highlight it. Scanned pages need selectable text."
            case .protectedDocument:
                return "This PDF is protected. Import an unprotected copy to add highlights."
            case .missingFile:
                return "The paper's PDF is no longer available. Reopen the paper before editing its highlights."
            case .changedFile:
                return "This PDF changed in another window or app. Reopen the paper before editing its highlights."
            case .encodingFailed:
                return "The highlights could not be saved. The PDF has not been changed."
            }
        }
    }
}
