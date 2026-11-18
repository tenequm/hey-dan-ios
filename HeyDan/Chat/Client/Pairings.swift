import AppIntents
import Foundation
import HeyDanCore
import Observation
import UIKit

@MainActor @Observable final class Pairings {
    static let shared = Pairings()
    enum State { case unreadable, none, paired }
    struct Entry: Codable, Sendable {
        let host: URL
        let deviceId: String
        let userName: String
        let agents: [Agent]
        var pairing: PairResponse {
            PairResponse(deviceId: deviceId, userName: userName, agents: agents, protocol: 1, serverTime: 0)
        }
        /// The host's `hello` features as last seen: refreshed on each connect, so every gate follows the server.
        var features: [String]
        init(host: URL, pairing: PairResponse, features: [String]) {
            self.host = host; self.deviceId = pairing.deviceId; self.userName = pairing.userName
            self.agents = pairing.agents; self.features = features
        }
    }
    private struct Saved: Codable {
        var entries: [String: Entry] = [:]
        var active: String?
    }
    private(set) var state: State = .unreadable
    private var saved = Saved()
    private(set) var error: AppError?
    private var pairingInFlight = false
    private var fixture = false
    private var publishedIdentity: String?
    private let publishes: Bool
    private let account: String
    #if DEBUG
    var isFixture: Bool { fixture }
    #endif
    var entries: [Entry] { saved.entries.values.sorted { $0.host.absoluteString < $1.host.absoluteString } }
    var active: Entry? { saved.active.flatMap { saved.entries[$0] } }

