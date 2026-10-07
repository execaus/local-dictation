import AppKit
import AVFoundation
import Carbon
import SwiftUI

private let hotKeySignature: OSType = 0x4C445350 // LDSP
private let hotKeyID: UInt32 = 1
private let cancelHotKeyID: UInt32 = 2

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum RecordingMode { case toggle, hold, sticky }
    private enum State { case idle, recording(pid_t, RecordingMode), processing }
    private var statusItem: NSStatusItem!
    private var actionItem: NSMenuItem!
    private var cancelItem: NSMenuItem!
    private var retryInsertItem: NSMenuItem!
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var cancelHotKey: EventHotKeyRef?
    private var escapeStopHotKey: EventHotKeyRef?
    private var escapeStopMonitor: Any?
    private var accessibilityRetryTimer: Timer?
    private var pendingRightControl = false
    private var settingsWindow: NSWindow?
    private var lastExternalPID: pid_t?
    private var pendingText: String?
    private var state: State = .idle
    private var trigger: DictationTrigger = {
        guard let data = UserDefaults.standard.data(forKey: "dictationTrigger.v1"),
              let saved = try? JSONDecoder().decode(DictationTrigger.self, from: data) else { return .default }
        return saved
    }()
    private let recorder = AudioRecorder()
    private let recognizer = LocalRecognizer()
    private let dictionaryStore = DictionaryStore()
    private let microphoneStore = MicrophoneStore()
    private let statusPanel = StatusPanel()
    private let rightControlMonitor = DoubleRightControlMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.record("launch")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Локальная диктовка")
        let menu = NSMenu()
        actionItem = NSMenuItem(title: "Начать диктовку · \(trigger.title)", action: #selector(toggleRecording), keyEquivalent: "")
        menu.addItem(actionItem)
        cancelItem = NSMenuItem(title: "Отменить запись · ⌃⌥Esc", action: #selector(cancelRecording), keyEquivalent: "")
        cancelItem.isEnabled = false
        menu.addItem(cancelItem)
        retryInsertItem = NSMenuItem(title: "Вставить готовый текст в выбранное поле", action: #selector(retryInsertion), keyEquivalent: "")
        retryInsertItem.isEnabled = false
        menu.addItem(retryInsertItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Настройки…", action: #selector(showSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Разрешить Универсальный доступ…", action: #selector(requestAccessibility), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Открыть журнал диагностики…", action: #selector(openDiagnostics), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let currentPID, currentPID != ProcessInfo.processInfo.processIdentifier {
            lastExternalPID = currentPID
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleApplicationActivation),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        registerHotKey()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleSessionInterruption),
                                                          name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleSessionInterruption),
                                                          name: NSWorkspace.willSleepNotification, object: nil)
    }

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return noErr }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == hotKeySignature else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                if id.id == hotKeyID { delegate.toggleRecording() }
                if id.id == cancelHotKeyID { delegate.cancelRecording() }
                if id.id == 3 { delegate.stopStickyRecording() }
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        RegisterEventHotKey(53, UInt32(controlKey | optionKey), EventHotKeyID(signature: hotKeySignature, id: cancelHotKeyID),
                            GetApplicationEventTarget(), 0, &cancelHotKey)
        if let error = installTrigger(trigger, persist: false) {
            let retryRightControl = trigger == .doubleRightControl && !AXIsProcessTrusted()
            trigger = .shortcut(.standard)
            if let fallbackError = installTrigger(trigger, persist: false) {
                showError(NSError(domain: "LocalDictation", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: fallbackError]))
            } else if !retryRightControl {
                showError(NSError(domain: "LocalDictation", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: error + " Включено стандартное сочетание."]))
            }
            if retryRightControl {
                pendingRightControl = true
                startAccessibilityRetry()
            }
        }
    }

    private func startAccessibilityRetry() {
        guard accessibilityRetryTimer == nil else { return }
        accessibilityRetryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.pendingRightControl else {
                    self.accessibilityRetryTimer?.invalidate()
                    self.accessibilityRetryTimer = nil
                    return
                }
                guard AXIsProcessTrusted(), case .idle = self.state else { return }
                if self.installTrigger(.doubleRightControl, persist: true) == nil {
                    self.pendingRightControl = false
                    self.accessibilityRetryTimer?.invalidate()
                    self.accessibilityRetryTimer = nil
                }
            }
        }
    }

    private func installTrigger(_ candidate: DictationTrigger, persist: Bool) -> String? {
        guard case .idle = state else {
            return "Измените способ запуска после завершения текущей диктовки."
        }
        switch candidate {
        case .shortcut(let shortcut):
            if shortcut.keyCode == 53 && shortcut.modifiers == UInt32(controlKey | optionKey) {
                return "⌃⌥Esc зарезервировано для отмены записи. Выберите другую клавишу."
            }
            var replacement: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                             EventHotKeyID(signature: hotKeySignature, id: hotKeyID),
                                             GetApplicationEventTarget(), 0, &replacement)
            guard status == noErr, let replacement else {
                return "Это сочетание занято macOS или другим приложением. Выберите другое."
            }
            if let hotKey { UnregisterEventHotKey(hotKey) }
            hotKey = replacement
            rightControlMonitor.stop()
            if persist { pendingRightControl = false }
        case .doubleRightControl:
            guard AXIsProcessTrusted() else {
                if persist {
                    pendingRightControl = true
                    startAccessibilityRetry()
                }
                return "Для двойного правого Control разрешите приложению доступ к «Универсальному доступу»."
            }
            guard rightControlMonitor.start(onHoldStart: { [weak self] in self?.beginRecording(mode: .hold) },
                                            onHoldEnd: { [weak self] in self?.stopHoldRecording() },
                                            onStickyStart: { [weak self] in self?.beginStickyRecording() }) else {
                return "Не удалось отслеживать правый Control. Проверьте разрешение «Универсальный доступ»."
            }
            if let hotKey { UnregisterEventHotKey(hotKey) }
            hotKey = nil
        }
        trigger = candidate
        if persist, let data = try? JSONEncoder().encode(candidate) {
            UserDefaults.standard.set(data, forKey: "dictationTrigger.v1")
        }
        updateActionTitle()
        return nil
    }

    private func updateActionTitle() {
        switch state {
        case .idle:
            actionItem.title = "Начать диктовку · \(trigger.title)"
        case .recording(_, .toggle):
            if case .shortcut = trigger {
                actionItem.title = "Остановить диктовку · \(trigger.title)"
            } else {
                actionItem.title = "Остановить диктовку"
            }
        case .recording(_, .hold):
            actionItem.title = "Отпустите правый Control для остановки"
        case .recording(_, .sticky):
            actionItem.title = "Остановить диктовку · Esc"
        case .processing:
            actionItem.title = "Распознавание…"
        }
    }

    private func beginStickyRecording() {
        guard case .idle = state else {
            rightControlMonitor.reset()
            return
        }
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(53, 0, EventHotKeyID(signature: hotKeySignature, id: 3),
                                         GetApplicationEventTarget(), 0, &replacement)
        if status == noErr, let replacement {
            escapeStopHotKey = replacement
        } else {
            escapeStopMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return }
                MainActor.assumeIsolated { self?.stopStickyRecording() }
            }
        }
        guard escapeStopHotKey != nil || escapeStopMonitor != nil else {
            rightControlMonitor.reset()
            showError(NSError(domain: "LocalDictation", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Не удалось отслеживать Esc для остановки записи. Проверьте «Универсальный доступ»."
            ]))
            return
        }
        beginRecording(mode: .sticky)
    }

    private func stopStickyRecording() {
        guard case .recording(let pid, .sticky) = state else {
            clearEscapeStopHotKey()
            rightControlMonitor.reset()
            return
        }
        rightControlMonitor.reset()
        stopRecording(for: pid)
    }

    private func stopHoldRecording() {
        guard case .recording(let pid, .hold) = state else { return }
        stopRecording(for: pid)
    }

    private func clearEscapeStopHotKey() {
        if let escapeStopHotKey { UnregisterEventHotKey(escapeStopHotKey) }
        escapeStopHotKey = nil
        if let escapeStopMonitor { NSEvent.removeMonitor(escapeStopMonitor) }
        escapeStopMonitor = nil
    }

    @objc private func toggleRecording() {
        switch state {
        case .idle:
            beginRecording(mode: .toggle)
        case .recording(let pid, _):
            rightControlMonitor.reset()
            stopRecording(for: pid)
        case .processing:
            break
        }
    }

    private func beginRecording(mode: RecordingMode) {
        guard case .idle = state else { return }
        let pid = targetApplicationPID() ?? 0
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startRecording(for: pid, mode: mode)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.startRecording(for: pid, mode: mode)
                    } else {
                        self.clearEscapeStopHotKey()
                        self.rightControlMonitor.reset()
                        self.showError(RecordingError.microphoneDenied)
                    }
                }
            }
        default:
            clearEscapeStopHotKey()
            rightControlMonitor.reset()
            showError(RecordingError.microphoneDenied)
        }
    }

    private func targetApplicationPID() -> pid_t? {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           pid != ProcessInfo.processInfo.processIdentifier {
            lastExternalPID = pid
            return pid
        }
        return lastExternalPID
    }

    @objc private func handleApplicationActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalPID = app.processIdentifier
    }

    private func startRecording(for pid: pid_t, mode: RecordingMode) {
        guard case .idle = state else { return }
        if mode == .hold && !rightControlMonitor.isHolding { return }
        if mode == .sticky && !rightControlMonitor.isSticky { return }
        do {
            Diagnostics.record("recording.start")
            try recorder.start(microphoneUID: microphoneStore.selectedUID)
            state = .recording(pid, mode)
            cancelItem.isEnabled = true
            statusPanel.showRecording()
            updateActionTitle()
            statusItem.button?.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Идёт запись")
        } catch {
            Diagnostics.record("recording.start.error: \(type(of: error))")
            clearEscapeStopHotKey()
            rightControlMonitor.reset()
            showError(error)
        }
    }

    private func stopRecording(for pid: pid_t) {
        do {
            Diagnostics.record("recording.stop")
            let samples = try recorder.stop()
            state = .processing
            clearEscapeStopHotKey()
            cancelItem.isEnabled = false
            statusPanel.showProcessing()
            updateActionTitle()
            statusItem.button?.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Распознавание")
            recognizer.transcribe(samples) { [weak self] result in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.state = .idle
                    self.cancelItem.isEnabled = false
                    self.statusPanel.hide()
                    self.updateActionTitle()
                    self.statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Локальная диктовка")
                    switch result {
                    case .success(let rawText):
                        Diagnostics.record("recognition.success")
                        let text = TermDictionary.apply(self.dictionaryStore.rules, to: rawText)
                        self.insertRecognizedText(text, into: pid)
                    case .failure(let error):
                        Diagnostics.record("recognition.error: \(type(of: error))")
                        self.showError(error)
                    }
                }
            }
        } catch {
            Diagnostics.record("recording.stop.error: \(type(of: error))")
            state = .idle
            clearEscapeStopHotKey()
            cancelItem.isEnabled = false
            statusPanel.hide()
            updateActionTitle()
            statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Локальная диктовка")
            showError(error)
        }
    }

    private func insertRecognizedText(_ text: String, into pid: pid_t) {
        pendingText = text
        retryInsertItem.isEnabled = true
        // The field selected after recognition takes precedence over the app
        // that was frontmost when recording began.
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let frontmostPID, frontmostPID != ProcessInfo.processInfo.processIdentifier {
            performInsertion(text, into: frontmostPID)
        } else if let target = NSRunningApplication(processIdentifier: pid) {
            target.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.performInsertion(text, into: pid)
            }
        } else {
            Diagnostics.record("insertion.no-target")
            showError(InsertError.noFocusedElement, result: text)
        }
    }

    private func performInsertion(_ text: String, into pid: pid_t) {
        do {
            Diagnostics.record("insertion.attempt")
            try TextInserter.insert(text, expectedPID: pid)
            pendingText = nil
            retryInsertItem.isEnabled = false
            Diagnostics.record("insertion.success")
        } catch {
            Diagnostics.record("insertion.error: \(error.localizedDescription)")
            showError(error, result: text)
        }
    }

    @objc private func retryInsertion() {
        guard let text = pendingText else { return }
        guard let pid = targetApplicationPID() else {
            showError(InsertError.noFocusedElement, result: text)
            return
        }
        Diagnostics.record("insertion.retry")
        insertRecognizedText(text, into: pid)
    }

    @objc private func cancelRecording() {
        guard case .recording = state else { return }
        recorder.cancel()
        state = .idle
        clearEscapeStopHotKey()
        rightControlMonitor.reset()
        cancelItem.isEnabled = false
        updateActionTitle()
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Локальная диктовка")
        statusPanel.hide()
    }

    @objc private func handleSessionInterruption(_ notification: Notification) {
        cancelRecording()
        clearEscapeStopHotKey()
        rightControlMonitor.reset()
    }

    private func showError(_ error: Error, result: String? = nil) {
        let alert = NSAlert()
        alert.messageText = result == nil ? "Диктовка не выполнена" : "Текст готов, но вставка не выполнена"
        alert.informativeText = error.localizedDescription + (result.map { "\n\n\($0)" } ?? "")
        if let insertError = error as? InsertError, case .permissionDenied = insertError {
            alert.addButton(withTitle: "Открыть настройки")
            alert.addButton(withTitle: "Отмена")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        } else if case RecordingError.microphoneDenied = error {
            alert.addButton(withTitle: "Открыть настройки")
            alert.addButton(withTitle: "Отмена")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        } else if let result {
            alert.informativeText += "\n\nТекст сохранён. Выберите поле ввода и нажмите «Вставить готовый текст» в меню приложения."
            alert.addButton(withTitle: "Копировать текст")
            alert.addButton(withTitle: "Закрыть")
            if alert.runModal() == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
            }
        } else {
            alert.runModal()
        }
    }

    @objc private func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func openDiagnostics() { Diagnostics.open() }

    @objc private func showSettings() {
        Diagnostics.record("settings.open.begin")
        if settingsWindow == nil {
            Diagnostics.record("settings.window.create")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 490),
                                  styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Настройки"
            window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: SettingsView(microphoneStore: microphoneStore,
                                                                      dictionaryStore: dictionaryStore,
                                                                      trigger: trigger,
                                                                      applyTrigger: { [weak self] candidate in
                self?.installTrigger(candidate, persist: true)
            }))
            window.center()
            settingsWindow = window
        }
        Diagnostics.record("settings.microphones.refresh.begin")
        microphoneStore.refresh()
        Diagnostics.record("settings.microphones.refresh.end")
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        Diagnostics.record("settings.open.end")
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        Diagnostics.record("terminate")
        accessibilityRetryTimer?.invalidate()
        if case .recording = state { recorder.cancel() }
        statusPanel.hide()
        rightControlMonitor.stop()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let cancelHotKey { UnregisterEventHotKey(cancelHotKey) }
        clearEscapeStopHotKey()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

