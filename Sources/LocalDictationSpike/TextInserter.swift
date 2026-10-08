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
        let system = AXUIElementCreateSystemWide()
        var focusedApplicationValue: CFTypeRef?
        var focusedApplicationPID: pid_t = 0
        if AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString,
                                         &focusedApplicationValue) == .success,
           let focusedApplicationValue,
           CFGetTypeID(focusedApplicationValue) == AXUIElementGetTypeID() {
            _ = AXUIElementGetPid(focusedApplicationValue as! AXUIElement, &focusedApplicationPID)
        }
        if let expectedPID, focusedApplicationPID > 0, focusedApplicationPID != expectedPID {
            Diagnostics.record("insertion.ax.other-application-focused")
            throw InsertError.noFocusedElement
        }
        var value: CFTypeRef?
        var element: AXUIElement?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            element = (value as! AXUIElement)
        }
        // Some IDEs expose the focused editor only through their application AX tree.
        var focusedPID: pid_t = 0
        let matchesTarget = element.map { AXUIElementGetPid($0, &focusedPID) == .success &&
            (focusedPID == expectedPID || focusedApplicationPID == expectedPID) } ?? false
        if !matchesTarget, let expectedPID {
            let app = AXUIElementCreateApplication(expectedPID)
            value = nil
            if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                element = (value as! AXUIElement)
            }
        }
        guard let element else {
            Diagnostics.record("insertion.ax.no-focused-element")
            throw InsertError.noFocusedElement
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

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else {
            throw InsertError.noFocusedElement
        }
        if let expectedPID, pid != expectedPID && focusedApplicationPID != expectedPID {
            Diagnostics.record("insertion.ax.element-owner-mismatch")
            throw InsertError.noFocusedElement
        }

        // The editor must process an input event itself. Setting AXSelectedText can
        // change the rendered text without updating an IDE editor's document model.
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
        let recipientPID = expectedPID ?? pid
        keyDown.postToPid(recipientPID)
        keyUp.postToPid(recipientPID)
    }
}
