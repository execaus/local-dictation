import AppKit
import ApplicationServices

enum InsertError: LocalizedError {
    case permissionDenied
    case noFocusedElement
    case unsupportedField
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Разрешите доступ в «Универсальном доступе» для проверки вставки."
        case .noFocusedElement: "Не удалось определить активное поле ввода."
        case .unsupportedField: "Это поле не поддерживает прямую вставку через Accessibility."
        case .eventCreationFailed: "Не удалось создать событие ввода текста."
        }
    }
}

enum TextInserter {
    static func insert(_ text: String, expectedPID: pid_t? = nil) throws {
        guard AXIsProcessTrusted() else { throw InsertError.permissionDenied }
        // Accessibility can omit the focused element for web-based editors.
        // The foreground application is the destination of normal keyboard input.
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              expectedPID == nil || expectedPID == frontmostPID else {
            Diagnostics.record("insertion.frontmost-application-changed")
            throw InsertError.noFocusedElement
        }
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        var element: AXUIElement?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            element = (value as! AXUIElement)
        }
        // Some IDEs expose the focused editor only through their application AX tree.
        var focusedPID: pid_t = 0
        let matchesTarget = element.map {
            AXUIElementGetPid($0, &focusedPID) == .success && focusedPID == frontmostPID
        } ?? false
        if !matchesTarget {
            element = nil
            let app = AXUIElementCreateApplication(frontmostPID)
            value = nil
            if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                let candidate = value as! AXUIElement
                var candidatePID: pid_t = 0
                if AXUIElementGetPid(candidate, &candidatePID) == .success,
                   candidatePID == frontmostPID {
                    element = candidate
                }
            }
        }
        guard let element else {
            Diagnostics.record("insertion.ax.focus-unavailable; keyboard-fallback")
            try postText(text, to: frontmostPID)
            return
        }

        // Never send text to a secure text field.
        var roleValue: CFTypeRef?
        var subroleValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
        if (roleValue as? String) == "AXSecureTextField" ||
           (subroleValue as? String) == "AXSecureTextField" {
            throw InsertError.unsupportedField
        }

        // The editor must process an input event itself. Setting AXSelectedText can
        // change the rendered text without updating an IDE editor's document model.
        try postText(text, to: frontmostPID)
    }

    private static func postText(_ text: String, to pid: pid_t) throws {
        guard let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw InsertError.eventCreationFailed
        }
        let units = Array(text.utf16)
        units.withUnsafeBufferPointer { buffer in
            keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        keyDown.flags = []
        keyUp.flags = []
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
    }
}
