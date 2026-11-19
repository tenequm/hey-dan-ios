import CryptoKit
import Foundation
import HeyDanCore

extension Outbox {
    nonisolated static var fileLimitMessage: String { "Files must be at most \(maximumFileBytes / 1024 / 1024) MiB." }
}

actor OutboxFile {
    private let root: URL
    private let downloads: URL
    /// Downloads can be fetched again, so they live where the system may purge them; the outbox must not.
    init(root: URL = StoreLocation.root, downloads: URL = StoreLocation.downloads) {
        self.root = root
        self.downloads = downloads
        StoreLocation.excludeFromBackup(root)
    }

    func directory(host: URL, deviceId: String) -> URL {
        StoreLocation.directory(root: root, host: host)
            .appending(path: "outbox")
            .appending(path: StoreLocation.digest(deviceId), directoryHint: .isDirectory)
    }

    func load(host: URL, deviceId: String) throws -> [Outbox.Entry] {
        let file = directory(host: host, deviceId: deviceId).appending(path: "entries.json")
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch CocoaError.fileReadNoSuchFile { return [] }
        do { return try JSONDecoder().decode([Outbox.Entry].self, from: data) }
        catch is DecodingError {
            try FileManager.default.moveItem(at: file, to: file.deletingLastPathComponent().appending(path: "entries-invalid-" + UUID().uuidString + ".json"))
            return []
        }
    }

    func save(_ entries: [Outbox.Entry], host: URL, deviceId: String) throws {
        let directory = directory(host: host, deviceId: deviceId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try JSONEncoder().encode(entries).write(to: directory.appending(path: "entries.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func clear(host: URL, deviceId: String) throws {
        try Self.remove(directory(host: host, deviceId: deviceId))
        try Self.remove(downloadsDirectory(host: host, deviceId: deviceId))
    }
    func stage(_ attachments: [StagedAttachment], host: URL, deviceId: String) throws -> [Outbox.Attachment] {
        let directory = directory(host: host, deviceId: deviceId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var result: [Outbox.Attachment] = []
        do {
            for attachment in attachments {
                let access = attachment.fileURL.startAccessingSecurityScopedResource()
                defer { if access { attachment.fileURL.stopAccessingSecurityScopedResource() } }
                let size = try attachment.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= Outbox.maximumFileBytes else { throw AppError.limit(Outbox.fileLimitMessage) }
                let data = try Data(contentsOf: attachment.fileURL)
                // The size key can be missing; the bytes read are what would be saved and sent.
                guard data.count <= Outbox.maximumFileBytes else { throw AppError.limit(Outbox.fileLimitMessage) }
                let name = UUID().uuidString
                try data.write(to: directory.appending(path: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                result.append(Outbox.Attachment(localFileName: name, name: attachment.name,
                    mimeType: attachment.mimeType, size: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                    durationMs: attachment.durationMs))
            }
            return result
        } catch {
            for attachment in result { try? FileManager.default.removeItem(at: directory.appending(path: attachment.localFileName)) }
            throw error
        }
    }
    func bytes(_ attachment: Outbox.Attachment, host: URL, deviceId: String) throws -> Data {
        try Data(contentsOf: directory(host: host, deviceId: deviceId).appending(path: attachment.localFileName))
    }
    func removeCopies(_ entries: [Outbox.Entry], host: URL, deviceId: String) throws {
        for entry in entries {
            for attachment in entry.attachments {
                try Self.remove(directory(host: host, deviceId: deviceId).appending(path: attachment.localFileName))
            }
        }
    }
    /// Removes without a separate existence check: a file already gone is not an error.
    private static func remove(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile {}
    }
    private func safeName(_ name: String) -> String {
        let value = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "attachment"
        return value == "." || value == ".." || value.isEmpty ? "attachment" : value
    }
    private func downloadsDirectory(host: URL, deviceId: String) -> URL {
        StoreLocation.directory(root: downloads, host: host)
            .appending(path: "downloads")
            .appending(path: StoreLocation.digest(deviceId), directoryHint: .isDirectory)
    }
    private func downloadURL(fileId: String, name: String, host: URL, deviceId: String) -> URL {
        downloadsDirectory(host: host, deviceId: deviceId).appending(path: StoreLocation.digest(fileId)).appending(path: safeName(name))
    }
    func cached(fileId: String, name: String, host: URL, deviceId: String) -> URL? {
        let url = downloadURL(fileId: fileId, name: name, host: host, deviceId: deviceId)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    func cache(_ data: Data, fileId: String, name: String, host: URL, deviceId: String) throws -> URL {
        let url = downloadURL(fileId: fileId, name: name, host: host, deviceId: deviceId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }
}
