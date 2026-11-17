import Foundation
import HeyDanCore

/// H3 replaces this unavailable store with a background SwiftData model actor.
actor SwiftDataThreadStore: ThreadStore {
    enum StoreError: Error { case unavailable }
    func load(host: URL, deviceId: String) async throws -> ThreadSnapshot { throw StoreError.unavailable }
    func save(_ snapshot: ThreadSnapshot, host: URL, deviceId: String) async throws { throw StoreError.unavailable }
    func clear(host: URL, deviceId: String) async throws { throw StoreError.unavailable }
}
