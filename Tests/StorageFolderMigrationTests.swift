import CoreGraphics
import Foundation

@main
struct StorageFolderMigrationTests {
    static func main() async {
        do {
            try testCopiesReuseAndRollback()
            print("PASS: Storage copies preserve originals, reuse identical PDFs, and roll back only new files")
            try testFailuresRollBack()
            print("PASS: Missing, corrupted, and conflicting PDFs abort migration without partial copies")
            try testUnsafePathsAndSymlinks()
            print("PASS: Storage migration rejects unsafe filenames, symbolic links, and non-files")
            try testSameFolder()
            print("PASS: A resolved source folder can be selected again without duplicating PDFs")
            try testEmptyLibraryWithUnavailableSource()
            print("PASS: A library without PDFs can choose a new folder when its old folder is unavailable")
            try testRollbackPreservesEdits()
            print("PASS: Rollback preserves copied files that another process has changed")
            try await testCancellation()
            print("PASS: Cancelled migrations do not create or change files")
            print("All storage migration tests passed.")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func testCopiesReuseAndRollback() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try subdirectory("source", in: root)
        let destination = try subdirectory("destination", in: root)
        let first = source.appendingPathComponent("first.pdf")
        let reused = source.appendingPathComponent("reused.pdf")
        try makePDF(at: first)
        try makePDF(at: reused, shade: 0.2)
        let firstBytes = try Data(contentsOf: first)
        let reusedBytes = try Data(contentsOf: reused)
        let reusedCopy = destination.appendingPathComponent("reused.pdf")
        try FileManager.default.copyItem(at: reused, to: reusedCopy)
        let unrelated = destination.appendingPathComponent("notes.txt")
        try Data("Keep these notes".utf8).write(to: unrelated)

        let prepared = try StorageFolderMigration.prepare(
            fileNames: ["first.pdf", "reused.pdf", "first.pdf"], from: source, to: destination)
        let firstCopy = destination.appendingPathComponent("first.pdf")
        try expect(prepared.createdFiles == [firstCopy], "Only unique newly created copies should be recorded")
        try expect(prepared.destination == destination.resolvingSymlinksInPath(), "Destination should be resolved")
        try expect(try Data(contentsOf: firstCopy) == firstBytes, "New copy should match its source")
        try expect(try Data(contentsOf: reusedCopy) == reusedBytes, "Reused copy should remain identical")
        try expect(try Data(contentsOf: first) == firstBytes, "Source PDF should remain intact")
        try prepared.rollback()
        try prepared.rollback()
        try expect(!FileManager.default.fileExists(atPath: firstCopy.path), "Rollback should remove the new copy")
        try expect(try Data(contentsOf: reusedCopy) == reusedBytes, "Rollback must preserve a reused PDF")
        try expect(try String(contentsOf: unrelated, encoding: .utf8) == "Keep these notes", "Unrelated files should be unchanged")
    }

    private static func testFailuresRollBack() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try subdirectory("source", in: root)
        let destination = try subdirectory("destination", in: root)
        let first = source.appendingPathComponent("first.pdf")
        let second = source.appendingPathComponent("second.pdf")
        try makePDF(at: first)
        try makePDF(at: second)
        let secondCopy = destination.appendingPathComponent("second.pdf")
        try makePDF(at: secondCopy, shade: 0.1)
        let existing = try Data(contentsOf: secondCopy)
        let badPDF = source.appendingPathComponent("bad.pdf")
        try Data("Broken paper".utf8).write(to: badPDF)

        for otherName in ["second.pdf", "missing.pdf", "bad.pdf"] {
            try expectFailure("Migration should reject \(otherName)") {
                _ = try StorageFolderMigration.prepare(fileNames: ["first.pdf", otherName],
                                                       from: source, to: destination)
            }
            try expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("first.pdf").path),
                       "Any copy made before failure should be removed")
            try expect(try Data(contentsOf: secondCopy) == existing, "An existing conflicting PDF should be preserved")
            try expect(FileManager.default.fileExists(atPath: first.path), "Failed migrations must retain source PDFs")
        }
    }

    private static func testUnsafePathsAndSymlinks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try subdirectory("source", in: root)
        let destination = try subdirectory("destination", in: root)
        for name in ["../outside.pdf", "nested/inside.pdf", "back\\slash.pdf", "bad\0.pdf", "notes.txt", ""] {
            try expectFailure("An unsafe filename should fail: \(name)") {
                _ = try StorageFolderMigration.prepare(fileNames: [name], from: source, to: destination)
            }
        }
        let outside = root.appendingPathComponent("outside.pdf")
        try makePDF(at: outside)
        let outsideBytes = try Data(contentsOf: outside)
        let sourceLink = source.appendingPathComponent("source-link.pdf")
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: outside)
        try expectFailure("A source symbolic link should not be followed") {
            _ = try StorageFolderMigration.prepare(fileNames: ["source-link.pdf"], from: source, to: destination)
        }
        let valid = source.appendingPathComponent("valid.pdf")
        try makePDF(at: valid)
        let destinationLink = destination.appendingPathComponent("valid.pdf")
        try FileManager.default.createSymbolicLink(at: destinationLink, withDestinationURL: outside)
        try expectFailure("A destination symbolic link should not be followed") {
            _ = try StorageFolderMigration.prepare(fileNames: ["valid.pdf"], from: source, to: destination)
        }
        _ = try subdirectory("directory.pdf", in: source)
        try expectFailure("A source directory must not be treated as a PDF") {
            _ = try StorageFolderMigration.prepare(fileNames: ["directory.pdf"], from: source, to: destination)
        }
        try expect(try Data(contentsOf: outside) == outsideBytes, "Symlink targets must remain unchanged")
        try expect(try FileManager.default.destinationOfSymbolicLink(atPath: destinationLink.path) == outside.path,
                   "The preexisting destination link should be preserved")
    }

    private static func testSameFolder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try subdirectory("source", in: root)
        let pdf = source.appendingPathComponent("paper.pdf")
        try makePDF(at: pdf)
        let original = try Data(contentsOf: pdf)
        let alias = root.appendingPathComponent("source-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let prepared = try StorageFolderMigration.prepare(fileNames: ["paper.pdf", "paper.pdf"],
                                                         from: source, to: alias)
        try expect(prepared.createdFiles.isEmpty, "The same folder must not produce any copies")
        try prepared.rollback()
        try expect(try Data(contentsOf: pdf) == original, "Same-folder migration and rollback must retain the PDF")
        try expectFailure("Same-folder migration must still report a missing PDF") {
            _ = try StorageFolderMigration.prepare(fileNames: ["missing.pdf"], from: source, to: source)
        }
    }

    private static func testRollbackPreservesEdits() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try subdirectory("source", in: root)
        let destination = root.appendingPathComponent("new-storage")
        try makePDF(at: source.appendingPathComponent("paper.pdf"))
        let prepared = try StorageFolderMigration.prepare(fileNames: ["paper.pdf"], from: source, to: destination)
        let copy = destination.appendingPathComponent("paper.pdf")
        let handle = try FileHandle(forWritingTo: copy)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n% An external annotation change\n".utf8))
        try handle.close()
        let changed = try Data(contentsOf: copy)
        try expectFailure("Rollback should refuse to remove a file edited after the copy") {
            try prepared.rollback()
        }
        try expect(try Data(contentsOf: copy) == changed, "External changes should not be deleted")
    }

    private static func testEmptyLibraryWithUnavailableSource() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unavailableSource = root.appendingPathComponent("missing-old-storage")
        let destination = root.appendingPathComponent("new-storage")
        let prepared = try StorageFolderMigration.prepare(fileNames: [], from: unavailableSource, to: destination)
        try expect(prepared.createdFiles.isEmpty && prepared.destination == destination,
                   "An empty library should prepare its chosen folder without accessing its old one")
        var isDirectory: ObjCBool = false
        try expect(FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory)
                   && isDirectory.boolValue, "The destination folder should be created")
        try prepared.rollback()
        try expect(!FileManager.default.fileExists(atPath: unavailableSource.path),
                   "An unavailable previous folder should stay untouched")
    }

    private static func testCancellation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try subdirectory("source", in: root)
        let destination = root.appendingPathComponent("destination")
        let pdf = source.appendingPathComponent("paper.pdf")
        try makePDF(at: pdf)
        let before = try Data(contentsOf: pdf)
        let start = StartGate()
        let task = Task.detached {
            await start.wait()
            return try StorageFolderMigration.prepare(fileNames: ["paper.pdf"], from: source, to: destination)
        }
        task.cancel()
        await start.open()
        do {
            _ = try await task.value
            throw TestFailure(message: "The cancelled task should throw CancellationError")
        } catch is CancellationError {
            // Expected: cancellation is distinct from a storage error.
        }
        try expect(!FileManager.default.fileExists(atPath: destination.path),
                   "Cancellation before starting must not create a destination")
        try expect(try Data(contentsOf: pdf) == before, "Cancellation must preserve source files")
    }

    private static func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BibStorageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    private static func subdirectory(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makePDF(at url: URL, shade: CGFloat = 0.8) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw TestFailure(message: "Could not create a test PDF")
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: shade, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 250, height: 350))
        context.endPDFPage()
        context.closePDF()
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw TestFailure(message: message) }
    }

    private static func expectFailure(_ message: String, operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw TestFailure(message: message)
    }

    private struct TestFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private actor StartGate {
        private var opened = false
        private var waiter: CheckedContinuation<Void, Never>?

        func wait() async {
            if !opened { await withCheckedContinuation { waiter = $0 } }
        }

        func open() {
            opened = true
            waiter?.resume()
            waiter = nil
        }
    }
}
