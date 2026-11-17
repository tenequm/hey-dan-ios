import CryptoKit
import Foundation
import Security

struct DeviceKey: Sendable {
    func create(host: URL) throws(AppError) {
        guard try IdentityKeychain.load(account: host.absoluteString) == nil else { return }
        do {
            guard let access = SecAccessControlCreateWithFlags(nil,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, nil) else {
                throw AppError.keyUnavailable
            }
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            try IdentityKeychain.save(key.dataRepresentation, account: host.absoluteString)
        } catch { throw .keyUnavailable }
    }

    private func key(host: URL) throws(AppError) -> SecureEnclave.P256.Signing.PrivateKey {
        guard let data = try IdentityKeychain.load(account: host.absoluteString) else { throw .notPaired }
        do { return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data) }
        catch { throw .keyUnavailable }
    }

    func publicKey(host: URL) throws(AppError) -> Data { try key(host: host).publicKey.derRepresentation }
    func sign(_ bytes: Data, host: URL) throws(AppError) -> Data {
        do { return try key(host: host).signature(for: bytes).derRepresentation }
        catch let error as AppError { throw error }
        catch { throw .keyUnavailable }
    }
    func remove(host: URL) throws(AppError) { try IdentityKeychain.remove(account: host.absoluteString) }
}

enum IdentityKeychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.tenequm.HeyDan.identity",
         kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true]
    }
    static func load(account: String) throws(AppError) -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw .keyUnavailable }
        return data
    }
    static func save(_ data: Data, account: String) throws(AppError) {
        let query = query(account)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
        guard status == errSecSuccess else { throw .keyUnavailable }
    }
    static func remove(account: String) throws(AppError) {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .keyUnavailable }
    }
}
