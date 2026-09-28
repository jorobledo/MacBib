import CryptoKit
import CoreGraphics
import Darwin
import Foundation

/// A verified set of copies. The original PDFs remain untouched until and after
/// the caller commits the new storage location.
struct PreparedStorageMigration: Sendable {
    let destination: URL
    let createdFiles: [URL]
    fileprivate let copies: [StorageFileCopy]

    /// Used if saving the new location fails. Existing or subsequently changed
    /// files are never removed, even when they have a matching filename.
    func rollback() throws {
        var failures: [String] = []
        for copy in copies.reversed() {
            do {
                try StorageFolderMigration.removeUnchangedCopy(copy)
            } catch {
                failures.append(copy.url.lastPathComponent)
            }
        }
        if !failures.isEmpty {
            throw StorageMigrationError.rollbackFailed(failures)
        }
    }
}

/// Performs blocking filesystem work; callers should run it away from MainActor.
enum StorageFolderMigration {
    static func prepare(fileNames: [String], from source: URL,
                        to destination: URL) throws -> PreparedStorageMigration {
        try Task.checkCancellation()
        let names = try validatedUniqueNames(fileNames)
        guard source.isFileURL, destination.isFileURL else {
            throw StorageMigrationError.invalidFolder
        }
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let destination = destination.standardizedFileURL.resolvingSymlinksInPath()

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let destinationDirectory = try openDirectory(destination)
        defer { close(destinationDirectory) }
        if names.isEmpty {
            try Task.checkCancellation()
            return PreparedStorageMigration(destination: destination, createdFiles: [], copies: [])
        }
        let sourceDirectory = try openDirectory(source)
        defer { close(sourceDirectory) }
        let sameDirectory = try stamp(sourceDirectory).sameFile(as: stamp(destinationDirectory))
        var copies: [StorageFileCopy] = []

        do {
            for name in names {
                try Task.checkCancellation()
                let sourceFile = try openRegularFile(name, in: sourceDirectory)
                defer { close(sourceFile) }
                try validatePDF(sourceFile, named: name)
                if sameDirectory {
                    // Still detect missing, unreadable, or changing source files.
                    _ = try fingerprint(sourceFile, named: name)
                    continue
                }

                let destinationFile = openat(destinationDirectory, name,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                if destinationFile >= 0 {
                    defer { close(destinationFile) }
                    try requireRegularFile(destinationFile, named: name)
                    let sourceHash = try fingerprint(sourceFile, named: name)
                    let destinationHash = try fingerprint(destinationFile, named: name)
                    guard sourceHash == destinationHash else {
                        throw StorageMigrationError.conflictingFile(name)
                    }
                } else {
                    let errorCode = errno
                    guard errorCode == ENOENT else {
                        throw StorageMigrationError.fileAccess(name, errorCode)
                    }
                    let copy = try makeCopy(from: sourceFile, named: name,
                                            in: destinationDirectory, destination: destination)
                    copies.append(copy)
                }
            }
            try Task.checkCancellation()
            return PreparedStorageMigration(destination: destination,
                                            createdFiles: copies.map(\.url), copies: copies)
        } catch {
            let prepared = PreparedStorageMigration(destination: destination,
                                                    createdFiles: copies.map(\.url), copies: copies)
            do {
                try prepared.rollback()
            } catch let cleanupError {
                throw StorageMigrationError.cleanupFailed(error.localizedDescription,
                                                           cleanupError.localizedDescription)
            }
            throw error
        }
    }

    private static func validatedUniqueNames(_ fileNames: [String]) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in fileNames {
            guard !name.isEmpty, !name.contains("\\"), !name.contains("\0"),
                  name == (name as NSString).lastPathComponent,
                  (name as NSString).pathExtension.lowercased() == "pdf" else {
                throw StorageMigrationError.invalidFileName(name)
            }
            if seen.insert(name).inserted { result.append(name) }
        }
        return result
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw StorageMigrationError.fileAccess(url.lastPathComponent, errno)
        }
        return descriptor
    }

    private static func openRegularFile(_ name: String, in directory: Int32) throws -> Int32 {
        // O_NONBLOCK lets us reject a FIFO without first blocking while opening it.
        let descriptor = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw StorageMigrationError.fileAccess(name, errno) }
        do {
            try requireRegularFile(descriptor, named: name)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func requireRegularFile(_ descriptor: Int32, named name: String) throws {
        let value = try stamp(descriptor)
        guard value.isRegular else { throw StorageMigrationError.notRegularFile(name) }
    }

    private static func validatePDF(_ descriptor: Int32, named name: String) throws {
        let before = try stamp(descriptor)
        var descriptor = descriptor
        // Read through the already validated descriptor. Reopening the path here
        // could follow a file swapped for a symbolic link during migration.
        var callbacks = CGDataProviderDirectCallbacks(
            version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { context, buffer, position, count in
                guard let context else { return 0 }
                let descriptor = context.assumingMemoryBound(to: Int32.self).pointee
                var result: Int
                repeat {
                    result = pread(descriptor, buffer, count, position)
                } while result < 0 && errno == EINTR
                return max(result, 0)
            }, releaseInfo: nil)
        try withUnsafeMutablePointer(to: &descriptor) { pointer in
            guard let provider = CGDataProvider(directInfo: pointer, size: before.size, callbacks: &callbacks),
                  let document = CGPDFDocument(provider), document.numberOfPages > 0,
                  !document.isEncrypted || document.isUnlocked else {
                throw StorageMigrationError.invalidPDF(name)
            }
        }
        try Task.checkCancellation()
        guard try stamp(descriptor) == before else {
            throw StorageMigrationError.fileChanged(name)
        }
    }

    private static func makeCopy(from source: Int32, named name: String, in directory: Int32,
                                 destination: URL) throws -> StorageFileCopy {
        // Exclusive creation cannot overwrite a file added since the earlier check.
        let target = openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                            mode_t(0o600))
        guard target >= 0 else { throw StorageMigrationError.fileAccess(name, errno) }
        defer { close(target) }
        let targetIdentity = try stamp(target)
        let sourceBefore = try stamp(source)
        let sourceHandle = FileHandle(fileDescriptor: source, closeOnDealloc: false)
        let targetHandle = FileHandle(fileDescriptor: target, closeOnDealloc: false)
        var sourceHash = SHA256()

        do {
            while true {
                try Task.checkCancellation()
                guard let bytes = try sourceHandle.read(upToCount: 1_048_576), !bytes.isEmpty else { break }
                sourceHash.update(data: bytes)
                try targetHandle.write(contentsOf: bytes)
            }
            guard try stamp(source) == sourceBefore else {
                throw StorageMigrationError.fileChanged(name)
            }
            try targetHandle.synchronize()
            guard lseek(target, 0, SEEK_SET) >= 0 else {
                throw StorageMigrationError.fileAccess(name, errno)
            }
            let targetHash = try fingerprint(target, named: name)
            guard Data(sourceHash.finalize()) == targetHash else {
                throw StorageMigrationError.verificationFailed(name)
            }
            return StorageFileCopy(url: destination.appendingPathComponent(name),
                                   stamp: try stamp(target), fingerprint: targetHash)
        } catch {
            // The incomplete copy belongs to this attempt. Do not follow or remove
            // a different item if another process has replaced it in the meantime.
            var current = stat()
            if fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0 {
                if StorageFileStamp(current).sameFile(as: targetIdentity),
                   unlinkat(directory, name, 0) == 0 {
                    throw error
                }
                throw StorageMigrationError.cleanupFailed(error.localizedDescription,
                    StorageMigrationError.rollbackFailed([name]).localizedDescription)
            }
            if errno != ENOENT {
                throw StorageMigrationError.cleanupFailed(error.localizedDescription,
                    StorageMigrationError.rollbackFailed([name]).localizedDescription)
            }
            throw error
        }
    }

    private static func fingerprint(_ descriptor: Int32, named name: String,
                                    checkCancellation: Bool = true) throws -> Data {
        let before = try stamp(descriptor)
        guard before.isRegular else { throw StorageMigrationError.notRegularFile(name) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var hasher = SHA256()
        while true {
            if checkCancellation { try Task.checkCancellation() }
            guard let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty else { break }
            hasher.update(data: bytes)
        }
        guard try stamp(descriptor) == before else {
            throw StorageMigrationError.fileChanged(name)
        }
        return Data(hasher.finalize())
    }

    fileprivate static func removeUnchangedCopy(_ copy: StorageFileCopy) throws {
        let directory = try openDirectory(copy.url.deletingLastPathComponent())
        defer { close(directory) }
        let name = copy.url.lastPathComponent
        let descriptor = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw StorageMigrationError.rollbackFailed([name])
        }
        defer { close(descriptor) }
        guard try stamp(descriptor) == copy.stamp,
              try fingerprint(descriptor, named: name, checkCancellation: false) == copy.fingerprint else {
            throw StorageMigrationError.rollbackFailed([name])
        }
        var current = stat()
        guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              StorageFileStamp(current) == copy.stamp,
              unlinkat(directory, name, 0) == 0 else {
            throw StorageMigrationError.rollbackFailed([name])
        }
    }

    private static func stamp(_ descriptor: Int32) throws -> StorageFileStamp {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            throw StorageMigrationError.fileAccess("PDF", errno)
        }
        return StorageFileStamp(value)
    }
}

