import Foundation
import WatchConnectivity

/// Receives taps and spoken lines from the watch app and logs them like taps on the phone.
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

    func session(_ s: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ s: WCSession) {}
    func sessionDidDeactivate(_ s: WCSession) { WCSession.default.activate() }
}
