import Foundation

struct LlmSettingsPresentation: Equatable {
    let availableModes: [LlmMode]
    let showsAPIKeyFields: Bool
    let showsModePicker: Bool

    init(entitlements: LlmEntitlements?, storedMode: LlmMode) {
        let modes = LlmEntitlementPolicy.allowedModes(for: entitlements)
        availableModes = modes
        showsModePicker = modes.count > 1
        showsAPIKeyFields = storedMode == .byok && modes.contains(.byok)
    }
}
