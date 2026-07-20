import Foundation

/// Heuristic "is a VPN tunnel active?" check for a regular (non-NetworkExtension)
/// app. iOS exposes no direct API, but `CFNetworkCopySystemProxySettings`'s
/// `__SCOPED__` dictionary lists per-interface proxy scopes — packet-tunnel
/// VPNs surface there as utun*/tun*/tap*/ppp*/ipsec* interfaces. Standard
/// App-Store-safe heuristic; used only to decide whether to SHOW the VPN
/// split-routing guidance, so a false positive costs one dismissible sheet.
enum VPNDetector {
    /// Pure classification over interface names — unit-testable without
    /// touching system state.
    static func containsVPNInterface<S: Sequence>(_ interfaceNames: S) -> Bool where S.Element == String {
        let prefixes = ["utun", "tun", "tap", "ppp", "ipsec"]
        return interfaceNames.contains { name in
            let lower = name.lowercased()
            return prefixes.contains { lower.hasPrefix($0) }
        }
    }

    /// Live check against the system proxy scopes.
    static func isVPNActive() -> Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
              let scoped = settings["__SCOPED__"] as? [String: Any] else {
            return false
        }
        return containsVPNInterface(scoped.keys)
    }
}
