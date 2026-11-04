import SwiftUI
import HealthKit

/// One tap on the Today screen: a glass of water, a meal, a mood or a check-in.
/// Water and mood also go to Apple Health; meals and check-ins live here and ride along with each day's sync.
struct LogEntry: Codable, Identifiable {
    var id = UUID()
    let kind: String      // "water" | "meal" | "mood" | "checkin" | "note"
    let label: String
    let time: Date
    var healthID: UUID?   // the Health sample this entry saved, so undo removes it too
}

@MainActor
final class DailyLog: ObservableObject {
    static let shared = DailyLog()
    @Published private(set) var entries: [LogEntry] = []
    private let key = "dailyLog"

    init() {
        if let d = UserDefaults.standard.data(forKey: key), let xs = try? JSONDecoder().decode([LogEntry].self, from: d) { entries = xs }
    }

    private func save() {
        let cutoff = Date().addingTimeInterval(-90 * 86400)  // keep 90 days on the phone; the Mac keeps everything
        entries = entries.filter { $0.time > cutoff }
        if let d = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(d, forKey: key) }
    }

    func today() -> [LogEntry] { on(Date()) }

    func on(_ day: Date) -> [LogEntry] {
        let cal = Calendar.current
        return entries.filter { cal.isDate($0.time, inSameDayAs: day) }.sorted { $0.time > $1.time }
    }

    func add(_ kind: String, _ label: String, healthID: UUID? = nil) {
        entries.append(LogEntry(kind: kind, label: label, time: Date(), healthID: healthID))
        save()
        Task.detached { await Sync.shared.run(reason: "log", daysBack: 0) }
    }

    func remove(_ e: LogEntry) {
        entries.removeAll { $0.id == e.id }
        save()
        Task.detached {
            if let id = e.healthID { await Sync.shared.deleteSample(id, kind: e.kind) }
            await Sync.shared.run(reason: "log", daysBack: 0)
        }
    }

    /// Typed or dictated line, e.g. "喝了两杯水" / "刚吃了午饭 牛肉面" / "吃药了".
    /// Water, meals and check-ins it recognizes are logged as usual; the full text is always kept as a note.
    /// Returns a short summary of what was logged.
    @discardableResult
    func quick(_ raw: String) async -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        var done: [String] = []
        let t = text.lowercased()
        if (t.contains("喝") && t.contains("水")) || t.contains("water") {
            let cups = QuickParse.cups(t)
            for _ in 0..<cups {
                if let id = await Sync.shared.logWater(ml: TodayView.cupML) { append("water", "\(Int(TodayView.cupML)) ml", healthID: id) }
            }
            done.append(L("water ×\(cups)", "喝水 \(cups) 杯"))
        }
        if let meal = QuickParse.meal(t) {
            append("meal", "\(meal)：\(text)")
            done.append(meal)
        }
        for c in QuickParse.checkins(t) { append("checkin", c); done.append(c) }
        append("note", text)
        save()
        Task.detached { await Sync.shared.run(reason: "log", daysBack: 0) }
        return done.isEmpty ? L("Noted", "已记下") : L("Logged: ", "已记：") + done.joined(separator: "、")
    }

    private func append(_ kind: String, _ label: String, healthID: UUID? = nil) {
        entries.append(LogEntry(kind: kind, label: label, time: Date(), healthID: healthID))
    }

    /// Meals and check-ins of a day for the sync payload (water and mood are read back from Health instead).
    nonisolated static func payload(for day: Date) -> [String: [[String: String]]] {
        guard let d = UserDefaults.standard.data(forKey: "dailyLog"), let xs = try? JSONDecoder().decode([LogEntry].self, from: d) else { return [:] }
        let cal = Calendar.current
        let iso = ISO8601DateFormatter(); iso.timeZone = .current
        var out: [String: [[String: String]]] = [:]
        for e in xs.filter({ cal.isDate($0.time, inSameDayAs: day) }).sorted(by: { $0.time < $1.time }) {
            let key = ["meal": "meals", "checkin": "checkins", "note": "notes"][e.kind]
            guard let key else { continue }
            out[key, default: []].append(["time": iso.string(from: e.time), "label": e.label])
        }
        return out
    }
}

/// Keyword rules for the quick-log line. Simple on purpose: the raw text always reaches the Mac as a note.
enum QuickParse {
    static let numbers: [Character: Int] = ["一": 1, "两": 2, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6]

