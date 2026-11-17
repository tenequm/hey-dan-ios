import Foundation
import HeyDanCore

/// H2 owns Secure Enclave keys and per-host pairing persistence.
struct DeviceKey: Sendable {
    func publicKey(host: URL) throws(AppError) -> Data { throw .transport(.unavailable) }
    func sign(_ bytes: Data, host: URL) throws(AppError) -> Data { throw .transport(.unavailable) }
    func remove(host: URL) throws(AppError) { throw .transport(.unavailable) }
}
