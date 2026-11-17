import Foundation
import HeyDanCore

actor OutboxFile {
    private let root: URL
    init(root: URL = StoreLocation.root) { self.root = root }

    func directory(host: URL, deviceId: String) -> URL {
        StoreLocation.directory(root: root, host: host)
            .appending(path: "outbox")
            .appending(path: StoreLocation.digest(deviceId), directoryHint: .isDirectory)
    }

    func load(host: URL, deviceId: String) throws -> [Outbox.Entry] {
        let file = directory(host: host, deviceId: deviceId).appending(path: "entries.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([Outbox.Entry].self, from: Data(contentsOf: file))
    }

    func save(_ entries: [Outbox.Entry], host: URL, deviceId: String) throws {
        let directory = directory(host: host, deviceId: deviceId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try JSONEncoder().encode(entries).write(to: directory.appending(path: "entries.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func clear(host: URL, deviceId: String) throws {
        let directory = directory(host: host, deviceId: deviceId)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
