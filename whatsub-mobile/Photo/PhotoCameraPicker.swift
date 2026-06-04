import SwiftUI
import UIKit

/// Camera capture via the venerable `UIImagePickerController`. Wrapped
/// in a `UIViewControllerRepresentable` so SwiftUI can present it as a
/// sheet. Returns `UIImage?` via the binding — nil when the user
/// cancels.
///
/// Why not AVCaptureSession or DataScannerViewController? Simpler is
/// better here:
///   - AVCaptureSession needs a custom preview + tap-to-capture UI;
///     that's a Phase 2 polish.
///   - DataScannerViewController gives live text overlay but is iOS
///     16+ only AND captures TEXT (not a still image), forcing a
///     parallel code path. We want one OCR pipeline that works
///     identically for camera + gallery.
///
/// 2026-06-04 (拍照识别短语).
struct PhotoCameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let vc = UIImagePickerController()
        vc.sourceType = .camera
        // Front cam by default? No — text is almost always on the rear-
        // facing world side. Skip device-availability check; if camera
        // isn't available the controller falls back to .photoLibrary
        // automatically.
        vc.cameraDevice = .rear
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject,
                              UIImagePickerControllerDelegate,
                              UINavigationControllerDelegate {
        let parent: PhotoCameraPicker
        init(_ parent: PhotoCameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            // .editedImage is set only when allowsEditing=true; we want the
            // full resolution shot for OCR so go for .originalImage.
            let img = info[.originalImage] as? UIImage
            parent.image = img
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.image = nil
            picker.dismiss(animated: true)
        }
    }
}

/// True only when the device has a usable camera. iPad simulators
/// without a camera return false; in that case the entry sheet hides
/// the 📷 拍照 button and the user must use the gallery picker.
var deviceHasCamera: Bool {
    UIImagePickerController.isSourceTypeAvailable(.camera)
}
