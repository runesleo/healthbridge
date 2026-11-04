import SwiftUI
import WatchKit
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

/// Today's counts on the watch itself, so a tap shows up at once even before the phone has it.
final class WatchCounts: ObservableObject {
    @Published var water = 0
    @Published var meals = 0
    @Published var done: Set<String> = []
    private let key = "watchCounts"

    init() { load() }

    private var today: String { Date().formatted(.iso8601.year().month().day()) }

    func load() {
        let d = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        guard d["day"] as? String == today else { water = 0; meals = 0; done = []; return }
        water = d["water"] as? Int ?? 0
        meals = d["meals"] as? Int ?? 0
        done = Set(d["done"] as? [String] ?? [])
    }

    func save() {
        UserDefaults.standard.set(["day": today, "water": water, "meals": meals, "done": Array(done)], forKey: key)
    }
}

struct Tile: View {
    let icon: String, title: String, detail: String, tint: Color
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.title2).foregroundStyle(tint)
            Text(title).font(.footnote).lineLimit(1).minimumScaleFactor(0.7)
            if !detail.isEmpty { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, minHeight: 56)
    }
}

struct WatchTodayView: View {
    @StateObject private var counts = WatchCounts()
    @State private var toast = ""
    @Environment(\.scenePhase) private var phase
    private let link = PhoneLink.shared
    private let moods: [(String, String, Double)] = [("😄", L("Great", "很好"), 0.9), ("🙂", L("Good", "不错"), 0.45),
                                                    ("😐", L("Okay", "一般"), 0), ("🙁", L("Low", "不太好"), -0.45), ("😣", L("Awful", "很差"), -0.9)]
    private let checkins: [(String, String)] = [(L("Woke up", "起床"), "sunrise.fill"), (L("Exercised", "运动"), "figure.run"),
                                                (L("Going to bed", "准备睡"), "moon.zzz.fill")]

    private func log(_ kind: String, _ text: String, _ msg: String) {
        link.send(kind, text)
        WKInterfaceDevice.current().play(.success)
        toast = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if toast == msg { toast = "" } }
    }

    private func mark(_ name: String) { counts.done.insert(name); counts.save() }

    var body: some View {
        NavigationStack { pages }
    }

    private var pages: some View {
        TabView {
            // Page 1: say it, or tap the four things that happen every day.
            ScrollView {
                VStack(spacing: 8) {
                    TextFieldLink(prompt: Text(L("e.g. had noodles for lunch", "比如：午饭吃了牛肉面"))) {
                        Label(L("Say something", "说一句"), systemImage: "mic.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                    } onSubmit: { t in
                        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !s.isEmpty { log("quick", s, L("Logged", "记下了")) }
                    }
                    .tint(.blue)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        Button { counts.water += 1; counts.save(); log("water", "250", "+250 ml") } label: {
                            Tile(icon: "drop.fill", title: L("Water", "喝水"), detail: L("\(counts.water) today", "今天 \(counts.water) 杯"), tint: .cyan)
                        }
                        Button { counts.meals += 1; counts.save(); log("meal", "", L("Meal logged", "记了吃饭")) } label: {
                            Tile(icon: "fork.knife", title: L("Ate", "吃饭"), detail: L("\(counts.meals) today", "今天 \(counts.meals) 顿"), tint: .orange)
                        }
                        Button { mark("meds"); log("checkin", L("Took meds", "吃药"), L("Meds", "吃药 ✓")) } label: {
                            Tile(icon: "pills.fill", title: L("Meds", "吃药"), detail: counts.done.contains("meds") ? "✓" : "", tint: .pink)
                        }
                        Button { mark("out"); log("checkin", L("Went outside", "出门晒太阳"), L("Outside", "出门 ✓")) } label: {
                            Tile(icon: "sun.max.fill", title: L("Outside", "出门"), detail: counts.done.contains("out") ? "✓" : "", tint: .yellow)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .navigationTitle(toast.isEmpty ? L("Today", "今天") : toast)

            // Page 2: mood, one big face per row.
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(moods, id: \.0) { m in
                        Button { log("mood", String(m.2), m.0 + " " + m.1) } label: {
                            HStack { Text(m.0).font(.title2); Text(m.1); Spacer() }.frame(minHeight: 36)
                        }
                    }
                }
            }
            .navigationTitle(toast.isEmpty ? L("Mood", "心情") : toast)

            // Page 3: the other check-ins.
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(checkins, id: \.0) { c in
                        Button { mark(c.0); log("checkin", c.0, c.0 + " ✓") } label: {
                            HStack { Image(systemName: c.1); Text(c.0); Spacer(); if counts.done.contains(c.0) { Text("✓").foregroundStyle(.green) } }
                                .frame(minHeight: 36)
                        }
                    }
                }
            }
            .navigationTitle(toast.isEmpty ? L("Check in", "打卡") : toast)
        }
        .tabViewStyle(.verticalPage)
        .onChange(of: phase) { _, p in if p == .active { counts.load() } }
    }
}
