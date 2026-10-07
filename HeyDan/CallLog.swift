import Foundation
import HeyDanCore
import LiveKit
import os

/// The app's log: subsystem = the app's bundle ID, one category per area. Every line is `.public` because it is built
/// only from ids, states, codes and durations, never a call-link token, a URL, a room token or anything said.
/// Lifecycle lines are `.notice`, which iOS keeps; DEBUG builds also append every line to Library/Caches/heydan.log,
/// which keeps debug lines too, survives a relaunch and can be copied off the phone (`just device-logs`).
enum CallLog {
    enum Category: String, CaseIterable, Sendable {
        case call, callkit, audio, net, room, rpc, stream, store, intent, activity
    }

    static let subsystem = Bundle.main.bundleIdentifier ?? "HeyDan"

    private static let loggers = Dictionary(
        uniqueKeysWithValues: Category.allCases.map { ($0, Logger(subsystem: subsystem, category: $0.rawValue)) }
    )

    static func log(_ category: Category, _ message: String, level: OSLogType = .default) {
        loggers[category]?.log(level: level, "\(message, privacy: .public)")
        #if DEBUG
        mirror(category, message, level)
        #endif
    }

    /// An error as its type and code only: a URL loading error carries the request URL, and with it the token.
    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as URLError: "URLError(\(error.code.rawValue))"
        case let error as LiveKitError: "LiveKitError(\(error.type))"
        case let error as RpcError: "RpcError(\(error.code))"
        case let error as CallFailure: "CallFailure(\(error.logName))"
        default: "\((error as NSError).domain)(\((error as NSError).code))"
        }
    }

    static func ms(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    #if DEBUG
    private static let file = OSAllocatedUnfairLock<FileHandle?>(initialState: {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "heydan.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }())

    private static func mirror(_ category: Category, _ message: String, _ level: OSLogType) {
        let tag = switch level {
        case .error, .fault: "E"
        case .debug: "D"
        case .info: "I"
        default: "N"
        }
        let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(tag) \(category.rawValue) \(message)\n"
        file.withLock { _ = try? $0?.write(contentsOf: Data(line.utf8)) }
    }
    #endif
}
