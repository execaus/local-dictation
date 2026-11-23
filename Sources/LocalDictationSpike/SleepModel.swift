import AppKit
import Foundation
import ServiceManagement

@MainActor final class SleepModel: ObservableObject {
    @Published private(set) var reason: HoldReason = .inactive
    @Published private(set) var error: String?
    @Published var rules: [ScheduleRule] {
        didSet { saveRules(); refresh() }
    }
    @Published var launchAtLogin: Bool {
        didSet { updateLoginItem() }
    }

    private let defaults = UserDefaults.standard
    private let assertion = SleepAssertion()
    private var hold: HoldState
    private var ticker: Timer?
    private var revertingLoginItem = false

    init(testing: Bool = false) {
        if !testing { Self.migrateLegacySettings(into: defaults) }
        if let data = defaults.data(forKey: "noSleep.rules.v1"),
           let decoded = try? JSONDecoder().decode([ScheduleRule].self, from: data) {
            rules = decoded
        } else { rules = [] }
        launchAtLogin = !testing && SMAppService.mainApp.status == .enabled
        hold = HoldState()
        hold.manual = defaults.bool(forKey: "noSleep.manual.v1")
        hold.timerEnd = defaults.object(forKey: "noSleep.timerEnd.v1") as? Date
        hold.suppressedIntervals = Set(defaults.stringArray(forKey: "noSleep.suppressed.v1") ?? [])
        if testing { return }
        refresh()
        ticker = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake),
                                                          name: NSWorkspace.screensDidWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(wake),
                                               name: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(wake),
                                               name: NSNotification.Name.NSCalendarDayChanged, object: nil)
    }

    @objc private func wake() { refresh() }

    func startManual() {
        hold.manual = true
        hold.timerEnd = nil
        refresh()
    }

    func startTimer(minutes: Int) {
        guard (1...10080).contains(minutes) else {
            error = "Введите длительность от 1 до 10 080 минут."
            return
        }
        hold.manual = false
        hold.timerEnd = Date().addingTimeInterval(TimeInterval(minutes * 60))
        refresh()
    }

    func stop() {
        hold.stop(at: Date(), rules: rules)
        refresh()
    }

    func refresh() {
        let next = hold.evaluate(at: Date(), rules: rules)
        let needed = next != .inactive
        let success = assertion.setActive(needed)
        reason = success ? next : .inactive
        error = success ? nil : "macOS не разрешила удерживать Mac и экран активными."
        defaults.set(hold.manual, forKey: "noSleep.manual.v1")
        defaults.set(hold.timerEnd, forKey: "noSleep.timerEnd.v1")
        defaults.set(Array(hold.suppressedIntervals), forKey: "noSleep.suppressed.v1")
    }

    var stateText: String {
        if let error { return "Ошибка: \(error)" }
        switch reason {
        case .inactive: return "Выключено · Mac может перейти в сон"
        case .manual: return "Включено вручную"
        case .timer(let end): return "Включено до \(end.formatted(date: .omitted, time: .shortened))"
        case .schedule(let end): return "Включено по расписанию до \(end.formatted(date: .omitted, time: .shortened))"
        }
    }

    private func saveRules() {
        if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: "noSleep.rules.v1") }
    }

    private static func migrateLegacySettings(into defaults: UserDefaults) {
        guard defaults.object(forKey: "noSleepMigrated.v1") == nil else { return }
        if let legacy = UserDefaults(suiteName: "com.execaus.PersonalNotSleep") {
            for key in ["rules.v1", "manual.v1", "timerEnd.v1", "suppressed.v1"] {
                let destination = "noSleep.\(key)"
                if defaults.object(forKey: destination) == nil,
                   let value = legacy.object(forKey: key) {
                    defaults.set(value, forKey: destination)
                }
            }
        }
        defaults.set(true, forKey: "noSleepMigrated.v1")
    }

    private func updateLoginItem() {
        if revertingLoginItem { return }
        let enabled = SMAppService.mainApp.status == .enabled
        if launchAtLogin == enabled { return }
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            revertingLoginItem = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
            revertingLoginItem = false
            self.error = "Автозапуск не изменён: \(error.localizedDescription)"
        }
    }
}
