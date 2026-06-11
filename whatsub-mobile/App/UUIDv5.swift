import Foundation
import CryptoKit

extension UUID {
    /// RFC 4122 UUIDv5 (SHA-1, name-based).
    ///
    /// We use this to derive a deterministic per-account `appAccountToken`
    /// that StoreKit stamps onto every IAP transaction (`Product.PurchaseOption
    /// .appAccountToken(uuid)`). Apple includes that token in the signed JWS
    /// the iOS app forwards to our backend AND in every App Store Server
    /// Notification (ASSN) about the same transaction.
    ///
    /// Why deterministic: if the iOS app's POST /api/license/iap/verify ever
    /// fails to reach our server (network blip, OCSP timeout, anything),
    /// Apple's later ASSN INITIAL_BUY / DID_RENEW notifications still arrive
    /// at our /api/license/iap/notifications webhook — and the backend can
    /// reverse the appAccountToken in the notification back to a whatSub
    /// email via the iap_account_tokens table, so the purchase still gets
    /// credited on the canonical server side. Without this hook, ASSN gives
    /// us only the originalTransactionId, which we have no way to attribute
    /// to a whatSub account if `/verify` never ran.
    ///
    /// Namespace UUID is a stable random constant — see
    /// `StoreManager.whatsubIAPNamespace`.
    static func v5(name: String, namespace: UUID) -> UUID {
        // namespace UUID bytes (16) || name UTF-8 bytes → SHA-1 → first 16 bytes
        // → set version (4 high bits of byte 6) and variant (2 high bits of byte 8)
        var nsTuple = namespace.uuid
        let nsBytes = withUnsafeBytes(of: &nsTuple) { Data($0) }
        let nameBytes = Data(name.utf8)
        let digest = Insecure.SHA1.hash(data: nsBytes + nameBytes)

        var bytes = [UInt8](digest)
        // Truncate to 16 (SHA-1 yields 20)
        bytes = Array(bytes.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5 in top 4 bits
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // variant DCE-1.1 in top 2 bits

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
