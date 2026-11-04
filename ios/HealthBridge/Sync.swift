import Foundation
import UIKit
import HealthKit
import BackgroundTasks
import CryptoKit

final class Sync {
    static let shared = Sync()
    static let taskID = (Bundle.main.bundleIdentifier ?? "HealthBridge") + ".refresh"
    static var defaultEndpoint: String { Config.endpoint }
    let store = HKHealthStore()
    private var observersStarted = false

    let sums: [(String, HKQuantityTypeIdentifier, HKUnit)] = [
        ("steps", .stepCount, .count()),
        ("active_kcal", .activeEnergyBurned, .kilocalorie()),
        ("exercise_min", .appleExerciseTime, .minute()),
        ("water_ml", .dietaryWater, .literUnit(with: .milli)),
        ("daylight_min", .timeInDaylight, .minute()),
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
    var readTypes: Set<HKObjectType> {
        var s: Set<HKObjectType> = [HKObjectType.workoutType(), HKCategoryType(.sleepAnalysis)]
        for (_, id, _) in sums { s.insert(HKQuantityType(id)) }
        for (_, id) in avgs { s.insert(HKQuantityType(id)) }
        for (_, id, _, _) in extras { s.insert(HKQuantityType(id)) }
        if #available(iOS 18.0, *) { s.insert(HKSampleType.stateOfMindType()) }
        return s
    }

    /// Minutes asleep for the night that ends on `day` (18:00 the evening before → 12:00),
    /// merging overlapping samples from different sources so nothing is counted twice,
    /// plus when that sleep started and ended (fell asleep / woke up).
    private func sleep(endingOn dayStart: Date) async -> [String: Any]? {
        let cal = Calendar.current
        guard let prev = cal.date(byAdding: .day, value: -1, to: dayStart),
              let from = cal.date(bySettingHour: 18, minute: 0, second: 0, of: prev),
              let to = cal.date(bySettingHour: 12, minute: 0, second: 0, of: dayStart) else { return nil }
        let samples: [HKCategorySample] = await withCheckedContinuation { c in
            let pred = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
            store.execute(HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis), predicate: pred, limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, s, _ in
                c.resume(returning: (s as? [HKCategorySample]) ?? []) })
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
        var out: [String: Any] = ["sleep_min": merged(asleep)]
        let iso = ISO8601DateFormatter(); iso.timeZone = .current
        if let s0 = asleep.map(\.startDate).min() { out["sleep_start"] = iso.string(from: max(s0, from)) }
        if let e0 = asleep.map(\.endDate).max() { out["sleep_end"] = iso.string(from: min(e0, to)) }
        // Times awake between falling asleep and the final wake-up (each merged stretch counts once).
        if let s0 = asleep.map(\.startDate).min(), let e0 = asleep.map(\.endDate).max() {
            let awake = samples.filter { $0.value == HKCategoryValueSleepAnalysis.awake.rawValue && $0.startDate >= s0 && $0.endDate <= e0 }
                .sorted { $0.startDate < $1.startDate }
            var count = 0, lastEnd: Date?
            for a in awake { if let e = lastEnd, a.startDate <= e { lastEnd = max(e, a.endDate) } else { count += 1; lastEnd = a.endDate } }
            out["awake_count"] = Double(count)
            if !awake.isEmpty { out["awake_min"] = merged(awake) }
        }
        let deep = samples.filter { $0.value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue }
        let rem = samples.filter { $0.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue }
        if !deep.isEmpty { out["deep_min"] = merged(deep) }  // omitted when the source has no stage data
        if !rem.isEmpty { out["rem_min"] = merged(rem) }
        return out
    }

    /// Mood entries logged that day (Health → State of Mind): time, momentary or whole-day, valence −1…1.
    private func moods(_ start: Date, _ end: Date) async -> [[String: Any]] {
        guard #available(iOS 18.0, *) else { return [] }
        let samples: [HKStateOfMind] = await withCheckedContinuation { c in
            let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            store.execute(HKSampleQuery(sampleType: .stateOfMindType(), predicate: pred, limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, s, _ in
                c.resume(returning: (s as? [HKStateOfMind]) ?? []) })
        }
        let iso = ISO8601DateFormatter(); iso.timeZone = .current
        return samples.map { m in
            ["time": iso.string(from: m.startDate), "kind": m.kind == .dailyMood ? "day" : "moment",
             "valence": (m.valence * 100).rounded() / 100]
        }
    }

