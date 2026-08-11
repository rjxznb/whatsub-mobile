import Foundation
import CryptoKit

@MainActor
final class ImportViewModel: ObservableObject {

    enum State {
        case idle
        case extracting
        /// Streaming AI analysis. `cueCount` lets the UI render a time
        /// estimate ("约 1 分钟") in addition to the live done/total bar.
        case analyzing(done: Int, total: Int, cueCount: Int)
        /// BYOK paused safely between requests because the app is backgrounded.
        case byokPaused(done: Int, total: Int, cueCount: Int)
        case submittingManaged
        /// Durable server-side analysis. Closing the sheet does not cancel it.
        case managedJob(ManagedAnalysisJob)
        case managedPolicy(ManagedAnalysisPolicy)
        case preview
        case syncing
        case done
        case error(String)
        /// Caption extraction failed — push to desktop is available. `debug`
        /// is the extractor's per-step event log surfaced via the
        /// 「查看诊断」 button so users can self-triage instead of guessing
        /// (or sending us a screenshot of a one-line error).
        case extractFailed(message: String, debug: [String])
        case pushing
        /// URL successfully enqueued to the backend import queue.
        /// `desktopOffline` = the backend hasn't seen the user's desktop
        /// client touch the queue recently (poll cadence is 30s; we warn
        /// past 120s) — the success screen shows a prominent "打开桌面端"
        /// reminder so the task doesn't sit in the queue unnoticed forever.
        case pushedToDesktop(desktopOffline: Bool)
        /// A non-YouTube source (Bilibili / other) that has no client-side
        /// caption path — offer to push it to the desktop queue.
        case needsDesktop(message: String)
        /// Push blocked by the OSS-video quota cap. Carries used/limit for display
        /// + the license-holder upsell.
        case quotaWall(used: Int, limit: Int)
    }

    @Published var state: State = .idle
    @Published private(set) var diagnosticReport: AnalysisDiagnosticReport?

    /// The in-flight extract→analyse→sync run. Owned here (not created ad-hoc
    /// by the View) so dismissing the import sheet can actually CANCEL it.
    /// Before 2026-07-20 the View spawned a detached `Task {}`: closing the
    /// sheet only tore down the UI while the run kept going and auto-synced a
    /// cloud entry the user believed they'd cancelled — silently consuming one
    /// of the 3 free video slots.
    private var workTask: Task<Void, Never>?
    private var runGeneration = 0
    private var managedAttemptID: String?
    private var managedAttemptFingerprint: String?

    typealias CaptionExtractor = (
        _ videoId: String,
        _ onProgress: @MainActor @escaping (String) -> Void
    ) async throws -> CaptionExtractionResult
    typealias LocalAnalyzer = (
        _ cues: [Cue],
        _ durationSec: Double?,
        _ settings: LlmSettings,
        _ resume: AnalysisResumeContext,
        _ onProgress: @escaping (Int, Int) -> Void,
        _ onDiagnostic: @escaping (AnalysisStreamEvent) -> Void
    ) async throws -> AnalysisJson

    private let managedClient: ManagedAnalysisClientProtocol
    private let entitlementRefresher: (String) async -> ManagedEntitlementState
    private let settingsProvider: () -> LlmSettings
    private let captionExtractor: CaptionExtractor
    private let titleFetcher: (String) async -> String?
    private let thumbnailFetcher: (String) async -> String?
    private let durationRefresher: (String) async throws -> Int?
    private let localAnalyzer: LocalAnalyzer
    private let checkpointStore: AnalysisCheckpointStore
    private let noProgressWait: () async throws -> Void
    private let byokRequestGate = BYOKRequestGate()
    private var byokCheckpointLease: BYOKCheckpointLease?
    private var byokPaused = false

