import Foundation
import UIKit

/// Serial upload of the queue (DESIGN.md, "Upload"). All state lives on the io queue; public methods may
/// be called from any thread.
final class Uploader {
    private struct Run {
        var limit: Int
        var refreshed = false
        let forced: Bool
    }

    private final class SyncWaiter {
        var uploaded = 0
        let completion: (Int) -> Void
        init(_ completion: @escaping (Int) -> Void) { self.completion = completion }
    }

    /// While the Keychain is locked, look again after this long.
    private static let lockedRetrySec = 60.0

    var onRemoteCommand: ((RemoteCommand) -> Void)?
    var onAuthorizationRequiredChange: ((Bool) -> Void)?

    private let queue: DispatchQueue
    private let store: LocalStore
    private let auth: AuthCache
    private let logger: EngineLogger
    private let events: EventSink
    private let clock: TimeSource
    private let random: () -> Double
    private let backgroundTask = BackgroundTask(name: "LongPing upload")
    private let retryTimer: EngineTimer
    private let session: URLSession

    private var http = HTTPConfig()
    private var scheduler = UploadScheduler()
    private var run: Run?
    private var task: URLSessionTask?
    private var waiters: [SyncWaiter] = []
    private var forceRequested = false
    private var authorizationRequired = false
    private var interruptedByExpiry = false

    init(queue: DispatchQueue, store: LocalStore, auth: AuthCache, logger: EngineLogger, events: EventSink,
         clock: TimeSource, random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.queue = queue
        self.store = store
        self.auth = auth
        self.logger = logger
        self.events = events
        self.clock = clock
        self.random = random
        retryTimer = EngineTimer(queue: queue)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpMaximumConnectionsPerHost = 1
        // Fail fast offline; NWPathMonitor tells us when to try again.
        configuration.waitsForConnectivity = false
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        session = URLSession(configuration: configuration, delegate: nil, delegateQueue: delegateQueue)

        backgroundTask.onExpire = { [weak self] in
            self?.queue.async { self?.expire() }
        }
    }

    // MARK: - API (any thread)

    func update(http: HTTPConfig) {
        queue.async {
            let urlChanged = http.url != self.http.url
            self.http = http
            if urlChanged, http.uploadURL != nil { self.consider(.watchdog) }
        }
    }

    func trigger(_ trigger: UploadTrigger) {
        queue.async { self.consider(trigger) }
    }

    func connectivityRestored() {
        queue.async {
            self.scheduler.connectivityRestored()
            self.consider(.connectivity)
        }
    }

    /// New or cleared credentials: lift the auth pause and try again.
    func authorizationChanged(cleared: Bool) {
        queue.async {
            self.scheduler.authorizationChanged()
            if !cleared { self.setAuthorizationRequired(false) }
            self.consider(.authorization)
        }
    }

    /// Upload now, ignoring uploadIntervalSec, backoff and the auth pause. Resolves records uploaded.
    func sync(_ completion: @escaping (Int) -> Void) {
        queue.async {
            self.waiters.append(SyncWaiter(completion))
            if self.run != nil {
                self.forceRequested = true
            } else {
                self.consider(.sync)
            }
        }
    }

    // MARK: - Scheduling (io queue)

