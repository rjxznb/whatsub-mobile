import UIKit
import Vision

/// Thin wrapper over three Apple Vision requests run in parallel against a
/// single image:
///
///  1. `VNClassifyImageRequest` — top-K scene/object labels (Apple's
///     ImageNet-class taxonomy, ~1303 categories). Free, on-device, ~10ms.
///  2. `VNDetectHumanRectanglesRequest` — counts visible people.
///  3. `VNDetectAnimalRectanglesRequest` — counts visible cats + dogs.
///
/// No image bytes ever leave the device — the classifier output (just
/// label strings + counts) is what later feeds the LLM prompt-derivation
/// call. App Review tends to ask about "is the photo uploaded"; the answer
/// is "no, only the OCR-style text summary is".
///
/// 2026-06-05 (实景口语练习).
struct SceneClassifier {

    /// Confidence floor for `VNClassifyImageRequest` results. 0.3 strikes
    /// a balance: lower would let "white" / "rectangle" / "object" sneak
    /// in (bad signal for prompt writing); higher cuts useful breadth on
    /// busy scenes. Tunable here without prompt regeneration.
    private static let labelConfidenceFloor: Float = 0.3

    /// Max number of labels handed to the prompt LLM. Top-8 keeps the
    /// LLM input compact + matches what a human describer would mentally
    /// inventory ("bicycle, brick wall, sunlight, two people, …").
    private static let labelTopK: Int = 8

    /// Returns a `SceneContext` or a Chinese error string on failure.
    /// Runs on a background queue (Vision handler is sync + CPU-bound);
    /// callers should `await` from the main actor.
    static func classify(_ image: UIImage) async -> SceneClassifyOutcome {
        guard let cgImage = image.cgImage else {
            return .failure("无法读取图片")
        }
        let orientation = cgOrientation(from: image.imageOrientation)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = performRequests(cgImage: cgImage, orientation: orientation)
                continuation.resume(returning: result)
            }
        }
    }

    private static func performRequests(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) -> SceneClassifyOutcome {
        let classify = VNClassifyImageRequest()
        let humans = VNDetectHumanRectanglesRequest()
        // VNRecognizeAnimalsRequest (NOT VNDetectAnimalRectangles —
        // that's a name I hallucinated; CI 26990209830 caught it).
        // iOS 13+, returns VNRecognizedObjectObservation per spotted
        // cat/dog; we use .count only — bounding boxes + species labels
        // are inside the results but we don't need them for prompt-gen.
        let animals = VNRecognizeAnimalsRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
        do {
            try handler.perform([classify, humans, animals])
        } catch {
            return .failure("图像识别失败:\(error.localizedDescription)")
        }

        let labels: [SceneLabel] = (classify.results ?? [])
            .filter { $0.confidence >= labelConfidenceFloor }
            .prefix(labelTopK)
            .map { SceneLabel(identifier: $0.identifier, confidence: $0.confidence) }

        let humanCount = humans.results?.count ?? 0
        let animalCount = animals.results?.count ?? 0

        // Empty labels + zero humans + zero animals = Vision saw nothing
        // confidently. Almost always means the photo was too dark or
        // featureless (closeup of a wall, blurry). Tell the user instead
        // of silently shipping a void context to the LLM (which would
        // then hallucinate a prompt about "an empty scene").
        if labels.isEmpty && humanCount == 0 && animalCount == 0 {
            return .failure("画面里没有识别出明显的物体或人,换一张试试")
        }

        return .success(SceneContext(
            labels: labels,
            humanCount: humanCount,
            animalCount: animalCount
        ))
    }

    /// `UIImage.imageOrientation` → `CGImagePropertyOrientation` mapping.
    /// Vision needs the latter to interpret pixels correctly when the
    /// image came from the camera in landscape/upside-down. Same table
    /// `PhotoOCR.swift` uses; would be worth extracting to a shared
    /// helper if a third caller shows up.
    private static func cgOrientation(from ui: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch ui {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
