import Foundation

/// Downloads the en_US-ljspeech-medium Piper voice files to
/// Application Support/tts-model/ljspeech/. Three files, total ~64MB.
/// Pure URLSession; no API key needed.
///
/// 2026-06-04 host strategy: try `hf-mirror.com` (HuggingFace's
/// China-friendly mirror, sub-second start in mainland China) FIRST,
/// fall back to `huggingface.co` (canonical source, needed when the
/// mirror is down or the user is on a network where it's blocked).
/// Each file tries hosts in order; first 2xx wins. The fallback
/// happens silently — the user sees one progress bar.
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

    /// Hosts to try IN ORDER for each file. hf-mirror is GFW-friendly
    /// (in-China users would otherwise be stuck on HF being unreachable);
    /// huggingface.co is the canonical fallback for everywhere else +
    /// the rare case the mirror has gaps.
    private let mirrorHosts: [String] = [
        "https://hf-mirror.com",
        "https://huggingface.co",
    ]

    /// Path under each mirror host (same on both — hf-mirror is a 1:1
    /// path-preserving proxy of huggingface.co).
    private let modelRepoPath = "/csukuangfj/vits-piper-en_US-ljspeech-medium/resolve/main"

    /// Files to download. `approxBytes` only drives the progress bar UI.
    private let files: [(name: String, approxBytes: Int64)] = [
        ("en_US-ljspeech-medium.onnx", 64_000_000),
        ("tokens.txt", 1_000),
        ("en_US-ljspeech-medium.onnx.json", 5_000),
    ]

    /// Root dir for Piper voices. Lazy-created on first access.
    /// nonisolated so PiperTTS can read it from a background queue without
    /// hopping to MainActor every inference.
    nonisolated static var modelRootDir: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tts-model")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    nonisolated static var ljspeechDir: URL {
        modelRootDir.appendingPathComponent("ljspeech")
    }

    init() {
        // Check at init whether files already exist (idempotent re-launch).
        if Self.isLjspeechReady() { status = .ready }
    }

    /// Synchronous read: all 3 ljspeech files exist on disk.
    /// nonisolated for the same reason as modelRootDir above.
    nonisolated static func isLjspeechReady() -> Bool {
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

        for file in files {
            // Try each mirror host in priority order; first 2xx wins.
            // Errors from earlier hosts are remembered only so the final
            // user-visible message can name the LAST attempt's reason.
            var lastError: String?
            var saved = false
            for host in mirrorHosts {
                let urlString = "\(host)\(modelRepoPath)/\(file.name)"
                guard let url = URL(string: urlString) else {
                    lastError = "URL 解析失败：\(urlString)"
                    continue
                }
                do {
                    let (tempURL, response) = try await URLSession.shared.download(from: url)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                        lastError = "HTTP \(code) — \(host)"
                        continue
                    }
                    let dest = dir.appendingPathComponent(file.name)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                    if let size = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64 {
                        receivedBytes += size
                    }
                    let progress = min(1.0, Double(receivedBytes) / Double(totalApproxBytes))
                    status = .downloading(progress: progress)
                    saved = true
                    break
                } catch {
                    lastError = "\(error.localizedDescription) (\(host))"
                    continue
                }
            }
            if !saved {
                status = .error("下载失败 — \(file.name) — \(lastError ?? "所有镜像源都不可达")")
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