if CommandLine.arguments.contains("--self-check") {
    let rules = [TermRule(spoken: "постгрес", written: "PostgreSQL"),
                 TermRule(spoken: "юз эффект", written: "useEffect"),
                 TermRule(spoken: "цена", written: "$5\\x")]
    let actual = TermDictionary.apply(rules, to: "Постгрес и юз эффект; суперпостгрес; цена.")
    let expected = "PostgreSQL и useEffect; суперпостгрес; $5\\x."
    guard actual == expected else {
        fputs("Dictionary self-check failed: \(actual)\n", stderr)
        exit(1)
    }
    let gesture = DoubleRightControlMonitor()
    gesture.accept(keyCode: 62, isPressed: true, at: 1.0)
    gesture.accept(keyCode: 62, isPressed: false, at: 1.08)
    gesture.accept(keyCode: 62, isPressed: true, at: 1.20)
    gesture.accept(keyCode: 62, isPressed: false, at: 1.28)
    guard gesture.isSticky else {
        fputs("Double Control self-check failed\n", stderr)
        exit(1)
    }
    gesture.reset()
    gesture.accept(keyCode: 62, isPressed: true, at: 2.0)
    RunLoop.main.run(until: Date().addingTimeInterval(0.32))
    guard gesture.isHolding else {
        fputs("Control hold self-check failed\n", stderr)
        exit(1)
    }
    gesture.accept(keyCode: 62, isPressed: false, at: 2.40)
    guard !gesture.isHolding else {
        fputs("Control release self-check failed\n", stderr)
        exit(1)
    }
    gesture.accept(keyCode: 62, isPressed: true, at: 3.0)
    gesture.accept(keyCode: 62, isPressed: false, at: 3.08)
    gesture.accept(keyCode: 58, isPressed: true, at: 3.10)
    gesture.accept(keyCode: 62, isPressed: true, at: 3.20)
    gesture.accept(keyCode: 62, isPressed: false, at: 3.28)
    guard !gesture.isSticky else {
        fputs("Interrupted double Control self-check failed\n", stderr)
        exit(1)
    }
    let keyEvent = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                    modifierFlags: [.control, .option], timestamp: 0,
                                    windowNumber: 0, context: nil, characters: " ",
                                    charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)
    guard let keyEvent, DictationShortcut(event: keyEvent) == .standard else {
        fputs("Shortcut capture self-check failed\n", stderr)
        exit(1)
    }
    print("Dictionary and keyboard self-check passed")
    exit(0)
}

