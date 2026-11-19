import Foundation
import CryptoKit
import HeyDanCore
import SwiftData

@Model final class CachedThreadEntity {
    #Index<CachedThreadEntity>([\.deviceId], [\.entityId], [\.conversationId], [\.order], [\.seq], [\.kind])
    @Attribute(.unique) var key: String
    var deviceId: String
    var entityId: String
    var conversationId: String
    var order: Int64
    var seq: Int64
    var kind: String
    var json: Data

    init(deviceId: String, entityId: String, conversationId: String, order: Int64,
         seq: Int64, kind: String, json: Data) {
        key = Self.key(device: StoreLocation.digest(deviceId), kind: kind, entityId: entityId)
        self.deviceId = deviceId
        self.entityId = entityId
        self.conversationId = conversationId
        self.order = order
        self.seq = seq
        self.kind = kind
        self.json = json
    }

    static func key(device: String, kind: String, entityId: String) -> String { device + ":" + (kind == "conversation" ? kind : "item") + ":" + entityId }
}

@Model final class CachedStreamCursor {
    @Attribute(.unique) var deviceId: String
    var cursor: Int64?
    var historyFloors: Data?
    init(deviceId: String, cursor: Int64?) {
        self.deviceId = deviceId
        self.cursor = cursor
    }
}

nonisolated enum StoreLocation {
    static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Chat", directoryHint: .isDirectory)
    }
    static var downloads: URL {
        URL.cachesDirectory.appending(path: "Chat", directoryHint: .isDirectory)
    }
    /// Device keys never leave this phone, so a restored copy of its chats could never be read or cleared.
    static func excludeFromBackup(_ root: URL) {
        var url = root
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do { try url.setResourceValues(values) } catch { CallLog.log(.store, "backup_exclusion_failed") }
    }
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func directory(root: URL, host: URL) -> URL {
        root.appending(path: digest(host.absoluteString), directoryHint: .isDirectory)
    }
}

actor SwiftDataThreadStore: ThreadStore {
    static let schemaVersion = 3
    private let root: URL
    private let version: Int
    private let inMemory: Bool
    private let beforeCommit: (@Sendable (ThreadSnapshot) throws -> Void)?
    private var workers: [URL: Task<ThreadStoreWorker, any Error>] = [:]

    init(root: URL = StoreLocation.root, schemaVersion: Int = schemaVersion, inMemory: Bool = false, beforeCommit: (@Sendable (ThreadSnapshot) throws -> Void)? = nil) {
        self.root = root
        version = schemaVersion
        self.inMemory = inMemory
        self.beforeCommit = beforeCommit
    }

    private func worker(host: URL) async throws -> ThreadStoreWorker {
        if let task = workers[host] { return try await task.value }
        let task = Task { [root, version, inMemory] in
            try await Self.makeWorker(root: root, host: host, version: version, inMemory: inMemory)
        }
        workers[host] = task
        do { return try await task.value }
        catch {
            workers[host] = nil
            throw error
        }
    }

    @concurrent private static func makeWorker(root: URL, host: URL, version: Int,
                                               inMemory: Bool) async throws -> ThreadStoreWorker {
        let directory = StoreLocation.directory(root: root, host: host).appending(path: "cache")
        let manager = FileManager.default
        if !inMemory {
            StoreLocation.excludeFromBackup(root)
            let marker = directory.appending(path: "schema")
            let previous = try? String(contentsOf: marker, encoding: .utf8)
            if previous != String(version), manager.fileExists(atPath: directory.path) {
                CallLog.log(.store, "wipe reason=schema")
                try manager.removeItem(at: directory)
            }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(String(version).utf8).write(to: marker, options: .atomic)
        }
        let schema = Schema([CachedThreadEntity.self, CachedStreamCursor.self])
        let configuration = inMemory
            ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            : ModelConfiguration(schema: schema, url: directory.appending(path: "threads.store"), cloudKitDatabase: .none)
        let container: ModelContainer
        do { container = try ModelContainer(for: schema, configurations: configuration) }
        catch {
            guard !inMemory else { throw error }
            CallLog.log(.store, "wipe reason=container")
            try manager.removeItem(at: directory)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(String(version).utf8).write(to: directory.appending(path: "schema"), options: .atomic)
            container = try ModelContainer(for: schema, configurations: configuration)
        }
        return ThreadStoreWorker(modelContainer: container)
    }

    func load(host: URL, deviceId: String) async throws -> ThreadSnapshot {
        let worker = try await worker(host: host)
        do { return try await worker.load(deviceId: deviceId) }
        catch is DecodingError {
            CallLog.log(.store, "wipe reason=decode")
            try await worker.clear(deviceId: deviceId)
            return ThreadSnapshot()
        }
    }
    func save(_ snapshot: ThreadSnapshot, host: URL, deviceId: String) async throws {
        let began = ContinuousClock.now
        let worker = try await worker(host: host)
        try await worker.save(snapshot, deviceId: deviceId, beforeCommit: beforeCommit)
        CallLog.log(.store, "save cursor=\(snapshot.cursor) count=\(snapshot.entities.count + snapshot.conversations.count) ms=\(CallLog.ms(since: began))")
    }
    func clear(host: URL, deviceId: String) async throws {
        try await worker(host: host).clear(deviceId: deviceId)
    }
}

