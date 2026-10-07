import AppKit
import Carbon
import Foundation

struct DictationShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let standard = DictationShortcut(keyCode: 49,
                                             modifiers: UInt32(controlKey | optionKey),
                                             keyLabel: "Пробел")

    var title: String {
        var parts = ""
        if modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        return parts + keyLabel
    }

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown, event.keyCode != 53 else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        let names: [UInt16: String] = [
            49: "Пробел", 36: "Return", 48: "Tab", 51: "Delete",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        let label = names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !label.isEmpty, label.count <= 12 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
    }
}

enum DictationTrigger: Codable, Equatable {
    case shortcut(DictationShortcut)
    case doubleRightControl

    static let `default`: DictationTrigger = .doubleRightControl

    var title: String {
        switch self {
        case .shortcut(let shortcut): shortcut.title
        case .doubleRightControl: "Правый Control × 2"
        }
    }
}

@MainActor final class DoubleRightControlMonitor {
    private enum State {
        case ready
        case firstTap(TimeInterval)
        case pressing(TimeInterval, Bool, Int)
        case holding
        case sticky
    }

    private var token: Any?
    private var state: State = .ready
    private var isDown = false
    private var generation = 0
    private var onHoldStart: (() -> Void)?
    private var onHoldEnd: (() -> Void)?
    private var onStickyStart: (() -> Void)?

    var isHolding: Bool {
        if case .holding = state { return true }
        return false
    }

    var isSticky: Bool {
        if case .sticky = state { return true }
        return false
    }

    func start(onHoldStart: @escaping () -> Void,
               onHoldEnd: @escaping () -> Void,
               onStickyStart: @escaping () -> Void) -> Bool {
        stop()
        self.onHoldStart = onHoldStart
        self.onHoldEnd = onHoldEnd
        self.onStickyStart = onStickyStart
        token = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        Diagnostics.record(token == nil ? "right-control.monitor.failed" : "right-control.monitor.started")
        return token != nil
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
        onHoldStart = nil
        onHoldEnd = nil
        onStickyStart = nil
        reset()
    }

    func reset() {
        isDown = false
        state = .ready
        generation += 1
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 62 { Diagnostics.record("right-control.event") }
        accept(keyCode: event.keyCode,
               isPressed: event.modifierFlags.contains(.control),
               at: event.timestamp)
    }

    func accept(keyCode: UInt16, isPressed: Bool, at now: TimeInterval) {
        guard keyCode == 62 else {
            if case .firstTap = state { state = .ready }
            if case .pressing = state { reset() }
            return
        }
        guard isPressed != isDown else { return }
        isDown = isPressed
        if isPressed {
            if case .sticky = state { return }
            let isSecond: Bool
            if case .firstTap(let releasedAt) = state {
                isSecond = now - releasedAt <= 0.42
            } else {
                isSecond = false
            }
            generation += 1
            let current = generation
            state = .pressing(now, isSecond, current)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
                guard let self, case .pressing(_, _, let pending) = self.state,
                      pending == current, self.isDown else { return }
                self.state = .holding
                Diagnostics.record("right-control.hold")
                self.onHoldStart?()
            }
        } else {
            switch state {
            case .pressing(let startedAt, let isSecond, _):
                if now - startedAt <= 0.28 {
                    if isSecond {
                        state = .sticky
                        Diagnostics.record("right-control.double-tap")
                        onStickyStart?()
                    } else {
                        state = .firstTap(now)
                    }
                } else {
                    state = .ready
                }
            case .holding:
                state = .ready
                onHoldEnd?()
            default:
                break
            }
        }
    }
}