    func authorize() async -> String {
        guard HKHealthStore.isHealthDataAvailable() else { return L("Health data is not available on this device", "此设备没有健康数据") }
        do { try await store.requestAuthorization(toShare: shareTypes, read: readTypes); startObservers(); return L("Authorization requested", "已请求授权") }
        catch { return L("Authorization failed: ", "授权失败：") + error.localizedDescription }
    }

    /// Save one glass of water to Health; returns the sample's id so the Today screen can undo it.
    func logWater(ml: Double, at now: Date = Date()) async -> UUID? {
        let sample = HKQuantitySample(type: HKQuantityType(.dietaryWater), quantity: HKQuantity(unit: .literUnit(with: .milli), doubleValue: ml), start: now, end: now)
        do { try await store.save(sample); return sample.uuid } catch { return nil }
    }

    /// Save a momentary mood (valence −1…1) to Health → State of Mind (iOS 18+).
    func logMood(valence: Double, at time: Date = Date()) async -> UUID? {
        guard #available(iOS 18.0, *) else { return nil }
        let m = HKStateOfMind(date: time, kind: .momentaryEmotion, valence: valence, labels: [], associations: [])
        do { try await store.save(m); return m.uuid } catch { return nil }
    }

    /// Undo: delete a sample this app saved earlier.
    func deleteSample(_ id: UUID, kind: String) async {
        let type: HKSampleType
        if kind == "mood" { guard #available(iOS 18.0, *) else { return }; type = .stateOfMindType() } else { type = HKQuantityType(.dietaryWater) }
        let pred = HKQuery.predicateForObject(with: id)
        _ = try? await store.deleteObjects(of: type, predicate: pred)
    }

    var shareTypes: Set<HKSampleType> {
        var s: Set<HKSampleType> = [HKQuantityType(.dietaryWater)]
        if #available(iOS 18.0, *) { s.insert(.stateOfMindType()) }
        return s
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

    private func stat(_ id: HKQuantityTypeIdentifier, _ opt: HKStatisticsOptions, _ start: Date, _ end: Date) async -> HKStatistics? {
        await withCheckedContinuation { c in
            let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            store.execute(HKStatisticsQuery(quantityType: HKQuantityType(id), quantitySamplePredicate: pred, options: opt) { _, s, _ in c.resume(returning: s) })
        }
    }

    private func workouts(_ start: Date, _ end: Date) async -> [HKWorkout] {
        await withCheckedContinuation { c in
            let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            store.execute(HKSampleQuery(sampleType: .workoutType(), predicate: pred, limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, s, _ in
                c.resume(returning: (s as? [HKWorkout]) ?? []) })
        }
    }

    func payload(for day: Date) async -> [String: Any] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day), end = cal.date(byAdding: .day, value: 1, to: start)!
        let iso = ISO8601DateFormatter(); iso.timeZone = .current
        let df = DateFormatter(); df.calendar = Calendar(identifier: .gregorian); df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = .current; df.dateFormat = "yyyy-MM-dd"
        var p: [String: Any] = ["date": df.string(from: start), "generated_at": iso.string(from: Date())]
        for (k, id, unit) in sums {
            if let v = await stat(id, .cumulativeSum, start, end)?.sumQuantity()?.doubleValue(for: unit) { p[k] = (v * 10).rounded() / 10 }
        }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        for (k, id) in avgs {
            if let s = await stat(id, [.discreteAverage, .discreteMax, .discreteMin], start, end) {
                if let v = s.averageQuantity()?.doubleValue(for: bpm) { p[k + "_avg"] = v.rounded() }
                if k == "heart_rate", let v = s.maximumQuantity()?.doubleValue(for: bpm) { p["heart_rate_max"] = v.rounded() }
            }
        }
        for (k, id, unit, scale) in extras {
            if let v = await stat(id, .discreteAverage, start, end)?.averageQuantity()?.doubleValue(for: unit) { p[k] = (v * scale * 10).rounded() / 10 }
        }
        if let sl = await sleep(endingOn: start) { for (k, v) in sl { p[k] = v } }
        var ws: [[String: Any]] = []
        for w in await workouts(start, end) {
            var d: [String: Any] = ["type": w.workoutActivityType.rawValue, "start": iso.string(from: w.startDate),
                                    "end": iso.string(from: w.endDate), "minutes": (w.duration / 6).rounded() / 10]
            if let e = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity() { d["active_kcal"] = e.doubleValue(for: .kilocalorie()).rounded() }
            if let h = w.statistics(for: HKQuantityType(.heartRate)) {
                if let a = h.averageQuantity() { d["hr_avg"] = a.doubleValue(for: bpm).rounded() }
                if let m = h.maximumQuantity() { d["hr_max"] = m.doubleValue(for: bpm).rounded() }
            }
            if let dist = w.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity() { d["km"] = (dist.doubleValue(for: .meterUnit(with: .kilo)) * 100).rounded() / 100 }
            ws.append(d)
        }
        p["workouts"] = ws
        for (k, v) in DailyLog.payload(for: start) { p[k] = v }
        let ms = await moods(start, end)
        if !ms.isEmpty { p["moods"] = ms }
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

    /// Send history in 30-day chunks, oldest first.
    func backfill(days total: Int, progress: @escaping (String) -> Void) async -> String {
        let anchor = Date()  // fixed for the whole backfill so crossing midnight leaves no gap
        var offset = total
        while offset >= 0 {
            let chunkEnd = max(offset - 29, 0)
            let (r, ok) = await runRange(from: offset, to: chunkEnd, anchor: anchor)
            progress(L("Backfilling: \(chunkEnd) days left… ", "补传中：还剩 \(chunkEnd) 天… ") + r)
            if !ok { return L("Backfill stopped: ", "补传中断：") + r }
            offset = chunkEnd - 1
        }
        return L("Backfill complete (\(total) days)", "历史补传完成（\(total) 天）")
    }

    private func runRange(from back: Int, to end: Int, anchor now: Date) async -> (String, Bool) {
        var days: [[String: Any]] = []
        for b in stride(from: back, through: end, by: -1) {
            if let d = Calendar.current.date(byAdding: .day, value: -b, to: now) { days.append(await payload(for: d)) }
        }
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

    @discardableResult
    func run(reason: String, daysBack: Int? = nil) async -> (String, String) {
        // Health data is encrypted while the phone is locked: queries come back empty and would overwrite good days on the Mac.
        guard await MainActor.run(body: { UIApplication.shared.isProtectedDataAvailable }) else {
            return (L("Phone locked, Health unreadable; will sync after unlock", "手机锁着，读不到健康数据；解锁后再同步"), "")
        }
        let now = Date()
        let daysBack = daysBack ?? catchUpDays(now: now)
        var days: [[String: Any]] = []
        for back in stride(from: daysBack, through: 0, by: -1) {
            if let d = Calendar.current.date(byAdding: .day, value: -back, to: now) { days.append(await payload(for: d)) }
        }
        let r = await send(days: days, reason: reason)
        if r.ok { Sync.lastOK = now }
        UserDefaults.standard.set(r.status, forKey: "lastStatus")
        return (r.status, r.json)
    }

    struct SendResult { let status: String; let json: String; var ok = false }

    func send(days: [[String: Any]], reason: String) async -> SendResult {
        let now = Date()
        let body: [String: Any] = ["source": "HealthBridge", "reason": reason, "sent_at": Int(now.timeIntervalSince1970), "days": days]
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
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 { return SendResult(status: L("Sent ", "已发送 ") + "\(Date().formatted(date: .omitted, time: .shortened)) (\(u.host ?? ""))", json: text, ok: true) }
                return SendResult(status: L("Mac answered ", "Mac 返回 ") + "\(code) (\(u.host ?? ""))", json: text)  // got an answer: never retry elsewhere
            } catch { lastError = L("Send failed ", "发送失败 ") + "(\(u.host ?? "")): \(error.localizedDescription)" }
        }
        return SendResult(status: lastError, json: text)
    }
}

/// Pick English or Chinese by the phone's preferred language.
func L(_ en: String, _ zh: String) -> String {
    (Locale.preferredLanguages.first ?? "").hasPrefix("zh") ? zh : en
}
