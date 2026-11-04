import SwiftUI
import WatchConnectivity

/// Watch side of the Today screen: every tap or spoken line is queued to the iPhone,
/// which logs it exactly like a tap there (water and mood into Apple Health, the rest into the day's sync).
@main
struct HealthBridgeWatchApp: App {
    var body: some Scene { WindowGroup { WatchTodayView() } }
}

final class PhoneLink: NSObject, WCSessionDelegate {
    static let shared = PhoneLink()
    override init() {
        super.init()
        if WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
    }
    /// Queued user info survives the phone being out of reach; it is delivered when the phone app runs.
    func send(_ kind: String, _ text: String) {
        WCSession.default.transferUserInfo(["kind": kind, "text": text, "time": Date().timeIntervalSince1970])
    }
    func session(_ s: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
}

func L(_ en: String, _ zh: String) -> String {
    (Locale.preferredLanguages.first ?? "").hasPrefix("zh") ? zh : en
}

struct WatchTodayView: View {
    @State private var text = ""
    @State private var toast = ""
    private let link = PhoneLink.shared
    private let moods: [(String, Double)] = [("😣", -0.9), ("🙁", -0.45), ("😐", 0), ("🙂", 0.45), ("😄", 0.9)]
    private let checkins = [L("Woke up", "起床"), L("Took meds", "吃药"), L("Went outside", "出门晒太阳"), L("Exercised", "运动"), L("Going to bed", "准备睡")]

    private func done(_ msg: String) {
        toast = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if toast == msg { toast = "" } }
    }

    var body: some View {
        NavigationStack {
            List {
                TextField(L("Say something", "说一句"), text: $text)
                    .onSubmit {
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { return }
                        link.send("quick", t); text = ""; done(L("Logged", "记下了"))
                    }
                Button { link.send("water", "250"); done("+250 ml") } label: {
                    Label(L("A glass of water", "喝了一杯水"), systemImage: "drop.fill")
                }
                Button { link.send("meal", ""); done(L("Meal logged", "记了吃饭")) } label: {
                    Label(L("Ate", "吃饭了"), systemImage: "fork.knife")
                }
                HStack {
                    ForEach(moods, id: \.0) { m in
                        Button { link.send("mood", String(m.1)); done(m.0) } label: { Text(m.0).font(.title3) }
                            .buttonStyle(.plain).frame(maxWidth: .infinity)
                    }
                }
                ForEach(checkins, id: \.self) { c in
                    Button(c) { link.send("checkin", c); done(c) }
                }
            }
            .navigationTitle(toast.isEmpty ? L("Today", "今天") : toast)
        }
    }
}