    init(
        managedClient: ManagedAnalysisClientProtocol = WhatsubAPI.shared,
        entitlementRefresher: @escaping (String) async -> ManagedEntitlementState = { token in
            do {
                let me = try await WhatsubAPI.shared.me(token: token)
                guard let active = me.hasActiveSubscription else { return .unknown }
                return active ? .freshPro : .freshFree
            } catch {
                return .unknown
            }
        },
        settingsProvider: @escaping () -> LlmSettings = { LlmSettingsStore.load() },
        captionExtractor: @escaping CaptionExtractor = { videoId, onProgress in
            try await YouTubeCaptionExtractor.extract(
                videoId: videoId,
                onProgress: onProgress
            )
        },
        titleFetcher: @escaping (String) async -> String? = { videoId in
            await ImportViewModel.fetchYouTubeTitle(videoId: videoId)
        },
        thumbnailFetcher: @escaping (String) async -> String? = { videoId in
            await ImportViewModel.fetchThumbBase64(videoId: videoId)
        },
        durationRefresher: @escaping (String) async throws -> Int? = { videoId in
            try await YouTubeCaptionExtractor.refreshDuration(videoId: videoId)
        },
        checkpointStore: AnalysisCheckpointStore = AnalysisCheckpointStore(),
        noProgressWait: @escaping () async throws -> Void = {
            try await Task.sleep(nanoseconds: 90_000_000_000)
        },
        localAnalyzer: @escaping LocalAnalyzer = { cues, durationSec, settings, resume, onProgress, onDiagnostic in
            let engine = AnalysisEngine(client: ChatCompletionsClient(settings: settings))
            return try await engine.analyze(
                cues,
                durationSec: durationSec,
                completedBatches: resume.completedBatches,
                completedSummary: resume.completedSummary,
                onBatchCompleted: resume.onBatchCompleted,
                onSummaryCompleted: resume.onSummaryCompleted,
                shouldBeginRequest: resume.shouldBeginRequest,
                onProgress: onProgress,
                onDiagnostic: onDiagnostic
            )
        }
    ) {
        self.managedClient = managedClient
        self.entitlementRefresher = entitlementRefresher
        self.settingsProvider = settingsProvider
        self.captionExtractor = captionExtractor
        self.titleFetcher = titleFetcher
        self.thumbnailFetcher = thumbnailFetcher
        self.durationRefresher = durationRefresher
        self.checkpointStore = checkpointStore
        self.noProgressWait = noProgressWait
        self.localAnalyzer = localAnalyzer
        try? checkpointStore.prune()
    }

    /// Start the full import run, replacing any previous one.
    func start(urlOrId: String, token: String, email: String? = nil) {
        deleteCurrentCheckpoint()
        workTask?.cancel()
        let generation = beginGeneration(newAttempt: true)
        workTask = Task { [weak self] in
            await self?.run(urlOrId: urlOrId, token: token, email: email, generation: generation)
        }
    }

    /// Start a re-run of JUST the analysis (error-screen retry button).
    func startRetryAnalysis(token: String) {
        workTask?.cancel()
        let generation = beginGeneration(newAttempt: false)
        workTask = Task { [weak self] in
            await self?.retryAnalysisOnly(token: token, generation: generation)
        }
    }

    func startRetryManaged(token: String, refreshDuration: Bool = false) {
        workTask?.cancel()
        let generation = beginGeneration(newAttempt: false)
        workTask = Task { [weak self] in
            await self?.retryManaged(
                token: token,
                refreshDuration: refreshDuration,
                generation: generation
            )
        }
    }

    /// Cancel whatever is running. Safe to call when nothing is.
    /// The extracted captions stay in the on-disk cache — that's harmless and
    /// makes a later re-import instant; only the network work stops.
    func cancelWork() {
        runGeneration += 1
        workTask?.cancel()
        workTask = nil
        byokPaused = false
        deleteCurrentCheckpoint()
    }

