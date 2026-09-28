import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit

@main
@MainActor
struct PDFHighlightsTests {
    static func main() {
        do {
            try testColorsAndPreservation()
            print("PASS: All highlight colors persist while text, existing annotations, and source PDFs survive")
            try testMultipleLinesAndPages()
            print("PASS: Multiline and multipage selections persist as separate text highlights")
            try testRecolorAndRemoval()
            print("PASS: Recoloring avoids duplicates; removing selected highlights works after reopening")
            try testFailedWriteRollsBack()
            print("PASS: Failed highlight writes roll back additions, recoloring, and removals")
            try testConflictsAndDeletedFiles()
            print("PASS: Stale windows and deleted PDFs cannot be overwritten or recreated")
            try testRejectedSelectionsAndProtectedPDFs()
            print("PASS: Empty, foreign, and protected PDF selections leave documents unchanged")
            print("All PDF highlight tests passed.")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static let pageLines = [
        ["Yellow highlights make key ideas easy to find.",
         "Green marks a method worth remembering.",
         "Blue keeps useful evidence close at hand.",
         "Pink calls attention to a question for later."],
        ["A second page continues the same argument.",
         "Highlights stay with the paper when it reopens.",
         "An unmarked line remains fully selectable."]
    ]

    private static func testColorsAndPreservation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.pdf")
        let managed = root.appendingPathComponent("managed.pdf")
        try makePDF(at: source)
        let initialDocument = try open(source)
        let initialPage = try unwrap(initialDocument.page(at: 0), "Missing first page")
        let imported = PDFAnnotation(bounds: CGRect(x: 40, y: 500, width: 100, height: 18), forType: .highlight, withProperties: nil)
        imported.userName = "Original author"
        imported.contents = "Existing annotation"
        imported.color = .orange
        initialPage.addAnnotation(imported)
        let link = PDFAnnotation(bounds: CGRect(x: 40, y: 450, width: 100, height: 18), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com/paper")
        initialPage.addAnnotation(link)
        try unwrap(initialDocument.dataRepresentation(), "Could not save existing annotations").write(to: source)
        let sourceBytes = try Data(contentsOf: source)
        try FileManager.default.copyItem(at: source, to: managed)

        let document = try open(managed)
        let originalText = document.string
        let editor = PDFHighlightEditor(document: document, url: managed)
        for (index, color) in PDFHighlightColor.allCases.enumerated() {
            try editor.add(selection: selection(pageLines[0][index], in: document), color: color)
        }
        let reopened = try open(managed)
        let page = try unwrap(reopened.page(at: 0), "Missing saved first page")
        let highlights = ownHighlights(on: page)
        try expect(highlights.count == 4, "Expected four saved highlights")
        for (index, color) in PDFHighlightColor.allCases.enumerated() {
            let line = try selection(pageLines[0][index], in: reopened)
            let highlight = try unwrap(highlights.first(where: { $0.bounds.intersects(line.bounds(for: page)) }), "Missing \(color.rawValue) highlight")
            try expect(sameColor(highlight.color, color.color), "Saved \(color.rawValue) color changed")
            try expect(highlight.quadrilateralPoints?.count == 4, "A text line needs exactly four highlight points")
        }
        try expect(reopened.string == originalText, "Highlighting must preserve selectable text")
        try expect(page.annotations.contains(where: { $0.userName == "Original author" && $0.contents == "Existing annotation" }),
                   "Imported annotations must be preserved")
        try expect(page.annotations.contains(where: { $0.type == "Link" && $0.url?.absoluteString == "https://example.com/paper" }),
                   "Existing links must be preserved")
        try expect(try Data(contentsOf: source) == sourceBytes, "The source PDF must remain byte-for-byte unchanged")
        if let output = ProcessInfo.processInfo.environment["BIB_HIGHLIGHT_FIXTURE"] {
            try Data(contentsOf: managed).write(to: URL(fileURLWithPath: output))
        }
    }

    private static func testMultipleLinesAndPages() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("multipage.pdf")
        try makePDF(at: url)
        let document = try open(url)
        let selected = PDFSelection(document: document)
        selected.add(try selection(pageLines[0][1], in: document))
        selected.add(try selection(pageLines[0][2], in: document))
        selected.add(try selection(pageLines[1][0], in: document))
        selected.add(try selection(pageLines[1][1], in: document))
        try PDFHighlightEditor(document: document, url: url).add(selection: selected, color: .green)
        let reopened = try open(url)
        for index in 0...1 {
            let page = try unwrap(reopened.page(at: index), "Missing saved page")
            let highlights = ownHighlights(on: page)
            try expect(highlights.count == 2, "Each page should have a separate highlight for each selected line")
            try expect(highlights.allSatisfy { $0.bounds.height < 30 && $0.bounds.width > 100 },
                       "Highlights should cover individual lines instead of a paragraph rectangle")
        }
    }

    private static func testRecolorAndRemoval() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("recolor.pdf")
        try makePDF(at: url)
        let document = try open(url)
        let editor = PDFHighlightEditor(document: document, url: url)
        let selected = try selection(pageLines[0][0], in: document)
        let page = try unwrap(document.page(at: 0), "Missing page")
        let imported = PDFAnnotation(bounds: selected.bounds(for: page), forType: .highlight, withProperties: nil)
        imported.userName = "Someone else"
        page.addAnnotation(imported)
        // The imported annotation is intentionally part of this editor's next save.
        try editor.add(selection: selected, color: .yellow)
        try editor.add(selection: selected, color: .yellow)
        try editor.add(selection: selected, color: .pink)
        try expect(ownHighlights(on: page).count == 1, "Repeated selection must not stack highlights")
        try editor.add(selection: selection(pageLines[0][2], in: document), color: .blue)

        let reopened = try open(url)
        let savedEditor = PDFHighlightEditor(document: reopened, url: url)
        let savedPage = try unwrap(reopened.page(at: 0), "Missing reopened page")
        let selectedAgain = try selection(pageLines[0][0], in: reopened)
        try savedEditor.add(selection: selectedAgain, color: .green)
        try expect(ownHighlights(on: savedPage).count == 2, "Recoloring after reopening must not create a duplicate")
        let recolored = try unwrap(ownHighlights(on: savedPage).first(where: { $0.bounds.intersects(selectedAgain.bounds(for: savedPage)) }), "Missing recolored annotation")
        try expect(sameColor(recolored.color, PDFHighlightColor.green.color), "Exact reselection must change the highlight color")
        let partial = try selection("key ideas", in: reopened)
        try expect(savedEditor.hasHighlights(in: partial), "Selecting a part of a highlight must enable removal")
        try savedEditor.remove(selection: partial)
        try expect(!savedEditor.hasHighlights(in: selectedAgain), "The selected line's Bib highlight should be removed")
        try expect(savedPage.annotations.contains(where: { $0.userName == "Someone else" }), "Removing must preserve an overlapping imported highlight")
        let afterRemoval = try open(url)
        let remaining = ownHighlights(on: try unwrap(afterRemoval.page(at: 0), "Missing page after removal"))
        try expect(remaining.count == 1 && sameColor(remaining[0].color, PDFHighlightColor.blue.color),
                   "Removal must persist and retain unrelated highlights")
    }