    init(account: String = "pairings", publishes: Bool = true) {
        self.account = account
        self.publishes = publishes
        #if DEBUG
        if ProcessInfo.processInfo.environment["HEYDAN_FIXTURE_CHAT"] == "1" {
            fixture = true
            let host = URL(string: "https://app.example.com")!
            saved.entries[host.absoluteString] = Entry(host: host, pairing: FixtureAppService.pairing,
                features: ["files", "calls", "push", "voice-picker"])
            saved.active = host.absoluteString
            state = .paired
            Task { @MainActor in publish() }
            return
        }
        #endif
        Task { @MainActor in reload() }
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.protectedDataDidBecomeAvailableNotification) {
                if self?.state == .unreadable { self?.reload() }
            }
        }
        #if DEBUG
        if publishes, let link = ProcessInfo.processInfo.environment["HEYDAN_PAIR_LINK"] {
            Task { do { try await pair(link) } catch { self.error = AppError.map(error) } }
        }
        #endif
    }
    private func reload() {
        do {
            if let data = try IdentityKeychain.load(account: account) {
                saved = try JSONDecoder().decode(Saved.self, from: data)
            } else { saved = Saved() }
            error = nil
            publish()
        } catch is DecodingError {
            saved = Saved(); error = nil
            CallLog.log(.net, "pairings invalid_saved_data")
            publish()
        } catch { state = .unreadable; self.error = .keyUnavailable }
    }
    private func publish() {
        if publishes { HeyDanShortcuts.updateAppShortcutParameters() }
        state = active == nil ? .none : .paired
        let identity = active.map { $0.host.absoluteString + "|" + $0.pairing.deviceId }
        guard publishes, identity != publishedIdentity else { return }
        publishedIdentity = identity
        ChatController.shared.selectPairing(active?.pairing,
            host: active?.host ?? URL(string: "https://app.example.com")!)
    }
    private func commit(_ next: Saved) throws(AppError) {
        guard state != .unreadable else { throw .keyUnavailable }
        if !fixture {
            do { try IdentityKeychain.save(JSONEncoder().encode(next), account: account) }
            catch { throw .keyUnavailable }
        }
        saved = next
        publish()
    }
    func add(_ pairing: PairResponse, host: URL, features: [String]) throws(AppError) {
        var next = saved
        next.entries[host.absoluteString] = Entry(host: host, pairing: pairing, features: features)
        next.active = host.absoluteString
        try commit(next)
    }
    func refreshFeatures(_ features: [String], host: URL) {
        guard var entry = saved.entries[host.absoluteString], entry.features != features else { return }
        entry.features = features
        var next = saved
        next.entries[host.absoluteString] = entry
        do { try commit(next) } catch { CallLog.log(.store, "pairings features_failed \(error.logName)") }
    }
    func setActive(host: URL) throws(AppError) {
        guard saved.entries[host.absoluteString] != nil else { throw .notPaired }
        var next = saved
        next.active = host.absoluteString
        try commit(next)
    }
    /// Removes the pairing only while it is still this device's: a host paired again meanwhile keeps its new pairing.
    func remove(host: URL, deviceId: String) throws(AppError) {
        guard saved.entries[host.absoluteString]?.deviceId == deviceId else { return }
        var next = saved
        next.entries.removeValue(forKey: host.absoluteString)
        if next.active == host.absoluteString { next.active = next.entries.keys.sorted().first }
        try commit(next)
        if !fixture { try DeviceKey().remove(host: host) }
    }
    func pair(_ text: String, configuration: URLSessionConfiguration = .ephemeral) async throws {
        guard !fixture else { throw PairingFailure.fixture }
        guard !pairingInFlight else { throw PairingFailure.busy }
        guard state != .unreadable else { throw AppError.keyUnavailable }
        #if DEBUG
        let allowsLocal = true
        #else
        let allowsLocal = false
        #endif
        guard let link = PairingLink(text, allowsLocalNetworking: allowsLocal) else { throw PairingFailure.invalidLink }
        pairingInFlight = true
        defer { pairingInFlight = false }
        let client = SignedClient(host: link.baseURL, configuration: configuration)
        let hello = try await client.hello()
        guard hello.minProtocol <= 1 && hello.protocol >= 1 else { throw PairingFailure.protocolMismatch }
        let key = DeviceKey()
        let pending = URL(string: link.baseURL.absoluteString + "#pending")!
        try key.remove(host: pending)
        try key.create(host: pending)
        do {
            let publicKey = SigningText.base64url(try key.publicKey(host: pending))
            let proof = try key.sign(Data(SigningText.pairProof(code: link.code, publicKey: publicKey).utf8), host: pending)
            let request = PairRequest(code: link.code, publicKey: publicKey, deviceName: UIDevice.current.name,
                proof: SigningText.base64url(proof), app: AppVersion(
                    version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                    build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
                    os: UIDevice.current.systemVersion))
            let pairing = try await client.pair(request)
            do {
                let previous = try IdentityKeychain.load(account: link.baseURL.absoluteString)
                guard let blob = try IdentityKeychain.load(account: pending.absoluteString) else { throw AppError.keyUnavailable }
                try IdentityKeychain.save(blob, account: link.baseURL.absoluteString)
                do { try add(pairing, host: link.baseURL, features: hello.features) }
                catch {
                    if let previous { try? IdentityKeychain.save(previous, account: link.baseURL.absoluteString) }
                    else { try? key.remove(host: link.baseURL) }
                    throw error
                }
            } catch {
                // The host already made the device: unpair it with the pending key, or nothing could ever remove it.
                try? await SignedClient(host: link.baseURL, deviceId: pairing.deviceId, configuration: configuration,
                    signer: { bytes, _ in try key.sign(bytes, host: pending) }).unpair()
                throw error
            }
            try? key.remove(host: pending)
            CallLog.log(.net, "pair ok")
        } catch {
            try? key.remove(host: pending)
            CallLog.log(.net, "pair failed \(AppError.map(error).logName)")
            throw error
        }
    }
}

enum PairingFailure: Error, LocalizedError {
    case invalidLink, protocolMismatch, busy, fixture
    var errorDescription: String? {
        switch self {
        case .busy: "Pairing is already in progress."
        case .fixture: "Pairing is unavailable in fixture mode."
        case .invalidLink: "Paste a valid pairing link."
        case .protocolMismatch: "This host requires a different app version. Update the app and try again."
        }
    }
}
