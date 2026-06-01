import Foundation

/// Phase 1.1 stub. This file's purpose: get the linker to actually pull in
/// sherpa-onnx + onnxruntime symbols so we know the XCFramework integration
/// works. Phase 1.2 will replace this with the real TTS wrapper (model
/// download, generate, audio playback, etc.).
///
/// We construct a config struct but DO NOT invoke any inference — that
/// requires bundled model + espeak-ng-data which Phase 1.2 will add.
enum PiperTTS {

    /// Returns true iff the sherpa-onnx XCFramework symbols are linked into
    /// the running app. Internally constructs (but doesn't free) a config
    /// struct using the C API. Result is cached on first call.
    private static var _linked: Bool?
    static var isFrameworkLinked: Bool {
        if let cached = _linked { return cached }
        // Calling sherpaOnnxOfflineTtsVitsModelConfig with empty strings is
        // safe — it allocates a value type and returns it. We never pass it
        // to a constructor that actually loads files.
        let vits = sherpaOnnxOfflineTtsVitsModelConfig(
            model: "", lexicon: "", tokens: "", dataDir: ""
        )
        // If the linker dead-stripped sherpa-onnx, this constructor wouldn't
        // even compile. Reaching here = framework symbols are present.
        let _ = vits.model     // touch a field so the optimizer can't elide it
        _linked = true
        return true
    }
}
