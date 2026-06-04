import SwiftUI
import PhotosUI

/// Gallery picker via SwiftUI's native `PhotosPicker` (iOS 16+).
/// Mirrors `PhotoCameraPicker`'s binding shape — sets `image` on
/// successful load, nil on cancel. Use as a `.photosPicker(...)`
/// attached to whichever button surfaces it.
///
/// We DON'T use this as a standalone view; the parent attaches
/// `.photosPicker(isPresented:, selection:)` directly. This file just
/// hosts the helper that converts `PhotosPickerItem -> UIImage`.
///
/// 2026-06-04 (拍照识别短语).
enum PhotoLibraryPicker {

    /// Resolve the picker's selected item into a UIImage. Returns nil
    /// on any error (cancellation, corrupted asset, unsupported format).
    /// The caller decides whether nil is a silent dismiss or a user-
    /// visible error.
    @MainActor
    static func resolve(_ item: PhotosPickerItem?) async -> UIImage? {
        guard let item else { return nil }
        do {
            // `loadTransferable` is the modern, sandbox-friendly path —
            // no need to request photo-library permission for read-only
            // access to the user-picked asset.
            if let data = try await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data) {
                return img
            }
        } catch {
            // Silent — caller decides UI.
        }
        return nil
    }
}
