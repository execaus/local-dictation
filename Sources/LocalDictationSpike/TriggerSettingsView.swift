import AppKit
import ApplicationServices
import SwiftUI

struct TriggerSettingsView: View {
    @State private var trigger: DictationTrigger
    @State private var recordingShortcut = false
    @State private var errorText: String?
    @State private var hasAccessibility = AXIsProcessTrusted()
    let apply: (DictationTrigger) -> String?

    init(trigger: DictationTrigger, apply: @escaping (DictationTrigger) -> String?) {
        _trigger = State(initialValue: trigger)
        self.apply = apply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Управление диктовкой", systemImage: "keyboard.fill")
                    .font(.title2.bold())
                Text("Выберите, как начинать и останавливать запись в любом приложении.")
                    .foregroundStyle(.secondary)
            }

            if !hasAccessibility {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(.orange)
                    Text("Правая Option ждёт разрешения «Универсальный доступ». Пока доступно сочетание ⌃⌥Пробел.")
                        .font(.callout)
                    Spacer()
                    Button("Открыть настройки") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .padding(12)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            }

            option(isSelected: isShortcutSelected,
                   icon: "command.square.fill",
                   title: "Сочетание клавиш",
                   detail: "Нажмите повторно, чтобы остановить и вставить текст.") {
                choose(.shortcut(currentShortcut))
            } accessory: {
                HStack(spacing: 8) {
                    Text(currentShortcut.title)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    Button("Изменить…") { recordingShortcut = true }
                        .buttonStyle(.bordered)
                }
            }

            option(isSelected: trigger == .doubleRightOption,
                   icon: "option",
                   title: "Правая Option",
                   detail: "Два быстрых нажатия — запись; ещё два — распознавание. Esc — отмена. Удержание — до отпускания.") {
                choose(.doubleRightOption)
            } accessory: {
                Text("× 2  /  удержание")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if recordingShortcut {
                HStack(spacing: 10) {
                    Image(systemName: "keyboard.badge.ellipsis")
                        .foregroundStyle(.tint)
                    Text("Нажмите новое сочетание. Esc — отмена.")
                    Spacer()
                    Button("Отмена") { recordingShortcut = false }
                }
                .padding(12)
                .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                ShortcutCaptureView(isRecording: $recordingShortcut) { shortcut in
                    choose(.shortcut(shortcut))
                }
                .frame(width: 1, height: 1)
            }

            if let errorText {
                HStack {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                    if errorText.contains("Универсальному доступу") {
                        Button("Открыть настройки") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }

            Text("Настройка хранится только на этом Mac. Одиночная клавиша может мешать обычному набору текста. ⌃⌥Esc отменяет запись.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 610)
        .background(.ultraThinMaterial)
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            hasAccessibility = AXIsProcessTrusted()
        }
    }

    private var currentShortcut: DictationShortcut {
        if case .shortcut(let shortcut) = trigger { return shortcut }
        return .standard
    }

    private var isShortcutSelected: Bool {
        if case .shortcut = trigger { return true }
        return false
    }

    private func choose(_ candidate: DictationTrigger) {
        if candidate == trigger {
            errorText = nil
            recordingShortcut = false
            return
        }
        if let error = apply(candidate) {
            errorText = error
        } else {
            trigger = candidate
            errorText = nil
            recordingShortcut = false
        }
    }

    private func option<Accessory: View>(isSelected: Bool,
                                         icon: String,
                                         title: String,
                                         detail: String,
                                         action: @escaping () -> Void,
                                         @ViewBuilder accessory: () -> Accessory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 28)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            HStack { Spacer(); accessory() }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(isSelected ? Color.accentColor.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.09)))
    }
}

private struct ShortcutCaptureView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCapture: (DictationShortcut) -> Void

    func makeNSView(context: Context) -> RecorderView { RecorderView() }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onCapture = onCapture
        view.onCancel = { isRecording = false }
        if isRecording {
            DispatchQueue.main.async {
                guard let window = view.window, window.firstResponder !== view else { return }
                window.makeFirstResponder(view)
            }
        }
    }

    final class RecorderView: NSView {
        var onCapture: ((DictationShortcut) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {
                onCancel?()
            } else if let shortcut = DictationShortcut(event: event) {
                onCapture?(shortcut)
            }
        }

        override func flagsChanged(with event: NSEvent) {}
    }
}
