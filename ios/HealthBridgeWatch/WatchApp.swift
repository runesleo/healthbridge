import SwiftUI
import WatchKit
import WatchConnectivity
import AppIntents
import AVFoundation

/// Watch side: one thing only — talk. Opening the app (or tapping the watch-face mic) starts recording at once;
/// "Done" queues the audio to the iPhone, which turns it into text and logs it like a quick-log line.
@main
struct HealthBridgeWatchApp: App {
    init() { _ = PhoneLink.shared }  // start activating at launch, well before the first note is sent
    var body: some Scene { WindowGroup { WatchTodayView() } }
}

final class PhoneLink: NSObject, WCSessionDelegate {
    static let shared = PhoneLink()
    override init() {
        super.init()
        if WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
    }
    /// Queued user info survives the phone being out of reach; it is delivered when the phone app runs.
    /// false when the link to the iPhone app never came up, so nothing was queued.
    func send(_ kind: String, _ text: String) async -> Bool {
        let time = Date().timeIntervalSince1970
        guard await activated(within: 5) else { return false }
        WCSession.default.transferUserInfo(["kind": kind, "text": text, "time": time])
        remember(text)
        return true
    }
    /// Recorded audio goes the same queued way; the phone transcribes it.
    func sendAudio(_ url: URL, at time: Date) {
        remember(L("voice note", "语音") + " · " + L("phone is turning it into text", "手机转文字中"))
        Task {
            _ = await activated(within: 60)  // best effort after that; nothing else can carry it
            WCSession.default.transferFile(url, metadata: ["kind": "audio", "time": time.timeIntervalSince1970])
        }
    }
    /// Transfers started before the session has activated are dropped; a cold launch takes a moment.
    private func activated(within seconds: Int) async -> Bool {
        guard WCSession.isSupported() else { return false }
        for _ in 0..<(seconds * 10) where WCSession.default.activationState != .activated {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return WCSession.default.activationState == .activated
    }
    private func remember(_ text: String) {
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
        guard await PhoneLink.shared.send("quick", text) else {
            return .result(dialog: "Couldn't reach the iPhone app. Open HealthBridge on the watch and try again.")
        }
        return .result(dialog: "Saved: \(text)")
    }
}

struct WatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WatchQuickLogIntent(), phrases: ["Quick log in \(.applicationName)", "\(.applicationName) log"],
                    shortTitle: "Quick log", systemImageName: "mic.fill")
    }
}

@MainActor
final class Recorder: ObservableObject {
    enum State { case idle, recording, sent, denied }
    @Published var state: State = .idle
    @Published var seconds = 0
    private var rec: AVAudioRecorder?
    private var started = Date()
    private var timer: Timer?
    static let maxSeconds = 300

    func start() {
        guard state != .recording else { return }
        AVAudioApplication.requestRecordPermission { ok in
            Task { @MainActor in ok ? self.begin() : (self.state = .denied) }
        }
    }

    private func begin() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.record, mode: .default)
        try? s.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(Int(Date().timeIntervalSince1970)).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
                                       AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
        guard let r = try? AVAudioRecorder(url: url, settings: settings), r.record() else { state = .idle; return }
        rec = r; started = Date(); seconds = 0; state = .recording
        WKInterfaceDevice.current().play(.start)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                self.seconds += 1
                if self.seconds >= Recorder.maxSeconds { self.finish() }
            }
        }
    }

    func finish() {
        guard let r = rec, state == .recording else { return }
        r.stop(); timer?.invalidate(); rec = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        if seconds >= 1 {
            PhoneLink.shared.sendAudio(r.url, at: started)
            WKInterfaceDevice.current().play(.success)
            state = .sent
        } else {
            state = .idle
        }
    }

    func cancel() {
        guard let r = rec else { state = .idle; return }
        r.stop(); r.deleteRecording(); timer?.invalidate(); rec = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        state = .idle
    }
}

struct WatchTodayView: View {
    @StateObject private var r = Recorder()
    @State private var last = ""
    @State private var launched = false

    private func refresh() {
        guard let d = UserDefaults.standard.dictionary(forKey: "lastLine"), let t = d["text"] as? String,
              let ts = d["time"] as? Double else { last = ""; return }
        last = Date(timeIntervalSince1970: ts).formatted(date: .omitted, time: .shortened) + " " + t
    }

    var body: some View {
        VStack(spacing: 8) {
            switch r.state {
            case .recording:
                Text(L("Listening…", "在听，说吧")).font(.headline)
                Text(String(format: "%d:%02d", r.seconds / 60, r.seconds % 60)).font(.title2.monospacedDigit()).foregroundStyle(.red)
                Button { r.finish(); refresh() } label: {
                    Label(L("Done", "说完了"), systemImage: "checkmark").frame(maxWidth: .infinity)
                }.tint(.green)
                Button(L("Cancel", "不要了"), role: .cancel) { r.cancel() }.font(.footnote)
            case .sent:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
                Text(L("Saved", "记下了")).font(.headline)
                Button { r.start() } label: { Label(L("One more", "再说一条"), systemImage: "mic.fill") }
            case .denied:
                Text(L("Allow the microphone in Settings → Privacy → Microphone.", "请在手表「设置 → 隐私与安全性 → 麦克风」里允许 HealthBridge。"))
                    .font(.footnote).multilineTextAlignment(.center)
            case .idle:
                Button { r.start() } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "mic.fill").font(.system(size: 40))
                        Text(L("Voice note", "口述记录")).font(.headline)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.tint(.blue)
                if !last.isEmpty {
                    Text(L("Last: ", "上一条：") + last).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 4)
        .onAppear {
            refresh()
            if !launched { launched = true; r.start() }   // cold launch = start talking right away
        }
        .onOpenURL { _ in if r.state != .recording { r.start() } }   // watch-face mic
    }
}
