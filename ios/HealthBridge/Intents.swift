import AppIntents

/// "Sync health data" action for the Shortcuts app, so a personal automation
/// (a time of day, or joining the home Wi-Fi) can sync without opening HealthBridge.
struct SyncHealthIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync health data"
    static var description = IntentDescription("Send the days since the last sync to your computer.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (status, _) = await Sync.shared.run(reason: "shortcut")
        return .result(dialog: "\(status)")
    }
}

/// "Log a glass of water" — one tap from the lock screen, Action button, watch or Siri.
struct LogWaterIntent: AppIntent {
    static var title: LocalizedStringResource = "Log a glass of water"
    static var description = IntentDescription("Log one glass (250 ml) of water in Health.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let id = await Sync.shared.logWater(ml: 250) else {
            return .result(dialog: "Could not save. Open HealthBridge and tap Allow Health access.")
        }
        await DailyLog.shared.add("water", "250 ml", healthID: id)
        return .result(dialog: "+250 ml")
    }
}

/// "Quick log" — Siri or a shortcut asks what to log; the answer goes through the same rules as the Today screen.
struct QuickLogIntent: AppIntent {
    static var title: LocalizedStringResource = "Quick log"
    static var description = IntentDescription("Log water, a meal, a check-in or a note in your own words.")
    static var openAppWhenRun = false

    @Parameter(title: "What to log", requestValueDialog: "Go ahead, I'll write it all down.")
    var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let r = await DailyLog.shared.quick(text)
        return .result(dialog: "\(r)")
    }
}

struct HealthBridgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SyncHealthIntent(), phrases: ["Sync \(.applicationName)"],
                    shortTitle: "Sync health data", systemImageName: "heart.text.square")
        AppShortcut(intent: LogWaterIntent(), phrases: ["Log water in \(.applicationName)", "\(.applicationName) water"],
                    shortTitle: "Log water", systemImageName: "drop.fill")
        AppShortcut(intent: QuickLogIntent(), phrases: ["Quick log in \(.applicationName)", "\(.applicationName) log", "\(.applicationName) 记一下"],
                    shortTitle: "Quick log", systemImageName: "mic.fill")
    }
}
