import AppIntents

/// "Sync health data" action for the Shortcuts app, so a personal automation
/// (a time of day, or joining the home Wi-Fi) can sync without opening HealthBridge.
struct SyncHealthIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync health data"
    static var description = IntentDescription("Send the days since the last sync to your Mac.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (status, _) = await Sync.shared.run(reason: "shortcut")
        return .result(dialog: "\(status)")
    }
}

/// "Log a glass of water" — one tap from the lock screen, Action button, watch or Siri.
struct LogWaterIntent: AppIntent {
    static var title: LocalizedStringResource = "Log a glass of water"
    static var description = IntentDescription("Add one glass (250 ml) of water to Apple Health.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let id = await Sync.shared.logWater(ml: 250) else {
            return .result(dialog: "Could not save. Open HealthBridge and tap Allow Health access.")
        }
        await DailyLog.shared.add("water", "250 ml", healthID: id)
        return .result(dialog: "+250 ml")
    }
}

struct HealthBridgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SyncHealthIntent(), phrases: ["Sync \(.applicationName)"],
                    shortTitle: "Sync health data", systemImageName: "heart.text.square")
        AppShortcut(intent: LogWaterIntent(), phrases: ["Log water in \(.applicationName)", "\(.applicationName) water"],
                    shortTitle: "Log water", systemImageName: "drop.fill")
    }
}
