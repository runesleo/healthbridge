import SwiftUI
import HealthKit

/// One tap on the Today screen: a glass of water, a meal, a mood or a check-in.
/// Water and mood also go to Apple Health; meals and check-ins live here and ride along with each day's sync.
struct LogEntry: Codable, Identifiable {
    var id = UUID()
    let kind: String      // "water" | "meal" | "mood" | "checkin"
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

    /// Meals and check-ins of a day for the sync payload (water and mood are read back from Health instead).
    nonisolated static func payload(for day: Date) -> [String: [[String: String]]] {
        guard let d = UserDefaults.standard.data(forKey: "dailyLog"), let xs = try? JSONDecoder().decode([LogEntry].self, from: d) else { return [:] }
        let cal = Calendar.current
        let iso = ISO8601DateFormatter(); iso.timeZone = .current
        var out: [String: [[String: String]]] = [:]
        for e in xs.filter({ cal.isDate($0.time, inSameDayAs: day) }).sorted(by: { $0.time < $1.time }) {
            guard e.kind == "meal" || e.kind == "checkin" else { continue }
            out[e.kind == "meal" ? "meals" : "checkins", default: []].append(["time": iso.string(from: e.time), "label": e.label])
        }
        return out
    }
}

struct TodayView: View {
    @ObservedObject private var log = DailyLog.shared
    @State private var showCamera = false
    @State private var note = ""

    static let cupML = 250.0
    static let moods: [(String, String, Double)] = [("😣", L("Awful", "很差"), -0.9), ("🙁", L("Low", "不太好"), -0.45),
                                                    ("😐", L("Okay", "一般"), 0), ("🙂", L("Good", "不错"), 0.45), ("😄", L("Great", "很好"), 0.9)]
    static let checkins = [L("Woke up", "起床"), L("Took meds", "吃药"), L("Went outside", "出门晒太阳"), L("Exercised", "运动"), L("Going to bed", "准备睡")]

    var mealNow: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<10: return L("Breakfast", "早饭")
        case 10..<15: return L("Lunch", "午饭")
        case 16..<21: return L("Dinner", "晚饭")
        default: return L("Snack", "加餐")
        }
    }

    var body: some View {
        let today = log.today()
        let cups = today.filter { $0.kind == "water" }.count
        NavigationStack {
            List {
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
                    Button { log.add("meal", mealNow) } label: { Label(L("Ate: \(mealNow)", "吃了\(mealNow)"), systemImage: "fork.knife") }
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
                            Text(e.label)
                        }
                    }
                    .onDelete { idx in for i in idx { log.remove(today[i]) } }
                }
            }
            .navigationTitle(L("Today", "今天"))
            .sheet(isPresented: $showCamera) {
                CameraPicker { image in
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)  // the Mac reads meal photos from the Photos library
                    log.add("meal", mealNow + L(" (photo)", "（拍照）"))
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