if CommandLine.arguments.contains("--model-check") {
    guard LocalRecognizer().smokeTest() else {
        fputs("Local model smoke test failed\n", stderr)
        exit(1)
    }
    print("Local model smoke test passed")
    exit(0)
}

if CommandLine.arguments.contains("--audio-check") {
    let devices = MicrophoneStore().devices
    let mapped = devices.filter { AudioRecorder.deviceID(for: $0.id) != nil }
    guard !devices.isEmpty, mapped.count == devices.count else {
        fputs("Audio input discovery failed (\(mapped.count)/\(devices.count) mapped)\n", stderr)
        exit(1)
    }
    print("Audio input discovery passed (\(devices.count) devices)")
    exit(0)
}

if CommandLine.arguments.contains("--settings-check") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let microphones = MicrophoneStore()
    let dictionary = DictionaryStore()
    for _ in 0..<30 {
        microphones.refresh()
        let view = NSHostingView(rootView: SettingsView(microphoneStore: microphones,
                                                       dictionaryStore: dictionary,
                                                       trigger: .default,
                                                       applyTrigger: { _ in nil }))
        view.frame = NSRect(x: 0, y: 0, width: 720, height: 490)
        view.layoutSubtreeIfNeeded()
    }
    print("Settings creation and microphone refresh passed")
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--transcribe-file"),
   CommandLine.arguments.indices.contains(index + 1) {
    do {
        let samples = try AudioFileLoader.load16kMono(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        let modelURL: URL? = {
            guard let modelIndex = CommandLine.arguments.firstIndex(of: "--model-path"),
                  CommandLine.arguments.indices.contains(modelIndex + 1) else { return nil }
            return URL(fileURLWithPath: CommandLine.arguments[modelIndex + 1])
        }()
        let prompt: String = {
            guard let promptIndex = CommandLine.arguments.firstIndex(of: "--prompt"),
                  CommandLine.arguments.indices.contains(promptIndex + 1) else { return "" }
            return CommandLine.arguments[promptIndex + 1]
        }()
        switch LocalRecognizer(modelURL: modelURL).transcribeSynchronously(samples, prompt: prompt) {
        case .success(let text): print(text)
        case .failure(let error): fputs("\(error.localizedDescription)\n", stderr); exit(1)
        }
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