@ModelActor actor ThreadStoreWorker {
    func load(deviceId: String) throws -> ThreadSnapshot {
        let records = try modelContext.fetch(FetchDescriptor<CachedThreadEntity>(
            predicate: #Predicate { $0.deviceId == deviceId }, sortBy: [SortDescriptor(\.order)]))
        let cursor = try modelContext.fetch(FetchDescriptor<CachedStreamCursor>(
            predicate: #Predicate { $0.deviceId == deviceId })).first
        var result = ThreadSnapshot(cursor: cursor?.cursor)
        if let data = cursor?.historyFloors { result.historyFloors = try JSONDecoder().decode([String: Int64].self, from: data) }
        let decoder = JSONDecoder()
        let stale = Set(records.filter { $0.kind == "unknown" }.map(\.conversationId))
        for record in records {
            if record.kind == "conversation" {
                result.conversations.append(try decoder.decode(Conversation.self, from: record.json))
            } else if stale.contains(record.conversationId) {
                modelContext.delete(record)
            } else {
                result.entities.append(try decoder.decode(ThreadEntity.self, from: record.json))
            }
        }
        if !stale.isEmpty {
            result.historyFloors = result.historyFloors.filter { !stale.contains($0.key) }
            do {
                cursor?.historyFloors = try JSONEncoder().encode(result.historyFloors)
                try modelContext.save()
            } catch {
                modelContext.rollback()
                throw error
            }
        }
        return result
    }

    func save(_ snapshot: ThreadSnapshot, deviceId: String, beforeCommit: (@Sendable (ThreadSnapshot) throws -> Void)? = nil) throws {
        modelContext.autosaveEnabled = false
        do {
            if snapshot.replacesCache { try deleteRecords(deviceId: deviceId) }
            let encoder = JSONEncoder()
            if let allowed = snapshot.allowedConversations.map(Array.init) {
                for row in try modelContext.fetch(FetchDescriptor<CachedThreadEntity>(predicate: #Predicate {
                    $0.deviceId == deviceId && !allowed.contains($0.conversationId)
                })) { modelContext.delete(row) }
            }
            typealias Row = (id: String, conversationId: String, kind: String, order: Int64, seq: Int64, value: any Encodable)
            var rows: [Row] = snapshot.conversations.map { ($0.id, $0.id, "conversation", 0, $0.seq, $0) }
            for entity in snapshot.entities {
                switch entity {
                case .message(let value): rows.append((value.id, value.conversationId, "message", value.order, value.seq, entity))
                case .question(let value): rows.append((value.id, value.conversationId, "question", value.order, value.seq, entity))
                case .unknown:
                    if let key = entity.identity { rows.append((key.id, key.conversationId, "unknown", key.order, key.seq, entity)) }
                }
            }
            let device = StoreLocation.digest(deviceId)
            let keys = rows.map { CachedThreadEntity.key(device: device, kind: $0.kind, entityId: $0.id) }
            // One fetch for the whole batch instead of one per row.
            var existing = Dictionary(try modelContext.fetch(FetchDescriptor<CachedThreadEntity>(
                predicate: #Predicate { keys.contains($0.key) })).map { ($0.key, $0) }) { first, _ in first }
            for (key, row) in zip(keys, rows) {
                if let record = existing[key] {
                    guard row.seq > record.seq || (row.seq == record.seq && record.kind == "unknown" && row.kind != "unknown") else { continue }
                    record.kind = row.kind
                    record.json = try encoder.encode(row.value)
                    record.seq = row.seq
                    record.order = row.order
                    record.conversationId = row.conversationId
                } else {
                    let record = CachedThreadEntity(deviceId: deviceId, entityId: row.id, conversationId: row.conversationId,
                        order: row.order, seq: row.seq, kind: row.kind, json: try encoder.encode(row.value))
                    modelContext.insert(record)
                    existing[key] = record
                }
            }
            let cursor = try modelContext.fetch(FetchDescriptor<CachedStreamCursor>(
                predicate: #Predicate { $0.deviceId == deviceId })).first
            if let cursor {
                if snapshot.hasCursor { cursor.cursor = max(cursor.cursor ?? 0, snapshot.cursor) }
                var floors = try cursor.historyFloors.map { try JSONDecoder().decode([String: Int64].self, from: $0) } ?? [:]
                floors.merge(snapshot.historyFloors) { _, new in new }
                cursor.historyFloors = try encoder.encode(floors)
            } else if snapshot.hasCursor || !snapshot.historyFloors.isEmpty {
                let record = CachedStreamCursor(deviceId: deviceId, cursor: snapshot.hasCursor ? snapshot.cursor : nil)
                record.historyFloors = try encoder.encode(snapshot.historyFloors)
                modelContext.insert(record)
            }
            try beforeCommit?(snapshot)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func clear(deviceId: String) throws {
        modelContext.autosaveEnabled = false
        do {
            try deleteRecords(deviceId: deviceId)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
    private func deleteRecords(deviceId: String) throws {
        for row in try modelContext.fetch(FetchDescriptor<CachedThreadEntity>(predicate: #Predicate { $0.deviceId == deviceId })) {
            modelContext.delete(row)
        }
        for row in try modelContext.fetch(FetchDescriptor<CachedStreamCursor>(predicate: #Predicate { $0.deviceId == deviceId })) {
            modelContext.delete(row)
        }
    }
}
