import Foundation

/// Downloads the en_US-ljspeech-medium Piper voice files from HuggingFace
/// to Application Support/tts-model/ljspeech/. Three files, total ~64MB.
/// Pure URLSession; no API key needed; stable HF URLs.
@MainActor
final class PiperModelDownloader: ObservableObject {

    static let shared = PiperModelDownloader()

    enum Status: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case ready
        case error(String)
    }

    @Published private(set) var status: Status = .notDownloaded

    /// Files to download. Order matters only for the progress UI.
    /// URLs are pinned to the resolve/main branch of csukuangfj's HF repo,
    /// which is the canonical sherpa-onnx model mirror.
    private let files: [(url: String, name: String, approxBytes: Int64)] = [
        ("https://huggingface.co/csukuangfj/vits-piper-en_US-ljspeech-medium/resolve/main/en_US-ljspeech-medium.onnx",
         "en_US-ljspeech-medium.onnx", 64_000_000),
        ("https://huggingface.co/csukuangfj/vits-piper-en_US-ljspeech-medium/resolve/main/tokens.txt",
         "tokens.txt", 1_000),
        ("https://huggingface.co/csukuangfj/vits-piper-en_US-ljspeech-medium/resolve/main/en_US-ljspeech-medium.onnx.json",
         "en_US-ljspeech-medium.onnx.json", 5_000),
    ]

    /// Root dir for Piper voices. Lazy-created on first access.
    static var modelRootDir: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tts-model")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static var ljspeechDir: URL {
        modelRootDir.appendingPathComponent("ljspeech")
    }

    init() {
        // Check at init whether files already exist (idempotent re-launch).
        if Self.isLjspeechReady() { status = .ready }
    }

    /// Synchronous read: all 3 ljspeech files exist on disk.
    static func isLjspeechReady() -> Bool {
        let dir = ljspeechDir
        let required = [
            "en_US-ljspeech-medium.onnx",
            "tokens.txt",
            "en_US-ljspeech-medium.onnx.json",
        ]
        return required.allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    /// Triggers the download. Updates @Published status as it progresses.
    func download() async {
        if Self.isLjspeechReady() { status = .ready; return }
        let dir = Self.ljspeechDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let totalApproxBytes = files.reduce(0) { $0 + $1.approxBytes }
        var receivedBytes: Int64 = 0
        status = .downloading(progress: 0)

        for (urlString, name, _) in files {
            guard let url = URL(string: urlString) else {
                status = .error("URL 解析失败：\(urlString)")
                return
            }
            do {
                let (tempURL, response) = try await URLSession.shared.download(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    status = .error("下载失败 (HTTP \(code)) - \(name)")
                    return
                }
                let dest = dir.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tempURL, to: dest)
                if let size = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64 {
                    receivedBytes += size
                }
                let progress = min(1.0, Double(receivedBytes) / Double(totalApproxBytes))
                status = .downloading(progress: progress)
            } catch {
                status = .error("下载失败：\(error.localizedDescription)")
                return
            }
        }
        status = .ready
    }

    func deleteModel() {
        try? FileManager.default.removeItem(at: Self.ljspeechDir)
        status = .notDownloaded
    }
}
