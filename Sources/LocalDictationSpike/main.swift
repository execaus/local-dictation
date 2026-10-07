import AppKit
import AVFoundation
import Carbon
import SwiftUI

private let hotKeySignature: OSType = 0x4C445350 // LDSP
private let hotKeyID: UInt32 = 1
private let cancelHotKeyID: UInt32 = 2

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum State { case idle, recording(pid_t), processing }
    private var statusItem: NSStatusItem!
    private var actionItem: NSMenuItem!
    private var cancelItem: NSMenuItem!
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var cancelHotKey: EventHotKeyRef?
    private var dictionaryWindow: NSWindow?
    private var state: State = .idle
    private let recorder = AudioRecorder()
    private let recognizer = LocalRecognizer()
    private let dictionaryStore = DictionaryStore()
    private let statusPanel = StatusPanel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Локальная диктовка")
        let menu = NSMenu()
        actionItem = NSMenuItem(title: "Начать диктовку · ⌃⌥Пробел", action: #selector(toggleRecording), keyEquivalent: "")
        menu.addItem(actionItem)
        cancelItem = NSMenuItem(title: "Отменить запись · ⌃⌥Esc", action: #selector(cancelRecording), keyEquivalent: "")
        cancelItem.isEnabled = false
        menu.addItem(cancelItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Словарь терминов…", action: #selector(showDictionary), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Разрешить Универсальный доступ…", action: #selector(requestAccessibility), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        statusItem.menu = menu
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
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        // Space key (49), Control + Option. Works while another application is focused.
        RegisterEventHotKey(49, UInt32(controlKey | optionKey), EventHotKeyID(signature: hotKeySignature, id: hotKeyID),
                            GetApplicationEventTarget(), 0, &hotKey)
        RegisterEventHotKey(53, UInt32(controlKey | optionKey), EventHotKeyID(signature: hotKeySignature, id: cancelHotKeyID),
                            GetApplicationEventTarget(), 0, &cancelHotKey)
    }

    @objc private func toggleRecording() {
        switch state {
        case .idle:
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
                showError(InsertError.noFocusedElement)
                return
            }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                startRecording(for: pid)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if granted { self.startRecording(for: pid) }
                        else { self.showError(RecordingError.microphoneDenied) }
                    }
                }
            default:
                showError(RecordingError.microphoneDenied)
            }
        case .recording(let pid):
            stopRecording(for: pid)
        case .processing:
            break
        }
    }

    private func startRecording(for pid: pid_t) {
        do {
            try recorder.start()
            state = .recording(pid)
            cancelItem.isEnabled = true
            statusPanel.showRecording()
            actionItem.title = "Остановить диктовку · ⌃⌥Пробел"
            statusItem.button?.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Идёт запись")
        } catch { showError(error) }
    }

    private func stopRecording(for pid: pid_t) {
        do {
            let samples = try recorder.stop()
            state = .processing
            cancelItem.isEnabled = false
            statusPanel.showProcessing()
            actionItem.title = "Распознавание…"
            statusItem.button?.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Распознавание")
            let prompt = dictionaryStore.entries.map(\.written).joined(separator: ", ")
            recognizer.transcribe(samples, prompt: prompt) { [weak self] result in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.state = .idle
                    self.cancelItem.isEnabled = false
                    self.statusPanel.hide()
                    self.actionItem.title = "Начать диктовку · ⌃⌥Пробел"
                    self.statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Локальная диктовка")
                    switch result {
                    case .success(let rawText):
                        let text = TermDictionary.apply(self.dictionaryStore.rules, to: rawText)
                        do { try TextInserter.insert(text, expectedPID: pid) }
                        catch { self.showError(error, result: text) }
                    case .failure(let error):
                        self.showError(error)
                    }
                }
            }
        } catch {
            state = .idle
            cancelItem.isEnabled = false
            statusPanel.hide()
            actionItem.title = "Начать диктовку · ⌃⌥Пробел"
            statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Локальная диктовка")
            showError(error)
        }
    }

    @objc private func cancelRecording() {
        guard case .recording = state else { return }
        recorder.cancel()
        state = .idle
        cancelItem.isEnabled = false
        actionItem.title = "Начать диктовку · ⌃⌥Пробел"
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Локальная диктовка")
        statusPanel.hide()
    }

    @objc private func handleSessionInterruption(_ notification: Notification) {
        cancelRecording()
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

    @objc private func showDictionary() {
        if dictionaryWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Словарь терминов"
            window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: DictionaryView(store: dictionaryStore))
            window.center()
            dictionaryWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        dictionaryWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        if case .recording = state { recorder.cancel() }
        statusPanel.hide()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let cancelHotKey { UnregisterEventHotKey(cancelHotKey) }
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
    print("Dictionary self-check passed")
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