    /// Backgrounding does not cancel an in-flight BYOK request. The engine
    /// persists that batch, then observes this gate before opening the next
    /// request. Foregrounding resumes through the same serialized entry point.
    func setSceneActive(_ active: Bool, token: String?) {
        byokRequestGate.setActive(active)
        guard active, byokPaused, let token, !rawCues.isEmpty else { return }
        byokPaused = false
        workTask?.cancel()
        let generation = beginGeneration(newAttempt: false)
        workTask = Task { [weak self] in
            await self?.retryAnalysisOnly(token: token, generation: generation)
        }
    }

    /// Extracted + analysed result, set once analysis completes.
    private(set) var result: AnalysisJson?
    /// Raw extracted cues (pre-analysis); kept for SRT generation.
    private(set) var rawCues: [Cue] = []
    /// Authoritative YouTube player duration. Managed analysis must reject nil
    /// instead of inferring a policy duration from the final subtitle cue.
    private(set) var videoDurationSec: Int?
    private(set) var videoId: String = ""
    private(set) var title: String = ""
    private var accountEmail: String?
    /// The full YouTube watch URL entered/resolved by the user, kept so
    /// pushToDesktop can enqueue it without requiring UI re-entry.
    private(set) var resolvedSourceURL: String = ""

    private func beginGeneration(newAttempt: Bool) -> Int {
        runGeneration += 1
        if newAttempt {
            managedAttemptID = nil
            managedAttemptFingerprint = nil
        }
        return runGeneration
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == runGeneration
    }

    // MARK: - Step 1: Extract + Analyse

    func run(urlOrId: String, token: String, email: String? = nil) async {
        let generation = beginGeneration(newAttempt: true)
        await run(urlOrId: urlOrId, token: token, email: email, generation: generation)
    }

    private func run(
        urlOrId: String,
        token: String,
        email: String?,
        generation: Int
    ) async {
        guard isCurrent(generation), !Task.isCancelled else { return }
        // A sheet can reuse the same VM for another URL. Clear every value
        // tied to the previous import before any validation or routing branch,
        // so an early failure can never leak an old duration/result into the
        // next managed-analysis request.
        result = nil
        diagnosticReport = nil
        rawCues = []
        videoDurationSec = nil
        videoId = ""
        title = ""
        resolvedSourceURL = ""
        accountEmail = email

        let trimmed = urlOrId.trimmingCharacters(in: .whitespacesAndNewlines)

        // Non-YouTube URLs have no phone-side caption path (Bilibili CC is
        // Chinese/absent). Route straight to the desktop queue. A bare 11-char
        // YouTube id has no "://" → falls through to the YouTube path below.
        if trimmed.contains("://"), VideoSource.from(url: trimmed) != .youtube {
            resolvedSourceURL = trimmed
            videoId = ""
            title = trimmed
            state = .needsDesktop(message: "B站 / 其它来源无法在手机端取字幕，可推送到桌面端用 whisper 转录 + 解析（需桌面在线且登录同一账号）。")
            return
        }

        // Resolve video ID — accept a raw 11-char id or a full YouTube URL.
        let resolvedId: String
        if let fromURL = extractYouTubeID(trimmed) {
            resolvedId = fromURL
        } else if trimmed.count == 11, trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
            resolvedId = trimmed
        } else {
            state = .error("无法识别的 YouTube URL 或 ID")
            return
        }
        videoId = resolvedId
        title = resolvedId  // v1 fallback: use videoId as title
        resolvedSourceURL = "https://www.youtube.com/watch?v=\(resolvedId)"

        // Step 1: Extract captions.
        state = .extracting
        let extraction: CaptionExtractionResult
        // 2026-06-19: pure-Swift Innertube extractor — see spec
        // docs/superpowers/specs/2026-06-19-ios-innertube-captions-design.md.
        var debugLog: [String] = []
        do {
            extraction = try await captionExtractor(
                resolvedId,
                { event in debugLog.append(event) }
            )
        } catch {
            guard isCurrent(generation) else { return }
            state = .extractFailed(
                message: error.localizedDescription,
                debug: debugLog
            )
            return
        }
        guard isCurrent(generation), !Task.isCancelled else { return }
        rawCues = extraction.cues
        videoDurationSec = extraction.durationSec
        // Replace the videoId placeholder title with the real YouTube title
        // (best-effort; VPN is on during import so youtube.com oEmbed is reachable).
        let fetchedTitle = await titleFetcher(resolvedId)
        guard isCurrent(generation), !Task.isCancelled else { return }
        if let real = fetchedTitle, !real.isEmpty {
            title = real
        }

