import Foundation
import IOKit.pwr_mgt

@MainActor final class SleepAssertion {
    private var systemID: IOPMAssertionID = 0
    private var displayID: IOPMAssertionID = 0

    var isActive: Bool { systemID != 0 && displayID != 0 }

    func setActive(_ active: Bool) -> Bool {
        if !active { release(); return true }
        if isActive { return true }
        let reason = "Local Dictation: режим без сна" as CFString
        let systemResult = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                       IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &systemID)
        guard systemResult == kIOReturnSuccess else { release(); return false }
        let displayResult = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &displayID)
        guard displayResult == kIOReturnSuccess else { release(); return false }
        return true
    }

    func release() {
        if systemID != 0 { IOPMAssertionRelease(systemID); systemID = 0 }
        if displayID != 0 { IOPMAssertionRelease(displayID); displayID = 0 }
    }

    deinit {
        if systemID != 0 { IOPMAssertionRelease(systemID) }
        if displayID != 0 { IOPMAssertionRelease(displayID) }
    }
}
