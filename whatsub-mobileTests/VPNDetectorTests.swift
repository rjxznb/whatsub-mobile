import XCTest
@testable import whatsub_mobile

final class VPNDetectorTests: XCTestCase {
    func testTunnelInterfacesDetected() {
        // utunN is what packet-tunnel VPNs (Shadowrocket/Clash/WireGuard…)
        // register on iOS; the others cover legacy PPTP/L2TP/IPSec shapes.
        XCTAssertTrue(VPNDetector.containsVPNInterface(["en0", "utun2"]))
        XCTAssertTrue(VPNDetector.containsVPNInterface(["tun0"]))
        XCTAssertTrue(VPNDetector.containsVPNInterface(["tap1"]))
        XCTAssertTrue(VPNDetector.containsVPNInterface(["ppp0"]))
        XCTAssertTrue(VPNDetector.containsVPNInterface(["ipsec0"]))
        XCTAssertTrue(VPNDetector.containsVPNInterface(["UTUN3"])) // case-insensitive
    }

    func testNormalInterfacesNotDetected() {
        // en0 = WiFi, pdp_ip0 = cellular, lo0 = loopback, awdl0 = AirDrop —
        // all present WITHOUT any VPN; must not trigger the guidance.
        XCTAssertFalse(VPNDetector.containsVPNInterface(["en0", "pdp_ip0", "lo0", "awdl0"]))
        XCTAssertFalse(VPNDetector.containsVPNInterface([]))
        // "untunneled" contains "tun" but doesn't START with a VPN prefix.
        XCTAssertFalse(VPNDetector.containsVPNInterface(["untunneled0"]))
    }
}