    static func cups(_ t: String) -> Int {
        if let r = t.range(of: #"(\d+)\s*(ml|毫升)"#, options: .regularExpression),
           let n = Int(t[r].filter(\.isNumber)) { return max(1, Int((Double(n) / TodayView.cupML).rounded())) }
        if let r = t.range(of: #"(\d+|[一两二三四五六])\s*(杯|瓶|glass|cup)"#, options: .regularExpression) {
            let s = t[r]
            if let n = Int(s.filter(\.isNumber)) { return min(max(n, 1), 8) }
            if let c = s.first, let n = numbers[c] { return t.contains("瓶") ? n * 2 : n }
        }
        return t.contains("瓶") ? 2 : 1
    }

    static func meal(_ raw: String) -> String? {
        var t = raw
        for w in ["吃了药", "吃的药", "吃药"] { t = t.replacingOccurrences(of: w, with: "") }  // taking meds is not a meal
        if t.contains("早饭") || t.contains("早餐") || t.contains("breakfast") { return L("Breakfast", "早饭") }
        if t.contains("午饭") || t.contains("午餐") || t.contains("中饭") || t.contains("lunch") { return L("Lunch", "午饭") }
        if t.contains("晚饭") || t.contains("晚餐") || t.contains("dinner") { return L("Dinner", "晚饭") }
        if t.contains("夜宵") || t.contains("宵夜") || t.contains("加餐") || t.contains("零食") || t.contains("snack") { return L("Snack", "加餐") }
        if t.contains("吃了") || t.contains("吃饭") || t.contains("吃的") || t.contains("ate ") { return TodayView.mealNow }
        return nil
    }

    static func checkins(_ t: String) -> [String] {
        let rules: [([String], String)] = [
            (["起床", "醒了", "起来了", "woke"], L("Woke up", "起床")),
            (["吃药", "吃了药", "meds"], L("Took meds", "吃药")),
            (["出门", "晒太阳", "散步", "outside"], L("Went outside", "出门晒太阳")),
            (["运动", "健身", "跑步", "踢球", "打球", "exercise"], L("Exercised", "运动")),
            (["睡了", "睡觉", "准备睡", "躺下", "bed"], L("Going to bed", "准备睡")),
        ]
        return rules.filter { ws, _ in ws.contains { t.contains($0) } }.map(\.1)
    }
}

struct TodayView: View {
    @ObservedObject private var log = DailyLog.shared
    @State private var showCamera = false
    @State private var note = ""
    @State private var quickResult = ""
    @FocusState private var typing: Bool

    static let cupML = 250.0
    static let moods: [(String, String, Double)] = [("😣", L("Awful", "很差"), -0.9), ("🙁", L("Low", "不太好"), -0.45),
                                                    ("😐", L("Okay", "一般"), 0), ("🙂", L("Good", "不错"), 0.45), ("😄", L("Great", "很好"), 0.9)]
    static let checkins = [L("Woke up", "起床"), L("Took meds", "吃药"), L("Went outside", "出门晒太阳"), L("Exercised", "运动"), L("Going to bed", "准备睡")]

    static var mealNow: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<10: return L("Breakfast", "早饭")
        case 10..<15: return L("Lunch", "午饭")
        case 16..<21: return L("Dinner", "晚饭")
        default: return L("Snack", "加餐")
        }
    }

    private func submitNote() {
        let text = note
        note = ""; typing = false
        Task { quickResult = await log.quick(text) }
    }

    var body: some View {
        let today = log.today()
        let cups = today.filter { $0.kind == "water" }.count
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField(L("Say or type, e.g. “had lunch, noodles”", "说一句或打一句，比如“吃了午饭 牛肉面”"), text: $note, axis: .vertical)
                            .focused($typing).submitLabel(.done)
                            .onSubmit(submitNote)
                        Button(L("Log", "记"), action: submitNote).buttonStyle(.borderedProminent).disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: { Text(L("Quick log", "随手记")) } footer: {
                    Text(quickResult.isEmpty ? L("Tap the mic on the keyboard to speak. Water, meals and check-ins are picked up automatically.",
                                                 "点键盘上的麦克风就能说话输入。喝水、吃饭、打卡会自动认出来，原话也会存下。") : quickResult)
                }
                Section(L("Water", "喝水")) {
                    Button {
                        Task {
                            let id = await Sync.shared.logWater(ml: Self.cupML)
                            log.add("water", "\(Int(Self.cupML)) ml", healthID: id)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "drop.fill").foregroundStyle(.blue)
                            Text(L("I drank a glass", "喝了一杯"))
                            Spacer()
                            Text(L("\(cups) today · \(cups * Int(Self.cupML)) ml", "今天 \(cups) 杯 · \(cups * Int(Self.cupML)) ml")).foregroundStyle(.secondary)
                        }
                    }
                }
                Section(L("Meal", "吃饭")) {
                    Button { log.add("meal", Self.mealNow) } label: { Label(L("Ate: \(Self.mealNow)", "吃了\(Self.mealNow)"), systemImage: "fork.knife") }
                    Button { showCamera = true } label: { Label(L("Take a photo of it", "拍一张再记"), systemImage: "camera") }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                }
                Section(L("Mood right now", "现在心情")) {
                    HStack {
                        ForEach(Self.moods, id: \.0) { m in
                            Button {
                                Task {
                                    let id = await Sync.shared.logMood(valence: m.2)
                                    log.add("mood", "\(m.0) \(m.1)", healthID: id)
                                }
                            } label: { Text(m.0).font(.largeTitle) }
                            .buttonStyle(.borderless).frame(maxWidth: .infinity)
                        }
                    }
                }
                Section(L("Check in", "打卡")) {
                    ForEach(Self.checkins, id: \.self) { c in
                        Button { log.add("checkin", c) } label: {
                            HStack { Text(c); Spacer()
                                if let t = today.first(where: { $0.kind == "checkin" && $0.label == c })?.time {
                                    Text(t.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section(L("Today (swipe to undo)", "今天的记录（左滑撤销）")) {
                    if today.isEmpty { Text(L("Nothing yet", "还没有")).foregroundStyle(.secondary) }
                    ForEach(today) { e in
                        HStack {
                            Text(e.time.formatted(date: .omitted, time: .shortened)).monospacedDigit().foregroundStyle(.secondary)
                            Text(e.kind == "note" ? "📝 " + e.label : e.label)
                        }
                    }
                    .onDelete { idx in for i in idx { log.remove(today[i]) } }
                }
            }
            .navigationTitle(L("Today", "今天"))
            .sheet(isPresented: $showCamera) {
                CameraPicker { image in
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)  // the Mac reads meal photos from the Photos library
                    log.add("meal", Self.mealNow + L(" (photo)", "（拍照）"))
                }.ignoresSafeArea()
            }
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onPhoto: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onPhoto(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
