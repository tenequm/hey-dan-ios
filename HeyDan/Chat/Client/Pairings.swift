import Foundation
import HeyDanCore
import Observation
import UIKit

@MainActor @Observable final class Pairings {
    static let shared = Pairings()
    enum State { case unreadable, none, paired }
    struct Entry: Codable, Sendable {
        let host: URL
        let pairing: PairResponse
        let features: [String]
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
    var entries: [Entry] { saved.entries.values.sorted { $0.host.absoluteString < $1.host.absoluteString } }
    var active: Entry? { saved.active.flatMap { saved.entries[$0] } }

    private init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["HEYDAN_FIXTURE_CHAT"] == "1" {
            fixture = true
            let host = URL(string: "https://app.opx.one")!
            saved.entries[host.absoluteString] = Entry(host: host, pairing: FixtureAppService.pairing,
                features: ["files", "calls", "push", "voice-picker"])
            saved.active = host.absoluteString
            publish()
            return
        }
        #endif
        reload()
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.protectedDataDidBecomeAvailableNotification) {
                self?.reload()
            }
        }
        #if DEBUG
        if let link = ProcessInfo.processInfo.environment["HEYDAN_PAIR_LINK"] {
            Task { do { try await pair(link) } catch { self.error = AppError.map(error) } }
        }
        #endif
    }
    private func reload() {
        do {
            if let data = try IdentityKeychain.load(account: "pairings") {
                saved = try JSONDecoder().decode(Saved.self, from: data)
            } else { saved = Saved() }
            error = nil
            publish()
        } catch { state = .unreadable; self.error = .keyUnavailable }
    }
    private func publish() {
        state = active == nil ? .none : .paired
        ChatController.shared.selectPairing(active?.pairing,
            host: active?.host ?? URL(string: "https://app.opx.one")!)
    }
    private func commit(_ next: Saved) throws(AppError) {
        guard state != .unreadable else { throw .keyUnavailable }
        if !fixture {
            do { try IdentityKeychain.save(JSONEncoder().encode(next), account: "pairings") }
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
    func setActive(host: URL) throws(AppError) {
        guard saved.entries[host.absoluteString] != nil else { throw .notPaired }
        var next = saved
        next.active = host.absoluteString
        try commit(next)
    }
    func remove(host: URL) throws(AppError) {
        var next = saved
        next.entries.removeValue(forKey: host.absoluteString)
        if next.active == host.absoluteString { next.active = next.entries.keys.sorted().first }
        try commit(next)
        if !fixture { try DeviceKey().remove(host: host) }
    }
    func pair(_ text: String) async throws {
        guard !pairingInFlight else { return }
        guard state != .unreadable else { throw AppError.keyUnavailable }
        #if DEBUG
        let allowsLocal = true
        #else
        let allowsLocal = false
        #endif
        guard let link = PairingLink(text, allowsLocalNetworking: allowsLocal) else { throw PairingFailure.invalidLink }
        let alreadyPaired = saved.entries[link.baseURL.absoluteString] != nil
        pairingInFlight = true
        defer { pairingInFlight = false }
        let client = SignedClient(host: link.baseURL)
        let hello = try await client.hello()
        guard hello.minProtocol <= 1 && hello.protocol >= 1 else { throw PairingFailure.protocolMismatch }
        let key = DeviceKey()
        if !alreadyPaired { try key.create(host: link.baseURL) }
        do {
            let publicKey = SigningText.base64url(try key.publicKey(host: link.baseURL))
            let proof = try key.sign(Data(SigningText.pairProof(code: link.code, publicKey: publicKey).utf8), host: link.baseURL)
            let request = PairRequest(code: link.code, publicKey: publicKey, deviceName: UIDevice.current.name,
                proof: SigningText.base64url(proof), app: AppVersion(
                    version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                    build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
                    os: UIDevice.current.systemVersion))
            let pairing = try await client.pair(request)
            try add(pairing, host: link.baseURL, features: hello.features)
        } catch {
            if !alreadyPaired { try key.remove(host: link.baseURL) }
            throw error
        }
    }
}

enum PairingFailure: Error, LocalizedError {
    case invalidLink, protocolMismatch
    var errorDescription: String? {
        switch self {
        case .invalidLink: "Paste a valid pairing link."
        case .protocolMismatch: "This host requires a different app version. Update the app and try again."
        }
    }
}
