import CryptoKit
import Foundation

public enum PairedAgentID {
    /// Saved shortcuts name an agent by this id, so it hashes the host's key: a respelled host keeps its ids.
    public static func make(host: URL, agentId: String) -> UUID {
        let host = PairedHost.key(host)
        // Length-prefix the host so boundaries cannot alias agent ids containing separators.
        let digest = SHA256.hash(data: Data("\(host.utf8.count):\(host)\(agentId)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
