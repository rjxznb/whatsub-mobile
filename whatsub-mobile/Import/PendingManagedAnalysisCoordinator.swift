import Foundation

/// App-owned retry loop for managed-analysis submissions that reached a
/// temporarily saturated server. Its lifetime is independent of ImportView:
/// closing the sheet only stops observing the result, not the accepted intent.
actor PendingManagedAnalysisCoordinator {
    enum Resolution: Equatable {
        case accepted(requestID: String, ownerEmail: String, job: ManagedAnalysisJob)
        case failed(requestID: String, ownerEmail: String, error: ManagedAnalysisClientError)
        case cancelled(requestID: String, ownerEmail: String)
    }

    static let shared = PendingManagedAnalysisCoordinator(
        client: WhatsubAPI.shared,
        store: .shared
    )

    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void
    typealias Clock = @Sendable () -> Date

    private struct Account: Equatable {
        let token: String
        let email: String
    }

    private let client: any ManagedAnalysisClientProtocol
    private let store: PendingManagedAnalysisStore
    private let sleeper: Sleeper
    private let now: Clock
    private var account: Account?
    private var runner: Task<Void, Never>?
    private var generation = 0
    private var activeSubmissionKeys: Set<String> = []
    private var cancelledSubmissionKeys: Set<String> = []
    private var waiters: [
        String: [UUID: CheckedContinuation<Resolution, Never>]
    ] = [:]
    private var recent: [String: Resolution] = [:]
    private var recentOrder: [String] = []

    init(
        client: any ManagedAnalysisClientProtocol,
        store: PendingManagedAnalysisStore,
        now: @escaping Clock = { Date() },
        sleeper: @escaping Sleeper = { seconds in
            try await Task.sleep(
                nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)
            )
        }
    ) {
        self.client = client
        self.store = store
        self.now = now
        self.sleeper = sleeper
    }

    @discardableResult
    func enqueue(
        request: ManagedAnalysisCreateRequest,
        ownerEmail: String,
        retryAfterSeconds: Int?,
        token: String
    ) async throws -> PendingManagedAnalysisSubmission {
        let owner = normalized(ownerEmail)
        let pending = try await store.enqueue(
            request: request,
            ownerEmail: owner,
            retryAfterSeconds: retryAfterSeconds,
            at: now()
        )
        activate(token: token, email: owner)
        return pending
    }

    func activate(token: String, email: String) {
        let next = Account(token: token, email: normalized(email))
        if account != next {
            generation += 1
            runner = nil
            account = next
        }
        startRunnerIfNeeded()
    }

    func deactivate() {
        generation += 1
        runner = nil
        account = nil
    }

    func waitForResolution(
        requestID: String,
        ownerEmail: String
    ) async -> Resolution {
        let owner = normalized(ownerEmail)
        let key = resolutionKey(requestID: requestID, ownerEmail: owner)
        if let cached = recent.removeValue(forKey: key) {
            recentOrder.removeAll { $0 == key }
            return cached
        }
        let cancelled = Resolution.cancelled(
            requestID: requestID,
            ownerEmail: owner
        )
        guard !Task.isCancelled else { return cancelled }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: cancelled)
                } else {
                    waiters[key, default: [:]][waiterID] = continuation
                }
            }
        } onCancel: { [weak self] in
            Task {
                await self?.cancelWaiter(
                    key: key,
                    waiterID: waiterID,
                    resolution: cancelled
                )
            }
        }
    }

    func cancel(requestID: String, ownerEmail: String) async {
        let owner = normalized(ownerEmail)
        let key = resolutionKey(requestID: requestID, ownerEmail: owner)
        // If POST /jobs is already in flight, do not cancel its URLSession
        // task: the server may have accepted it before the response reaches
        // us. Keep a tombstone so the returned jobId is cancelled instead.
        if activeSubmissionKeys.contains(key) {
            cancelledSubmissionKeys.insert(key)
        }
        // A sleeping runner is invalidated by generation and exits before POST.
        // It is deliberately not Task.cancelled because that same Task may
        // already be inside the accepted-response race described above.
        let shouldRestart = account?.email == owner
        if shouldRestart {
            generation += 1
            runner = nil
        }
        try? await store.remove(
            requestID: requestID,
            ownerEmail: owner,
            at: now()
        )
        if shouldRestart {
            startRunnerIfNeeded()
        }
        publish(.cancelled(requestID: requestID, ownerEmail: owner))
    }

    func discard(requestID: String, ownerEmail: String) async {
        try? await store.remove(
            requestID: requestID,
            ownerEmail: normalized(ownerEmail),
            at: now()
        )
    }

    func clear(ownerEmail: String) async {
        let owner = normalized(ownerEmail)
        // Stop this account before the first suspension. Otherwise the actor
        // can re-enter while store.all() waits and let the old runner submit
        // or reschedule after logout has started.
        if account?.email == owner {
            deactivate()
        }
        let pending = (try? await store.all(at: now()))?
            .filter { $0.ownerEmail == owner } ?? []
        try? await store.removeAll(ownerEmail: owner, at: now())
        for item in pending {
            publish(.cancelled(requestID: item.requestID, ownerEmail: owner))
        }
    }

    private func startRunnerIfNeeded() {
        guard runner == nil, let account else { return }
        generation += 1
        let expectedGeneration = generation
        runner = Task { [weak self] in
            await self?.run(account: account, generation: expectedGeneration)
        }
    }

    private func run(account: Account, generation expectedGeneration: Int) async {
        defer {
            if generation == expectedGeneration {
                runner = nil
            }
        }

        while !Task.isCancelled,
              generation == expectedGeneration,
              self.account == account {
            let pending: PendingManagedAnalysisSubmission
            do {
                guard let next = try await store.next(
                    ownerEmail: account.email,
                    at: now()
                ) else { return }
                pending = next
            } catch {
                return
            }

            do {
                try await sleeper(max(0, pending.nextRetryAt.timeIntervalSince(now())))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  generation == expectedGeneration,
                  self.account == account else { return }

            let submissionKey = resolutionKey(
                requestID: pending.requestID,
                ownerEmail: account.email
            )
            activeSubmissionKeys.insert(submissionKey)
            do {
                let job = try await client.createJob(pending.request, token: account.token)
                activeSubmissionKeys.remove(submissionKey)
                if cancelledSubmissionKeys.remove(submissionKey) != nil {
                    _ = try? await client.cancel(id: job.jobId, token: account.token)
                    return
                }
                try? await store.remove(
                    requestID: pending.requestID,
                    ownerEmail: account.email,
                    at: now()
                )
                publish(.accepted(
                    requestID: pending.requestID,
                    ownerEmail: account.email,
                    job: job
                ))
                guard !Task.isCancelled,
                      generation == expectedGeneration,
                      self.account == account else { return }
                // Continue: one account may have several independently queued
                // imports, and a successful first item must not strand the rest.
            } catch is CancellationError {
                activeSubmissionKeys.remove(submissionKey)
                cancelledSubmissionKeys.remove(submissionKey)
                return
            } catch let error as ManagedAnalysisClientError {
                activeSubmissionKeys.remove(submissionKey)
                if cancelledSubmissionKeys.remove(submissionKey) != nil {
                    // Reissue the same idempotency key once. If the first POST
                    // reached the server but its response was lost, this gets
                    // the existing jobId; if it did not, the newly-created job
                    // is immediately cancelled.
                    if let job = try? await client.createJob(
                        pending.request,
                        token: account.token
                    ) {
                        _ = try? await client.cancel(id: job.jobId, token: account.token)
                    }
                    return
                }
                if let delay = retryableDelay(for: error) {
                    _ = try? await store.reschedule(
                        requestID: pending.requestID,
                        ownerEmail: account.email,
                        retryAfterSeconds: delay,
                        at: now()
                    )
                    continue
                }
                try? await store.remove(
                    requestID: pending.requestID,
                    ownerEmail: account.email,
                    at: now()
                )
                publish(.failed(
                    requestID: pending.requestID,
                    ownerEmail: account.email,
                    error: error
                ))
            } catch {
                activeSubmissionKeys.remove(submissionKey)
                cancelledSubmissionKeys.remove(submissionKey)
                return
            }
        }
    }

    private func retryableDelay(for error: ManagedAnalysisClientError) -> Int? {
        switch error {
        case .queueLimit:
            return 5
        case .serverBusy(let retryable):
            return retryable ? 5 : nil
        case .network:
            return 5
        case .server(let status, _, _, _) where (500...599).contains(status):
            return 5
        default:
            return nil
        }
    }

    private func publish(_ resolution: Resolution) {
        let key: String
        switch resolution {
        case let .accepted(requestID, ownerEmail, _),
             let .failed(requestID, ownerEmail, _),
             let .cancelled(requestID, ownerEmail):
            key = resolutionKey(requestID: requestID, ownerEmail: ownerEmail)
        }
        if let continuations = waiters.removeValue(forKey: key), !continuations.isEmpty {
            for continuation in continuations.values {
                continuation.resume(returning: resolution)
            }
            return
        }
        recent[key] = resolution
        recentOrder.removeAll { $0 == key }
        recentOrder.append(key)
        while recentOrder.count > 20 {
            recent.removeValue(forKey: recentOrder.removeFirst())
        }
    }

    private func resolutionKey(requestID: String, ownerEmail: String) -> String {
        "\(normalized(ownerEmail))\u{0}\(requestID)"
    }

    private func cancelWaiter(
        key: String,
        waiterID: UUID,
        resolution: Resolution
    ) {
        guard var bucket = waiters[key],
              let continuation = bucket.removeValue(forKey: waiterID) else { return }
        if bucket.isEmpty {
            waiters.removeValue(forKey: key)
        } else {
            waiters[key] = bucket
        }
        continuation.resume(returning: resolution)
    }

    private func normalized(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
