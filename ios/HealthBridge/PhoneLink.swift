import Foundation
import WatchConnectivity
import Speech

/// Receives taps, spoken lines and recorded voice notes from the watch app and logs them like taps on the phone.
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ s: WCSession, didReceiveUserInfo info: [String: Any] = [:]) {
        let kind = info["kind"] as? String ?? ""
        let text = info["text"] as? String ?? ""
        let time = Date(timeIntervalSince1970: info["time"] as? Double ?? Date().timeIntervalSince1970)
        Task { @MainActor in
            let log = DailyLog.shared
            switch kind {
            case "water":
                let ml = Double(text) ?? TodayView.cupML
                let id = await Sync.shared.logWater(ml: ml, at: time)
                log.add("water", "\(Int(ml)) ml ⌚︎", healthID: id, at: time)
            case "mood":
                let v = Double(text) ?? 0
                let id = await Sync.shared.logMood(valence: v, at: time)
                let face = TodayView.moods.min(by: { abs($0.2 - v) < abs($1.2 - v) })
                log.add("mood", "\(face?.0 ?? "") \(face?.1 ?? "") ⌚︎", healthID: id, at: time)
            case "meal": log.add("meal", TodayView.mealName(at: time) + " ⌚︎", at: time)
            case "checkin": log.add("checkin", text, at: time)
            case "quick": await log.quick(text, at: time)
            default: break
            }
        }
    }

    /// A voice note from the watch. The file must be moved before this returns; transcription happens after.
    func session(_ s: WCSession, didReceive file: WCSessionFile) {
        let time = file.metadata?["time"] as? Double ?? Date().timeIntervalSince1970
        guard let dest = try? VoiceNotes.store(file.fileURL, time: time) else { return }
        Task { await VoiceNotes.transcribe(dest) }
    }

    func session(_ s: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ s: WCSession) {}
    func sessionDidDeactivate(_ s: WCSession) { WCSession.default.activate() }
}

/// Voice notes waiting to become text. Kept on disk until transcribed, so nothing is lost if the phone is busy or locked.
enum VoiceNotes {
    static var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func store(_ src: URL, time: Double) throws -> URL {
        let dest = dir.appendingPathComponent("\(Int(time)).m4a")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: src, to: dest)
        return dest
    }

    static func authorize() {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined { SFSpeechRecognizer.requestAuthorization { _ in } }
    }

    /// Retry anything still waiting (called when the app opens).
    static func retryPending() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "m4a" { Task { await transcribe(f) } }
    }

    static func transcribe(_ url: URL) async {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let rec = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), rec.isAvailable else { return }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        let text: String? = await withCheckedContinuation { c in
            var done = false
            rec.recognitionTask(with: req) { result, error in
                guard !done else { return }
                if let r = result, r.isFinal { done = true; c.resume(returning: r.bestTranscription.formattedString) }
                else if error != nil { done = true; c.resume(returning: nil) }
            }
        }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        let time = Date(timeIntervalSince1970: Double(url.deletingPathExtension().lastPathComponent) ?? Date().timeIntervalSince1970)
        try? FileManager.default.removeItem(at: url)
        guard !t.isEmpty else { return }
        await MainActor.run { _ = Task { await DailyLog.shared.quick("🎙 " + t, at: time) } }
    }
}