    private static func testFailedWriteRollsBack() throws {
        let root = try temporaryDirectory()
        let directory = root.appendingPathComponent("readonly")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("paper.pdf")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: root)
        }
        try makePDF(at: url)
        let document = try open(url)
        let editor = PDFHighlightEditor(document: document, url: url)
        let selected = try selection(pageLines[0][0], in: document)
        try editor.add(selection: selected, color: .yellow)
        let before = try Data(contentsOf: url)
        let page = try unwrap(document.page(at: 0), "Missing page")
        let original = try unwrap(ownHighlights(on: page).first, "Missing original highlight")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        try expectThrows("A read-only directory must reject addition") {
            try editor.add(selection: selection(pageLines[0][1], in: document), color: .blue)
        }
        try expect(ownHighlights(on: page) == [original], "Failed additions must roll back in-memory annotations")
        try expectThrows("A read-only directory must reject recoloring") {
            try editor.add(selection: selected, color: .pink)
        }
        try expect(ownHighlights(on: page) == [original] && sameColor(original.color, PDFHighlightColor.yellow.color),
                   "Failed recoloring must restore the original annotation and color")
        try expectThrows("A read-only directory must reject removal") { try editor.remove(selection: selected) }
        try expect(ownHighlights(on: page) == [original], "Failed removal must restore the annotation in memory")
        try expect(try Data(contentsOf: url) == before, "Failed saves must preserve original PDF bytes")
    }

    private static func testConflictsAndDeletedFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("shared.pdf")
        try makePDF(at: url)
        let first = try open(url)
        let second = try open(url)
        let firstEditor = PDFHighlightEditor(document: first, url: url)
        let secondEditor = PDFHighlightEditor(document: second, url: url)
        try firstEditor.add(selection: selection(pageLines[0][0], in: first), color: .yellow)
        let saved = try Data(contentsOf: url)
        try expectThrows("A stale editor must reject a conflicting save") {
            try secondEditor.add(selection: selection(pageLines[0][1], in: second), color: .green)
        }
        try expect(try Data(contentsOf: url) == saved, "A stale editor must preserve the latest file")
        try expect(ownHighlights(on: try unwrap(second.page(at: 0), "Missing second editor page")).isEmpty,
                   "A rejected stale edit must leave its document unchanged")
        try FileManager.default.removeItem(at: url)
        try expectThrows("Deleted papers must not be recreated") {
            try firstEditor.add(selection: selection(pageLines[0][1], in: first), color: .green)
        }
        try expect(!FileManager.default.fileExists(atPath: url.path), "Saving a deleted paper must not recreate its PDF")
    }

    private static func testRejectedSelectionsAndProtectedPDFs() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("paper.pdf")
        try makePDF(at: url)
        let document = try open(url)
        let editor = PDFHighlightEditor(document: document, url: url)
        let before = try Data(contentsOf: url)
        let empty = PDFSelection(document: document)
        try expect(!editor.hasHighlights(in: empty), "An empty selection must not enable removal")
        try expectThrows("Empty selections must be rejected") { try editor.add(selection: empty, color: .yellow) }
        let foreign = try open(url)
        try expectThrows("Selections from a different document must be rejected") {
            try editor.add(selection: selection(pageLines[0][0], in: foreign), color: .yellow)
        }
        try expect(try Data(contentsOf: url) == before, "Rejected selections must preserve the PDF")

        let protectedURL = root.appendingPathComponent("protected.pdf")
        try expect(document.write(to: protectedURL, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]),
                   "Could not create a protected PDF")
        let protected = try open(protectedURL)
        let protectedEditor = PDFHighlightEditor(document: protected, url: protectedURL)
        let protectedBytes = try Data(contentsOf: protectedURL)
        try expectThrows("Locked documents must reject annotations") {
            try protectedEditor.add(selection: PDFSelection(document: protected), color: .yellow)
        }
        try expect(protected.unlock(withPassword: "secret"), "Could not unlock fixture")
        try expectThrows("Unlocked encrypted documents must retain protection") {
            try protectedEditor.add(selection: selection(pageLines[0][0], in: protected), color: .yellow)
        }
        try expect(try Data(contentsOf: protectedURL) == protectedBytes, "Rejected annotations must preserve encryption and bytes")
    }

    private static func makePDF(at url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try unwrap(CGContext(url as CFURL, mediaBox: &mediaBox,
                                         [kCGPDFContextTitle as String: "Highlight test paper"] as CFDictionary), "Could not create PDF fixture")
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        for lines in pageLines {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            for (index, text) in lines.enumerated() {
                let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                context.textPosition = CGPoint(x: 40, y: 710 - index * 36)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func selection(_ text: String, in document: PDFDocument) throws -> PDFSelection {
        try unwrap(document.findString(text, withOptions: []).first, "Could not select fixture text: \(text)")
    }

    private static func ownHighlights(on page: PDFPage) -> [PDFAnnotation] {
        page.annotations.filter { $0.type == "Highlight" && $0.userName == "Bib" }
    }

    private static func sameColor(_ first: NSColor, _ second: NSColor) -> Bool {
        guard let first = first.usingColorSpace(.deviceRGB), let second = second.usingColorSpace(.deviceRGB) else { return false }
        return abs(first.redComponent - second.redComponent) < 0.02
            && abs(first.greenComponent - second.greenComponent) < 0.02
            && abs(first.blueComponent - second.blueComponent) < 0.02
            && abs(first.alphaComponent - second.alphaComponent) < 0.02
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BibHighlightTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func open(_ url: URL) throws -> PDFDocument {
        try unwrap(PDFDocument(url: url), "Could not open PDF: \(url.lastPathComponent)")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw TestFailure(message: message) }
    }

    private static func expectThrows(_ message: String, operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw TestFailure(message: message)
    }

    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw TestFailure(message: message) }
        return value
    }

    private struct TestFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