        // Step 2: Guard LLM configured.
        let settings = settingsProvider()
        guard settings.isConfigured else {
            state = .error("请先配置 LLM（我的 → LLM 设置）")
            return
        }

        // Step 3: Run AI analysis + auto-sync. Per user feedback
        // 2026-06-21: drop the manual "开始 AI 解析" + "同步到云库"
        // confirmation steps — once captions are extracted the user's
        // intent is obviously to land the entry in the cloud library.
        // Two manual taps were friction without value.
        if settings.useManagedRelay {
            await submitManagedAnalysis(token: token, generation: generation)
        } else {
            await performAnalysis(rawCues, token: token, generation: generation)
        }
    }

    /// Re-run JUST the LLM analysis on the in-memory `rawCues`. Used by
    /// the error-screen「重试 AI 解析」button so a network-stage failure
    /// (VPN routing, key issue, etc.) doesn't force the user back through
    /// URL input + caption extraction. If somehow rawCues is empty (e.g.,
    /// after a process restart), falls back to .idle so the URL screen
    /// shows up.
    func retryAnalysisOnly(token: String) async {
        let generation = beginGeneration(newAttempt: false)
        await retryAnalysisOnly(token: token, generation: generation)
    }

    private func retryAnalysisOnly(token: String, generation: Int) async {
        guard isCurrent(generation), !Task.isCancelled else { return }
        guard !rawCues.isEmpty else {
            state = .idle
            return
        }
        let settings = settingsProvider()
        if settings.useManagedRelay {
            await submitManagedAnalysis(token: token, generation: generation)
        } else {
            await performAnalysis(rawCues, token: token, generation: generation)
        }
    }

    func retryManagedSubmission(token: String, refreshDuration: Bool = false) async {
        let generation = beginGeneration(newAttempt: false)
        await retryManaged(
            token: token,
            refreshDuration: refreshDuration,
            generation: generation
        )
    }

    private func retryManaged(
        token: String,
        refreshDuration: Bool,
        generation: Int
    ) async {
        guard isCurrent(generation), !Task.isCancelled else { return }
        guard !rawCues.isEmpty else { state = .idle; return }
        if refreshDuration {
            state = .submittingManaged
            do {
                let refreshedDuration = try await durationRefresher(videoId)
                guard isCurrent(generation), !Task.isCancelled else { return }
                videoDurationSec = refreshedDuration
            } catch {
                guard isCurrent(generation) else { return }
                state = .managedPolicy(.durationUnknown)
                return
            }
        }
        guard isCurrent(generation) else { return }
        await submitManagedAnalysis(token: token, generation: generation)
    }

    private func submitManagedAnalysis(token: String, generation: Int) async {
        guard isCurrent(generation), !Task.isCancelled else { return }
        guard let duration = videoDurationSec, duration > 0 else {
            state = .managedPolicy(.durationUnknown)
            return
        }
        let entitlement = await entitlementRefresher(token)
        guard isCurrent(generation), !Task.isCancelled else { return }
        if entitlement == .freshFree, duration > 1_200 {
            state = .managedPolicy(.videoTooLong(duration: duration, limit: 1_200))
            return
        }

        let cues = rawCues.map(ManagedAnalysisCue.init(cue:))
        state = .submittingManaged
        let request = ManagedAnalysisCreateRequest(
            idempotencyKey: managedIdempotencyKey(duration: duration, cues: cues),
            youtubeId: videoId,
            sourceUrl: resolvedSourceURL,
            title: title,
            durationSec: duration,
            cues: cues,
            transcriptSrt: buildSRT(from: rawCues),
            thumbData: await thumbnailFetcher(videoId)
        )
        let encodedRequestBytes = (try? JSONEncoder().encode(request).count) ?? 0
        guard isCurrent(generation), !Task.isCancelled else { return }
        do {
            let job = try await managedClient.createJob(request, token: token)
            guard isCurrent(generation) else { return }
            if job.status == .failed || job.status == .cancelled {
                rotateManagedAttempt()
            }
            if #available(iOS 16.2, *),
               job.status != .cancelled,
               let email = accountEmail {
                let terminal = job.status == .completed || job.status == .failed || job.status == .cancelled
                let initial = ImportActivityAttributes.ContentState(
                    inProgress: terminal ? 0 : 1,
                    completed: job.status == .completed ? 1 : 0,
                    failed: job.status == .failed ? 1 : 0,
                    recentTitle: title,
                    recentEntryId: job.resultEntryId
                )
                await LiveActivityCoordinator.shared.ensureActivity(
                    forUserEmail: email,
                    initialState: initial
                )
            }
            state = .managedJob(job)
        } catch is CancellationError {
            if isCurrent(generation) { state = .idle }
        } catch let error as ManagedAnalysisClientError {
            if isCurrent(generation) {
                if case let .server(status, code, diagnosticCode, diagnosticId) = error {
                    diagnosticReport = .managed(
                        request: request,
                        encodedBytes: encodedRequestBytes,
                        status: status,
                        code: code,
                        diagnosticCode: diagnosticCode,
                        diagnosticId: diagnosticId
                    )
                }
                state = managedState(for: error, duration: duration)
            }
        } catch {
            if isCurrent(generation) { state = .error(error.localizedDescription) }
        }
    }

    private func managedState(
        for error: ManagedAnalysisClientError,
        duration: Int
    ) -> State {
        switch error {
        case .durationUnknown: return .managedPolicy(.durationUnknown)
        case .videoTooLong: return .managedPolicy(.videoTooLong(duration: duration, limit: 1_200))
        case .freeUsedUp: return .managedPolicy(.freeUsedUp)
        case .quotaExceeded: return .managedPolicy(.quotaExceeded)
        case .upstreamUnavailable: return .managedPolicy(.upstreamUnavailable)
        case .serverBusy: return .managedPolicy(.serverBusy)
        case .queueLimit: return .managedPolicy(.queueLimit)
        case .unauthorized: return .error("登录信息已过期，请重新登录。")
        case .network(let detail): return .error("网络连接失败：\(detail)")
        case .notFound, .invalidState, .invalidResponse, .server:
            return .error("后台解析任务提交失败，请稍后重试。")
        }
    }

    private func managedIdempotencyKey(
        duration: Int,
        cues: [ManagedAnalysisCue]
    ) -> String {
        var input = Data("\(videoId)\u{0}\(duration)\u{0}".utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let encoded = try? encoder.encode(cues) { input.append(encoded) }
        let digest = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        return "ios-\(attemptID(for: digest))-\(digest)"
    }

    private func attemptID(for fingerprint: String) -> String {
        if managedAttemptFingerprint == fingerprint, let managedAttemptID {
            return managedAttemptID
        }
        let key = "managed-analysis-attempt.\(fingerprint)"
        let stored = UserDefaults.standard.string(forKey: key)
        let attempt = stored ?? UUID().uuidString.lowercased()
        if stored == nil { UserDefaults.standard.set(attempt, forKey: key) }
        managedAttemptFingerprint = fingerprint
        managedAttemptID = attempt
        return attempt
    }

    private func rotateManagedAttempt() {
        let attempt = UUID().uuidString.lowercased()
        managedAttemptID = attempt
        if let fingerprint = managedAttemptFingerprint {
            UserDefaults.standard.set(
                attempt,
                forKey: "managed-analysis-attempt.\(fingerprint)"
            )
        }
    }

    func cancelManagedJob(token: String) async {
        guard case .managedJob(let current) = state,
              current.status != .completed,
              current.status != .failed,
              current.status != .cancelled else { return }
        do {
            let cancelled = try await managedClient.cancel(id: current.jobId, token: token)
            rotateManagedAttempt()
            state = .managedJob(cancelled)
        } catch is CancellationError {
            // The user left while the explicit cancellation request was in flight.
        } catch {
            state = .error("取消后台解析失败，请稍后再试。")
        }
    }

    private func performAnalysis(_ cues: [Cue], token: String, generation: Int) async {
        guard isCurrent(generation), !Task.isCancelled else { return }
        let settings = settingsProvider()
        guard settings.isConfigured else {
            state = .error("请先配置 LLM（我的 → LLM 设置）")
            return
        }
        let cueCount = cues.count
        let durationSec = videoDurationSec.map(Double.init)
        state = .analyzing(done: 0, total: 1, cueCount: cueCount)
        let progressSnapshot = AnalysisProgressSnapshot()
        let diagnosticTracker = AnalysisStreamDiagnosticTracker()
        progressSnapshot.update(done: 0, total: cues.count + 1)
        do {
            byokCheckpointLease?.invalidate {}
            let checkpointLease = BYOKCheckpointLease()
            byokCheckpointLease = checkpointLease
            var checkpoint = try checkpointStore.load(sourceID: videoId, cues: cues)
                ?? checkpointStore.makeCheckpoint(sourceID: videoId, cues: cues)
            let resume = AnalysisResumeContext(
                completedBatches: checkpoint.completedBatches,
                completedSummary: checkpoint.completedSummary,
                onBatchCompleted: { [checkpointStore] index, result in
                    try checkpointLease.withValid {
                        try checkpoint.recordBatch(index: index, result: result, sourceCues: cues)
                        try checkpointStore.save(checkpoint)
                    }
                },
                onSummaryCompleted: { [checkpointStore] summary in
                    try checkpointLease.withValid {
                        checkpoint.recordSummary(summary)
                        try checkpointStore.save(checkpoint)
                    }
                },
                shouldBeginRequest: { [byokRequestGate] in
                    byokRequestGate.canBeginRequest()
                }
            )
            enum RaceResult {
                case analysis(AnalysisJson)
                case timeout
            }
            let analysis = try await withThrowingTaskGroup(of: RaceResult.self) { group in
                group.addTask { [localAnalyzer] in
                    let value = try await localAnalyzer(
                        cues,
                        durationSec,
                        settings,
                        resume,
                        { [weak self] done, total in
                            progressSnapshot.update(done: done, total: total)
                            Task { @MainActor [weak self] in
                                guard let self,
                                      self.isCurrent(generation),
                                      !self.byokPaused else { return }
                                self.state = .analyzing(done: done, total: total, cueCount: cueCount)
                            }
                        },
                        { event in diagnosticTracker.record(event) }
                    )
                    return .analysis(value)
                }
                group.addTask { [noProgressWait] in
                    try await noProgressWait()
                    return .timeout
                }
                while let result = try await group.next() {
                    switch result {
                    case .analysis(let value):
                        group.cancelAll()
                        return value
                    case .timeout:
                        let latest = diagnosticTracker.snapshot()
                        if latest.parsedCues == 0 {
                            group.cancelAll()
                            throw BYOKNoProgressTimeoutError(event: latest)
                        }
                    }
                }
                throw CancellationError()
            }
            guard isCurrent(generation) else { return }
            result = analysis
            // Cancelled while the last chunk was in flight? Then the sheet is
            // already gone — do NOT upload. This is the check that keeps a
            // "cancelled" import out of the user's cloud library + quota.
            try Task.checkCancellation()
            // Auto-sync immediately on analysis success — user requested
            // removal of the preview/sync confirmation step.
            await sync(token: token, generation: generation)
        } catch let timeout as BYOKNoProgressTimeoutError {
            guard isCurrent(generation) else { return }
            let host = URL(string: settings.baseUrl)?.host ?? "unknown"
            diagnosticReport = .byok(
                stage: timeout.event.stage,
                elapsedSeconds: 90,
                providerHost: host,
                model: settings.model,
                batch: timeout.event.batch,
                parsedCues: timeout.event.parsedCues
            )
            state = .error("AI 解析 90 秒仍未收到可解析字幕，已停止等待。请复制诊断信息发给客服。")
        } catch is AnalysisPausedError {
            guard isCurrent(generation) else { return }
            // Foreground may have won the race after the engine observed the
            // closed gate but before this MainActor catch ran. Continue now;
            // otherwise no later scenePhase edge would exist to wake the job.
            if byokRequestGate.canBeginRequest() {
                await performAnalysis(cues, token: token, generation: generation)
                return
            }
            byokPaused = true
            workTask = nil
            let progress = progressSnapshot.read()
            state = .byokPaused(
                done: progress.done,
                total: progress.total,
                cueCount: cueCount
            )
        } catch is CancellationError {
            // User closed the sheet. No error UI: nothing is on screen, and
            // the next open should start clean rather than land on a stale
            // failure page.
            if isCurrent(generation) { state = .idle }
        } catch {
            // Captions stay in memory (rawCues) so the error-screen retry
            // skips straight back to performAnalysis. The hint differs by
            // mode: relay users hit eversay.cc (suspect VPN MITM); BYOK
            // users hit their LLM vendor directly (suspect baseUrl /
            // model / key).
            let base = error.localizedDescription
            let hint: String
            if settings.useManagedRelay {
                hint = "\n\n字幕仍在内存里，点「重试 AI 解析」会跳过字幕抓取直接重跑 AI。最快恢复：关 VPN 后点重试。一劳永逸：见底部「VPN 规则」。"
            } else {
                hint = "\n\n字幕仍在内存里，点「重试 AI 解析」可以重试。报「200」通常是 baseUrl 或 model 名不对——检查「我的 → LLM 设置」里 baseUrl 是否带 `/v1` 后缀（DeepSeek 是 `https://api.deepseek.com/v1`）、model 是 `deepseek-chat` 之类厂商支持的型号。"
            }
            if isCurrent(generation) { state = .error(base + hint) }
        }
    }

    /// Fetch the real video title via YouTube oEmbed (best-effort; nil on any failure).
    private static func fetchYouTubeTitle(videoId: String) async -> String? {
        var comps = URLComponents(string: "https://www.youtube.com/oembed")
        comps?.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoId)"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = comps?.url,
              let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String else { return nil }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Step 1b: Push caption-less URL to desktop import queue

    /// Directly enqueue an entered/shared URL to the desktop queue (the explicit
    /// "推送到桌面" choice — bypasses on-phone caption extraction).
    /// `email` (when available) is forwarded to `pushToDesktop` so it can start
    /// the Live Activity scoped to that user. Optional — Live Activity is
    /// best-effort; without an email we still enqueue normally.
    func pushURL(_ urlOrId: String, token: String, email: String? = nil) async {
        let trimmed = urlOrId.trimmingCharacters(in: .whitespacesAndNewlines)
        resolvedSourceURL = trimmed.contains("://")
            ? trimmed
            : (VideoSource.isLikelyYouTubeId(trimmed) ? "https://www.youtube.com/watch?v=\(trimmed)" : trimmed)
        await pushToDesktop(token: token, email: email)
    }

    func pushToDesktop(token: String, email: String? = nil) async {
        let url = resolvedSourceURL.isEmpty ? "https://www.youtube.com/watch?v=\(videoId)" : resolvedSourceURL
        state = .pushing
        do {
            let seenSecondsAgo = try await WhatsubAPI.shared.enqueueImport(url: url, token: token)
            // Start (or refresh) the Live Activity for the import queue so the
            // user has lock-screen / Dynamic Island visibility into desktop
            // processing. Best-effort — Activity failure means the in-app
            // queue view still works. Done BEFORE the state transition so
            // the lock-screen card appears in the same tick the success UI
            // does.
            // iOS 16.2+ guard: ActivityKit is unavailable on 16.0.
            if #available(iOS 16.2, *) {
                if let email = email {
                    let initial = ImportActivityAttributes.ContentState(
                        inProgress: 1,
                        completed: 0,
                        failed: 0,
                        recentTitle: title
                    )
                    await LiveActivityCoordinator.shared.ensureActivity(
                        forUserEmail: email,
                        initialState: initial
                    )
                }
            }
            // Desktop poll cadence is 30s — not seen for 120s (4 missed
            // polls) or never seen ⇒ treat as offline. nil also covers an
            // old backend without the field: we then show the softer copy
            // only when we KNOW the desktop was just alive.
            let offline = seenSecondsAgo == nil || seenSecondsAgo! > 120
            state = .pushedToDesktop(desktopOffline: offline)
        } catch APIError.quotaExceeded(let used, let limit) {
            state = .quotaWall(used: used, limit: limit)
        } catch let e as APIError {
            state = .error(e.chinese)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Step 2: Sync to cloud

    func sync(token: String) async {
        await sync(token: token, generation: runGeneration)
    }

    private func sync(token: String, generation: Int) async {
        guard isCurrent(generation), !Task.isCancelled else { return }
        guard let analysis = result else {
            state = .error("没有分析结果，请重新导入")
            return
        }
        state = .syncing

        let srt = buildSRT(from: rawCues)
        let sourceUrl = "https://www.youtube.com/watch?v=\(videoId)"
        // Fetch the YouTube cover now (VPN is on for the import) + ship it as
        // thumbData so the backend serves a China-reachable thumbnail — the
        // imported video then shows a cover in the Library list WITHOUT VPN.
        let thumbData = await thumbnailFetcher(videoId)
        guard isCurrent(generation), !Task.isCancelled else { return }

        do {
            try await WhatsubAPI.shared.syncLibraryEntry(
                youtubeId: videoId,
                sourceUrl: sourceUrl,
                title: title,
                durationSec: videoDurationSec,
                transcriptSrt: srt,
                analysis: analysis,
                thumbData: thumbData,
                token: token
            )
            guard isCurrent(generation) else { return }
            deleteCurrentCheckpoint()
            state = .done
        } catch {
            if isCurrent(generation) { state = .error(error.localizedDescription) }
        }
    }

    /// Best-effort: fetch the YouTube cover (mqdefault.jpg) + base64. Returns nil
    /// on any failure (entry falls back to the i.ytimg URL, VPN-only).
    private static func fetchThumbBase64(videoId: String) async -> String? {
        guard let url = URL(string: "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg") else { return nil }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else { return nil }
            return data.base64EncodedString()
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private func buildSRT(from cues: [Cue]) -> String {
        cues.enumerated().map { (i, cue) in
            let start = srtTimestamp(cue.time)
            let end = srtTimestamp(cue.endTime)
            return "\(i + 1)\n\(start) --> \(end)\n\(cue.text)"
        }.joined(separator: "\n\n")
    }

    private func srtTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let ms = Int((seconds - Double(total)) * 1000)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    private func deleteCurrentCheckpoint() {
        guard !videoId.isEmpty, !rawCues.isEmpty else { return }
        let sourceID = videoId
        let cues = rawCues
        if let lease = byokCheckpointLease {
            lease.invalidate { [checkpointStore] in
                checkpointStore.delete(sourceID: sourceID, cues: cues)
            }
            byokCheckpointLease = nil
        } else {
            checkpointStore.delete(sourceID: sourceID, cues: cues)
        }
    }
}
