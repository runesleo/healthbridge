import Foundation
import UIKit
import HealthKit
import BackgroundTasks
import CryptoKit

final class Sync: @unchecked Sendable {
    static let shared = Sync()
    static let taskID = (Bundle.main.bundleIdentifier ?? "HealthBridge") + ".refresh"
    static var defaultEndpoint: String { Config.endpoint }
    let store = HKHealthStore()
    private var observersStarted = false
    private let jobLock = NSLock()
    private var syncJob: Task<(String, String), Never>?
    private var backfillJob: Task<String, Never>?

    enum ReadError: Error { case locked }

    let sums: [(String, HKQuantityTypeIdentifier, HKUnit)] = [
        ("steps", .stepCount, .count()),
        ("active_kcal", .activeEnergyBurned, .kilocalorie()),
        ("exercise_min", .appleExerciseTime, .minute()),
    ]
    let avgs: [(String, HKQuantityTypeIdentifier)] = [
        ("heart_rate", .heartRate),
        ("resting_hr", .restingHeartRate),
    ]
    /// Daily averages of other discrete measurements: (key, type, unit, scale).
    let extras: [(String, HKQuantityTypeIdentifier, HKUnit, Double)] = [
        ("hrv_sdnn_ms", .heartRateVariabilitySDNN, .secondUnit(with: .milli), 1),
        ("walking_hr_avg", .walkingHeartRateAverage, HKUnit.count().unitDivided(by: .minute()), 1),
        ("spo2_pct", .oxygenSaturation, .percent(), 100),
        ("resp_rate", .respiratoryRate, HKUnit.count().unitDivided(by: .minute()), 1),
        ("vo2max", .vo2Max, HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute())), 1),
        ("bp_sys", .bloodPressureSystolic, .millimeterOfMercury(), 1),
        ("bp_dia", .bloodPressureDiastolic, .millimeterOfMercury(), 1),
        ("weight_kg", .bodyMass, .gramUnit(with: .kilo), 1),
    ]
    /// Workout distance, first one present: walks/runs, rides, swims.
    let distances: [HKQuantityTypeIdentifier] = [.distanceWalkingRunning, .distanceCycling, .distanceSwimming]
    var readTypes: Set<HKObjectType> {
        var s: Set<HKObjectType> = [HKObjectType.workoutType(), HKCategoryType(.sleepAnalysis)]
        for id in distances { s.insert(HKQuantityType(id)) }
        for (_, id, _) in sums { s.insert(HKQuantityType(id)) }
        for (_, id) in avgs { s.insert(HKQuantityType(id)) }
        for (_, id, _, _) in extras { s.insert(HKQuantityType(id)) }
        return s
    }

    /// Minutes asleep for the night that ends on `day` (18:00 the evening before → 12:00),
    /// merging overlapping samples from different sources so nothing is counted twice.
    private func sleep(endingOn dayStart: Date) async throws -> [String: Double]? {
        let cal = Calendar.current
        guard let prev = cal.date(byAdding: .day, value: -1, to: dayStart),
              let from = cal.date(bySettingHour: 18, minute: 0, second: 0, of: prev),
              let to = cal.date(bySettingHour: 12, minute: 0, second: 0, of: dayStart) else { return nil }
        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { c in
            let pred = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
            store.execute(HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis), predicate: pred, limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, s, e in
                c.resume(with: Result { (try Sync.unlessNoData(s, e) as? [HKCategorySample]) ?? [] }) })
        }
        func merged(_ xs: [HKCategorySample]) -> Double {
            var total = 0.0, curS: Date?, curE: Date?
            for x in xs.sorted(by: { $0.startDate < $1.startDate }) {
                let a = max(x.startDate, from), b = min(x.endDate, to)
                guard b > a else { continue }
                if let e = curE, a <= e { curE = max(e, b) } else {
                    if let s0 = curS, let e = curE { total += e.timeIntervalSince(s0) }
                    curS = a; curE = b
                }
            }
            if let s0 = curS, let e = curE { total += e.timeIntervalSince(s0) }
            return (total / 60).rounded()
        }
        let asleepValues: Set<Int> = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                      HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue]
        let asleep = samples.filter { asleepValues.contains($0.value) }
        guard !asleep.isEmpty else { return nil }
        var out = ["sleep_min": merged(asleep)]
        let deep = samples.filter { $0.value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue }
        let rem = samples.filter { $0.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue }
        if !deep.isEmpty { out["deep_min"] = merged(deep) }  // omitted when the source has no stage data
        if !rem.isEmpty { out["rem_min"] = merged(rem) }
        return out
    }

    func authorize() async -> String {
        guard HKHealthStore.isHealthDataAvailable() else { return L("Health data is not available on this device", "此设备没有健康数据") }
        do { try await store.requestAuthorization(toShare: [], read: readTypes); startObservers(); return L("Authorization requested", "已请求授权") }
        catch { return L("Authorization failed: ", "授权失败：") + error.localizedDescription }
    }

    func startObservers() {
        guard !observersStarted else { return }
        observersStarted = true
        for t in [HKObjectType.workoutType(), HKQuantityType(.activeEnergyBurned)] as [HKSampleType] {
            let q = HKObserverQuery(sampleType: t, predicate: nil) { _, done, _ in
                Task { await self.run(reason: "observer"); done() }
            }
            store.execute(q)
            store.enableBackgroundDelivery(for: t, frequency: .hourly) { _, _ in }
        }
    }

    static func schedule() {
        let r = BGAppRefreshTaskRequest(identifier: taskID)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        try? BGTaskScheduler.shared.submit(r)
    }

    /// A query result, or nil when Health has nothing to give for it (no data, or a type the user hasn't granted,
    /// e.g. one added in a newer version). Any other error (e.g. the phone locked mid-read) throws, so a failed
    /// read is never sent as an empty day.
    static func unlessNoData<T>(_ value: T?, _ error: Error?) throws -> T? {
        if let error {
            let e = error as NSError
            let absent: [HKError.Code] = [.errorNoData, .errorAuthorizationNotDetermined, .errorAuthorizationDenied]
            if e.domain == HKErrorDomain && absent.contains(where: { $0.rawValue == e.code }) { return nil }
            throw error
        }
        return value
    }

    private func stat(_ id: HKQuantityTypeIdentifier, _ opt: HKStatisticsOptions, _ start: Date, _ end: Date) async throws -> HKStatistics? {
        try await withCheckedThrowingContinuation { c in
            let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            store.execute(HKStatisticsQuery(quantityType: HKQuantityType(id), quantitySamplePredicate: pred, options: opt) { _, s, e in
                c.resume(with: Result { try Sync.unlessNoData(s, e) }) })
        }
    }

    private func workouts(_ start: Date, _ end: Date) async throws -> [HKWorkout] {
        try await withCheckedThrowingContinuation { c in
            let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            store.execute(HKSampleQuery(sampleType: .workoutType(), predicate: pred, limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, s, e in
                c.resume(with: Result { (try Sync.unlessNoData(s, e) as? [HKWorkout]) ?? [] }) })
        }
    }

    func payload(for day: Date) async throws -> [String: Any] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day), end = cal.date(byAdding: .day, value: 1, to: start)!
        let iso = ISO8601DateFormatter(); iso.timeZone = .current
        let df = DateFormatter(); df.calendar = Calendar(identifier: .gregorian); df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = .current; df.dateFormat = "yyyy-MM-dd"
        var p: [String: Any] = ["date": df.string(from: start), "generated_at": iso.string(from: Date())]
        for (k, id, unit) in sums {
            if let v = try await stat(id, .cumulativeSum, start, end)?.sumQuantity()?.doubleValue(for: unit) { p[k] = (v * 10).rounded() / 10 }
        }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        for (k, id) in avgs {
            if let s = try await stat(id, [.discreteAverage, .discreteMax, .discreteMin], start, end) {
                if let v = s.averageQuantity()?.doubleValue(for: bpm) { p[k + "_avg"] = v.rounded() }
                if k == "heart_rate", let v = s.maximumQuantity()?.doubleValue(for: bpm) { p["heart_rate_max"] = v.rounded() }
            }
        }
        for (k, id, unit, scale) in extras {
            if let v = try await stat(id, .discreteAverage, start, end)?.averageQuantity()?.doubleValue(for: unit) { p[k] = (v * scale * 10).rounded() / 10 }
        }
        if let sl = try await sleep(endingOn: start) { for (k, v) in sl { p[k] = v } }
        var ws: [[String: Any]] = []
        for w in try await workouts(start, end) {
            var d: [String: Any] = ["type": w.workoutActivityType.rawValue, "start": iso.string(from: w.startDate),
                                    "end": iso.string(from: w.endDate), "minutes": (w.duration / 6).rounded() / 10]
            if let e = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity() { d["active_kcal"] = e.doubleValue(for: .kilocalorie()).rounded() }
            if let h = w.statistics(for: HKQuantityType(.heartRate)) {
                if let a = h.averageQuantity() { d["hr_avg"] = a.doubleValue(for: bpm).rounded() }
                if let m = h.maximumQuantity() { d["hr_max"] = m.doubleValue(for: bpm).rounded() }
            }
            if let dist = distances.lazy.compactMap({ w.statistics(for: HKQuantityType($0))?.sumQuantity() }).first {
                d["km"] = (dist.doubleValue(for: .meterUnit(with: .kilo)) * 100).rounded() / 100
            }
            ws.append(d)
        }
        p["workouts"] = ws
        return p
    }

    /// Days since the oldest step sample in Health (first day of any recorded data).
    func daysOfHistory() async -> Int {
        let first: Date? = await withCheckedContinuation { c in
            store.execute(HKSampleQuery(sampleType: HKQuantityType(.stepCount), predicate: nil, limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, s, _ in
                c.resume(returning: s?.first?.startDate) })
        }
        guard let first else { return 0 }
        return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: first), to: Date()).day ?? 0
    }

    /// Await a shared job; cancelling the caller (e.g. an expiring background task) cancels the job.
    private func join<T>(_ job: Task<T, Never>) async -> T {
        await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
    }

    /// Read the days `back` ... `end` days before `now`, oldest first. Throws instead of returning empty days
    /// when Health can't be read: the phone is locked (before or during the read) or a query failed.
    private func readDays(from back: Int, to end: Int, now: Date) async throws -> [[String: Any]] {
        guard await MainActor.run(body: { UIApplication.shared.isProtectedDataAvailable }) else { throw ReadError.locked }
        var days: [[String: Any]] = []
        for b in stride(from: back, through: end, by: -1) {
            if let d = Calendar.current.date(byAdding: .day, value: -b, to: now) { days.append(try await payload(for: d)) }
        }
        guard await MainActor.run(body: { UIApplication.shared.isProtectedDataAvailable }) else { throw ReadError.locked }
        return days
    }

    static func readFailure(_ error: Error) -> String {
        let e = error as NSError
        if error is ReadError || (e.domain == HKErrorDomain && e.code == HKError.Code.errorDatabaseInaccessible.rawValue) {
            return L("Phone locked, Health unreadable; will sync after unlock", "手机锁着，读不到健康数据；解锁后再同步")
        }
        return L("Couldn't read Health, nothing sent: ", "读取健康数据失败，未发送：") + error.localizedDescription
    }

    /// Send history in 30-day chunks, oldest first. Waits for a sync in flight, and syncs triggered meanwhile
    /// return at once, so two sends never race on the Mac.
    func backfill(days total: Int, progress: @escaping (String) -> Void) async -> String {
        let job: Task<String, Never>? = jobLock.withLock {
            guard backfillJob == nil else { return nil }
            let pending = syncJob
            let t = Task<String, Never> {
                _ = await pending?.value
                let r = await self.backfillNow(days: total, progress: progress)
                self.jobLock.withLock { self.backfillJob = nil }
                return r
            }
            backfillJob = t
            return t
        }
        guard let job else { return L("Backfill already running", "历史补传已在进行") }
        return await join(job)
    }

    private func backfillNow(days total: Int, progress: @escaping (String) -> Void) async -> String {
        let anchor = Date()  // fixed for the whole backfill so crossing midnight leaves no gap
        var offset = total
        while offset >= 0 {
            if Task.isCancelled { return L("Backfill stopped", "补传中断") }
            let chunkEnd = max(offset - 29, 0)
            let (r, ok) = await runRange(from: offset, to: chunkEnd, anchor: anchor)
            progress(L("Backfilling: \(chunkEnd) days left… ", "补传中：还剩 \(chunkEnd) 天… ") + r)
            if !ok { return L("Backfill stopped: ", "补传中断：") + r }
            offset = chunkEnd - 1
        }
        return L("Backfill complete (\(total) days)", "历史补传完成（\(total) 天）")
    }

    private func runRange(from back: Int, to end: Int, anchor now: Date) async -> (String, Bool) {
        let days: [[String: Any]]
        do { days = try await readDays(from: back, to: end, now: now) } catch { return (Sync.readFailure(error), false) }
        let r = await send(days: days, reason: "backfill")
        return (r.status, r.ok)
    }

    /// Last time the Mac accepted a sync; the next run resends every day since then, so a failed send heals itself.
    static var lastOK: Date? {
        get { UserDefaults.standard.object(forKey: "lastOK") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastOK") }
    }

    /// Days to resend: at least 2, back to the day of the last accepted sync, at most 60.
    func catchUpDays(now: Date = Date()) -> Int {
        guard let last = Sync.lastOK else { return 2 }
        let cal = Calendar.current
        let gap = cal.dateComponents([.day], from: cal.startOfDay(for: last), to: cal.startOfDay(for: now)).day ?? 0
        return min(max(2, gap), 60)
    }

    /// Triggers overlap (unlock + open, two observers): one that arrives while a sync is in flight joins it
    /// instead of sending in parallel, since parallel sends race each other on the Mac.
    @discardableResult
    func run(reason: String, daysBack: Int? = nil) async -> (String, String) {
        let job: Task<(String, String), Never>? = jobLock.withLock {
            if backfillJob != nil { return nil }
            if let running = syncJob { return running }
            let t = Task<(String, String), Never> {
                let r = await self.runNow(reason: reason, daysBack: daysBack)
                self.jobLock.withLock { self.syncJob = nil }
                return r
            }
            syncJob = t
            return t
        }
        guard let job else { return (L("Backfill in progress; it includes today", "历史补传进行中，已包含今天"), "") }
        return await join(job)
    }

    private func runNow(reason: String, daysBack: Int?) async -> (String, String) {
        // Health data is encrypted while the phone is locked: queries fail, and sending the result would
        // overwrite good days on the Mac with empty ones. readDays throws instead.
        let now = Date()
        let back = daysBack ?? catchUpDays(now: now)
        let days: [[String: Any]]
        do { days = try await readDays(from: back, to: 0, now: now) } catch { return (Sync.readFailure(error), "") }
        let r = await send(days: days, reason: reason)
        if r.ok { Sync.lastOK = now }
        UserDefaults.standard.set(r.status, forKey: "lastStatus")
        return (r.status, r.json)
    }

    struct SendResult { let status: String; let json: String; var ok = false }

    func send(days: [[String: Any]], reason: String) async -> SendResult {
        let sentAt = Int(Date().timeIntervalSince1970)
        let body: [String: Any] = ["source": "HealthBridge", "reason": reason, "sent_at": sentAt, "days": days]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .prettyPrinted]) else { return SendResult(status: L("Encoding failed", "编码失败"), json: "") }
        let text = String(data: data, encoding: .utf8) ?? ""
        let saved = UserDefaults.standard.string(forKey: "endpoint")?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let url = URL(string: saved.isEmpty ? Sync.defaultEndpoint : saved), url.host != nil else { return SendResult(status: L("Invalid receiver address", "接收地址无效"), json: text) }
        let secret = Config.secret
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        guard let sealed = try? AES.GCM.seal(data, using: key).combined else { return SendResult(status: L("Encryption failed", "加密失败"), json: text) }
        var urls = [url]
        if let ip = Config.fallbackHost, let fb = URL(string: "http://\(ip):\(Config.port)/health"), fb != url { urls.append(fb) }
        var lastError = ""
        for u in urls {
            var req = URLRequest(url: u); req.httpMethod = "POST"; req.httpBody = sealed
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type"); req.timeoutInterval = 10
            do {
                let (reply, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 {
                    // Only the receiver holding the secret can produce this ack; any other 200 is not a delivery.
                    guard Sync.ackMatches(reply, sentAt: sentAt, key: key) else {
                        return SendResult(status: L("Unconfirmed answer from ", "回复无法确认，来自 ") + (u.host ?? "")
                            + L(" (not your receiver, or it runs an older HealthBridge)", "（不是你的接收端，或 Mac 端版本过旧）"), json: text)
                    }
                    return SendResult(status: L("Sent ", "已发送 ") + "\(Date().formatted(date: .omitted, time: .shortened)) (\(u.host ?? ""))", json: text, ok: true)
                }
                return SendResult(status: L("Mac answered ", "Mac 返回 ") + "\(code) (\(u.host ?? ""))", json: text)  // got an answer: never retry elsewhere
            } catch { lastError = L("Send failed ", "发送失败 ") + "(\(u.host ?? "")): \(error.localizedDescription)" }
        }
        return SendResult(status: lastError, json: text)
    }

    /// The receiver answers with AES-GCM(nonce‖ciphertext‖tag) of {"ack": sent_at}.
    static func ackMatches(_ reply: Data, sentAt: Int, key: SymmetricKey) -> Bool {
        guard let box = try? AES.GCM.SealedBox(combined: reply),
              let plain = try? AES.GCM.open(box, using: key),
              let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let ack = obj["ack"] as? Int else { return false }
        return ack == sentAt
    }
}

/// Pick English or Chinese by the phone's preferred language.
func L(_ en: String, _ zh: String) -> String {
    (Locale.preferredLanguages.first ?? "").hasPrefix("zh") ? zh : en
}
