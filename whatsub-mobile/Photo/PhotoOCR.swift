import Foundation
import UIKit
import Vision

/// On-device English OCR via Apple's Vision framework. Zero network,
/// zero cost, works offline. Same primitive that powers Live Text on
/// iOS 15+. We use `.accurate` recognition with language correction so
/// pasted-paper / signage shots come out cleanly; user-editable text
/// area in the review screen handles the residual misreads.
///
/// 2026-06-04 (拍照识别短语).
enum PhotoOCR {

    /// Run OCR on one UIImage. Returns the recognized lines + the joined
    /// full text. Errors thrown from Vision (camera permission denied
    /// mid-call, image conversion failure) are bubbled up so the view
    /// can surface them cleanly.
    static func recognize(_ image: UIImage) async throws -> Result {
        // Vision wants a CGImage. We also use the image's imageOrientation
        // so portrait shots aren't recognized sideways.
        guard let cg = image.cgImage else { throw OCRError.noCGImage }

        return try await withCheckedThrowingContinuation { cont in
            let req = VNRecognizeTextRequest { req, err in
                if let err {
                    cont.resume(throwing: err)
                    return
                }
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                let lines: [String] = observations.compactMap { obs in
                    let candidate = obs.topCandidates(1).first?.string
                    let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (trimmed?.isEmpty == false) ? trimmed : nil
                }
                cont.resume(returning: Result(lines: lines))
            }

            req.recognitionLevel = .accurate
            req.recognitionLanguages = ["en-US"]
            req.usesLanguageCorrection = true
            // Minimum text height (relative). 0 = no minimum. We leave
            // it at the default to catch small text in signage shots.

            let handler = VNImageRequestHandler(
                cgImage: cg,
                orientation: cgImagePropertyOrientation(from: image.imageOrientation),
                options: [:]
            )
            do {
                try handler.perform([req])
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    struct Result {
        /// One string per recognized line, in reading order.
        let lines: [String]

        /// Lines joined with `\n` for display + LLM input. Each line is
        /// already trimmed.
        var fullText: String { lines.joined(separator: "\n") }
    }

    enum OCRError: Error, LocalizedError {
        case noCGImage
        var errorDescription: String? {
            switch self {
            case .noCGImage: return "图片解码失败，请换一张试试"
            }
        }
    }

    /// UIImage.Orientation → CGImagePropertyOrientation. UIKit and
    /// CGImage use different orientation enums; without this conversion
    /// portrait shots are recognized as rotated 90° and Vision returns
    /// garbage.
    private static func cgImagePropertyOrientation(
        from o: UIImage.Orientation
    ) -> CGImagePropertyOrientation {
        switch o {
        case .up:            return .up
        case .upMirrored:    return .upMirrored
        case .down:          return .down
        case .downMirrored:  return .downMirrored
        case .left:          return .left
        case .leftMirrored:  return .leftMirrored
        case .right:         return .right
        case .rightMirrored: return .rightMirrored
        @unknown default:    return .up
        }
    }
}