    private func consider(_ trigger: UploadTrigger) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard run == nil else { return }
        guard http.uploadURL != nil, store.openIfNeeded(), let records = store.records,
              ((try? records.count()) ?? 0) > 0 else {
            resolveWaiters()
            return
        }
        if auth.current == nil, auth.isLocked {
            resolveWaiters()
            retryTimer.schedule(after: Self.lockedRetrySec) { [weak self] in self?.consider(.retryTimer) }
            return
        }
        let now = clock.nowMs
        guard scheduler.shouldUpload(trigger, now: now, uploadIntervalSec: http.uploadIntervalSec) else {
            resolveWaiters()
            scheduleRetry(now: now)
            return
        }
        retryTimer.cancel()
        run = Run(limit: http.maxBatchSize, forced: trigger == .sync)
        interruptedByExpiry = false
        backgroundTask.begin()
        sendNext()
    }

    /// Sleeps until backoff / interval / pause ends, so uploads also happen while tracking is stopped.
    private func scheduleRetry(now: EpochMs) {
        let due = scheduler.nextDueAt(uploadIntervalSec: http.uploadIntervalSec)
        guard due > now else { return }
        retryTimer.schedule(after: Double(due - now) / 1000) { [weak self] in self?.consider(.retryTimer) }
    }

    private func finish() {
        let finished = run
        run = nil
        task = nil
        backgroundTask.end()
        if forceRequested {
            forceRequested = false
            consider(.sync)
            return
        }
        if finished?.forced == true { resolveWaiters() }
        scheduleRetry(now: clock.nowMs)
    }

    private func resolveWaiters() {
        guard !waiters.isEmpty, run == nil else { return }
        let done = waiters
        waiters.removeAll()
        done.forEach { $0.completion($0.uploaded) }
    }

    // MARK: - Sending (io queue)

    private func sendNext() {
        guard var current = run, let url = http.uploadURL, let records = store.records else { return finish() }
        let rows: [QueuedRecord]
        do {
            rows = try records.oldest(limit: http.batch ? current.limit : 1)
        } catch {
            logger.error("upload", "could not read the queue: \(error)")
            return finish()
        }
        guard !rows.isEmpty else { return finish() }

        var items: [JSONValue] = []
        var ids: [Int64] = []
        var unreadable: [Int64] = []
        for row in rows {
            guard let item = UploadBody.item(fromStored: row.json, http: http) else {
                unreadable.append(row.id)
                continue
            }
            if let problem = item.templateError { logger.warn("upload", "\(problem); sent the plain record") }
            items.append(item.value)
            ids.append(row.id)
        }
        if !unreadable.isEmpty {
            _ = try? records.delete(ids: unreadable)
            logger.error("upload", "dropped \(unreadable.count) unreadable record(s)")
        }
        guard let first = items.first else { return sendNext() }

        let body = http.batch ? UploadBody.batch(items, http: http) : UploadBody.single(first, http: http)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: http.timeoutSec)
        request.httpMethod = http.method.rawValue
        for (name, value) in UploadHeaders.make(configured: http.headers, accessToken: auth.current?.accessToken) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body.data

        current.limit = max(1, min(current.limit, http.maxBatchSize))
        run = current
        scheduler.attemptStarted(now: clock.nowMs)
        let count = ids.count
        let dataTask = session.dataTask(with: request) { [weak self] data, response, error in
            self?.queue.async { self?.handle(ids: ids, count: count, data: data, response: response, error: error) }
        }
        task = dataTask
        dataTask.resume()
    }

    private func handle(ids: [Int64], count: Int, data: Data?, response: URLResponse?, error: Error?) {
        task = nil
        guard var current = run else { return }
        if interruptedByExpiry {
            logger.warn("upload", "upload interrupted: background time expired; records kept")
            return finish()
        }
        let httpResponse = response as? HTTPURLResponse
        let status = error == nil ? (httpResponse?.statusCode ?? 0) : 0
        let ok = (200...299).contains(status)
        let text = UploadPolicy.responseText(data)
        events.emit(.http, ["status": status, "ok": ok, "count": count, "responseText": text])
        let reason = error.map { " (\($0.localizedDescription))" } ?? ""
        logger.log(ok ? .info : .warn, "upload", "HTTP \(status) for \(count) record(s)\(reason)")

        let action = UploadPolicy.action(status: status, sentCount: count,
                                         refreshAvailable: auth.current?.canRefresh ?? false,
                                         alreadyRefreshed: current.refreshed)
        switch action {
        case .deleteSent:
            _ = try? store.records?.delete(ids: ids)
            waiters.forEach { $0.uploaded += count }
            scheduler.succeeded()
            setAuthorizationRequired(false)
            if let command = RemoteCommand.parse(data) { onRemoteCommand?(command) }
            sendNext()

        case .refreshAndRetry:
            current.refreshed = true
            run = current
            refreshToken { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .refreshed: self.sendNext()
                case .failed(let reason): self.pauseForAuthorization(status: status, message: reason)
                case .interrupted:
                    self.logger.warn("upload", "token refresh interrupted: background time expired; records kept")
                    self.finish()
                }
            }

        case .pauseForAuthorization:
            pauseForAuthorization(status: status, message: current.refreshed ? "rejected after token refresh (HTTP \(status))" : "HTTP \(status)")

        case .retrySmaller(let limit):
            current.limit = limit
            run = current
            logger.warn("upload", "HTTP 413: retrying with \(limit) record(s) per request")
            sendNext()

        case .backoff:
            let now = clock.nowMs
            let retryAfter = UploadPolicy.retryAfterSec(httpResponse?.value(forHTTPHeaderField: "Retry-After"), now: now)
            let delay = scheduler.failedTransiently(now: now, status: status, retryAfterSec: retryAfter, random: random)
            // The next automatic attempt also waits for uploadIntervalSec; log when it really happens.
            let nextIn = Double(max(0, scheduler.nextDueAt(uploadIntervalSec: http.uploadIntervalSec) - now)) / 1000
            logger.info("upload", String(format: "records kept; backoff %.0f s%@, next attempt in %.0f s", delay,
                                         retryAfter == nil ? "" : " (Retry-After)", nextIn))
            finish()

        case .countAttempt:
            do {
                let dropped = try store.records?.recordFailedAttempt(ids: ids, maxAttempts: UploadPolicy.maxAttempts) ?? []
                if !dropped.isEmpty {
                    logger.warn("upload", "dropped \(dropped.count) record(s) after \(UploadPolicy.maxAttempts) rejected attempts: \(dropped.prefix(5).joined(separator: ", "))")
                }
            } catch {
                logger.error("upload", "could not update attempts: \(error)")
            }
            finish()
        }
    }

    private func pauseForAuthorization(status: Int, message: String) {
        scheduler.pauseForAuthorization(now: clock.nowMs)
        setAuthorizationRequired(true)
        events.emit(.authorization, ["status": status, "error": message])
        logger.error("auth", "upload not authorized (\(message)); uploads paused until setAuthorization() or 15 min")
        finish()
    }

    private func setAuthorizationRequired(_ value: Bool) {
        guard value != authorizationRequired else { return }
        authorizationRequired = value
        onAuthorizationRequiredChange?(value)
    }

    private enum RefreshOutcome {
        case refreshed
        case failed(String)
        case interrupted
    }

    /// POSTs refreshPayload to refreshUrl and stores the new tokens.
    private func refreshToken(_ completion: @escaping (RefreshOutcome) -> Void) {
        guard let credentials = auth.current, let urlString = credentials.refreshUrl, let url = URL(string: urlString) else {
            return completion(.failed("no refresh URL"))
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: http.timeoutSec)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in credentials.refreshHeaders ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = AuthRefresh.body(for: credentials).data
        logger.info("auth", "access token rejected; refreshing")
        let refreshTask = session.dataTask(with: request) { [weak self] data, response, error in
            self?.queue.async {
                guard let self else { return }
                self.task = nil
                if self.interruptedByExpiry { return completion(.interrupted) }
                let status = error == nil ? ((response as? HTTPURLResponse)?.statusCode ?? 0) : 0
                guard (200...299).contains(status), let data, let tokens = AuthRefresh.tokens(from: data) else {
                    let reason = error.map { $0.localizedDescription } ?? "HTTP \(status)"
                    self.logger.warn("auth", "token refresh failed: \(reason)")
                    return completion(.failed("token refresh failed: \(reason)"))
                }
                // Credentials may have been replaced by setAuthorization() while the refresh ran.
                guard let latest = self.auth.current, latest.refreshUrl == credentials.refreshUrl else {
                    return completion(.refreshed)
                }
                self.auth.store(AuthRefresh.updated(latest, accessToken: tokens.accessToken, refreshToken: tokens.refreshToken))
                self.logger.info("auth", "access token refreshed")
                completion(.refreshed)
            }
        }
        task = refreshTask
        refreshTask.resume()
    }

    private func expire() {
        guard let task else { return }
        interruptedByExpiry = true
        task.cancel()
    }
}

/// `beginBackgroundTask` around each upload run so iOS gives it time to finish after the app is
/// backgrounded (needed when tracking is stopped; while tracking, location updates keep the app alive).
final class BackgroundTask {
    var onExpire: (() -> Void)?
    private let name: String
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) { self.name = name }

    func begin() {
        DispatchQueue.main.async {
            guard self.identifier == .invalid else { return }
            self.identifier = UIApplication.shared.beginBackgroundTask(withName: self.name) { [weak self] in
                self?.onExpire?()
                self?.endOnMain()
            }
        }
    }

    func end() {
        DispatchQueue.main.async { self.endOnMain() }
    }

    private func endOnMain() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