fileprivate struct StorageFileCopy: Sendable {
    let url: URL
    let stamp: StorageFileStamp
    let fingerprint: Data
}

fileprivate struct StorageFileStamp: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let mode: mode_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
        size = value.st_size
        mode = value.st_mode
        modifiedSeconds = value.st_mtimespec.tv_sec
        modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec
        changedNanoseconds = value.st_ctimespec.tv_nsec
    }

    var isRegular: Bool { mode & S_IFMT == S_IFREG }

    func sameFile(as other: StorageFileStamp) -> Bool {
        device == other.device && inode == other.inode
    }
}

private enum StorageMigrationError: LocalizedError {
    case invalidFileName(String)
    case invalidFolder
    case fileAccess(String, Int32)
    case notRegularFile(String)
    case invalidPDF(String)
    case fileChanged(String)
    case conflictingFile(String)
    case verificationFailed(String)
    case rollbackFailed([String])
    case cleanupFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidFileName(let name):
            return "The library contains an invalid PDF filename: \(name)."
        case .invalidFolder:
            return "Choose a folder on this device or an available connected drive."
        case .fileAccess(let name, let code):
            return "Could not access \(name): \(String(cString: strerror(code)))."
        case .notRegularFile(let name):
            return "\(name) is not a regular PDF file. Symbolic links and folders cannot be migrated."
        case .invalidPDF(let name):
            return "\(name) is not a readable, unlocked PDF. Restore the original PDF before changing its storage folder."
        case .fileChanged(let name):
            return "\(name) changed while it was being copied. Try again after other changes have finished."
        case .conflictingFile(let name):
            return "The chosen folder already contains a different file named \(name). Choose another folder or rename that file."
        case .verificationFailed(let name):
            return "The copy of \(name) could not be verified. The library still uses the original folder."
        case .rollbackFailed(let names):
            return "Some copied files could not be removed safely: \(names.joined(separator: ", ")). The original PDFs are unchanged."
        case .cleanupFailed(let failure, let cleanup):
            return "\(failure) \(cleanup)"
        }
    }
}
