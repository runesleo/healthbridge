import SwiftUI
import WatchKit
import WatchConnectivity
import AppIntents

/// Watch side: one thing only — say a line. It is queued to the iPhone, which reads it like a quick-log line there
/// (water and mood into Apple Health, meals / check-ins / the note itself into the day's sync).
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
        UserDefaults.standard.set(["text": text, "time": Date().timeIntervalSince1970], forKey: "lastLine")
    }
    func session(_ s: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
}

func L(_ en: String, _ zh: String) -> String {
    (Locale.preferredLanguages.first ?? "").hasPrefix("zh") ? zh : en
}

/// Siri on the watch: hold the side button and say "HealthBridge 记一下", then the line.
struct WatchQuickLogIntent: AppIntent {
    static var title: LocalizedStringResource = "Quick log"
    static var description = IntentDescription("Log water, a meal, a check-in or a note in your own words.")
    static var openAppWhenRun = false

    @Parameter(title: "What to log", requestValueDialog: "Go ahead, I'll write it all down.")
    var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        PhoneLink.shared.send("quick", text)
        return .result(dialog: "Saved: \(text)")
    }
}

struct WatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WatchQuickLogIntent(), phrases: ["Quick log in \(.applicationName)", "\(.applicationName) log"],
                    shortTitle: "Quick log", systemImageName: "mic.fill")
    }
}

struct WatchTodayView: View {
    @State private var last = ""
    @Environment(\.scenePhase) private var phase

    private func refresh() {
        guard let d = UserDefaults.standard.dictionary(forKey: "lastLine"), let t = d["text"] as? String,
              let ts = d["time"] as? Double else { last = ""; return }
        last = Date(timeIntervalSince1970: ts).formatted(date: .omitted, time: .shortened) + " " + t
    }

    var body: some View {
        VStack(spacing: 8) {
            TextFieldLink(prompt: Text(L("Say anything — it is all kept, AI sorts it tonight", "想到什么说什么，全都记下，晚上 AI 整理"))) {
                VStack(spacing: 6) {
                    Image(systemName: "mic.fill").font(.system(size: 40))
                    Text(L("Voice note", "口述记录")).font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } onSubmit: { t in
                let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !s.isEmpty else { return }
                PhoneLink.shared.send("quick", s)
                WKInterfaceDevice.current().play(.success)
                refresh()
            }
            .tint(.blue)
            if !last.isEmpty {
                Text(L("Last: ", "上一条：") + last).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.horizontal, 4)
        .onAppear(perform: refresh)
        .onChange(of: phase) { _, p in if p == .active { refresh() } }
    }
}
