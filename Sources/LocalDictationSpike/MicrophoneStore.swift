import Combine
import Foundation

struct MicrophoneOption: Identifiable, Equatable {
    let id: String
    let name: String
}

@MainActor final class MicrophoneStore: ObservableObject {
    @Published var devices: [MicrophoneOption] = []
    @Published var selectedUID: String? {
        didSet {
            if let selectedUID {
                UserDefaults.standard.set(selectedUID, forKey: "microphoneUID.v1")
            } else {
                UserDefaults.standard.removeObject(forKey: "microphoneUID.v1")
            }
        }
    }

    init() {
        selectedUID = UserDefaults.standard.string(forKey: "microphoneUID.v1")
        refresh()
    }

    func refresh() {
        devices = AudioInputDevices.available()
            .map { MicrophoneOption(id: $0.uid, name: $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var selectedDeviceMissing: Bool {
        guard let selectedUID else { return false }
        return !devices.contains { $0.id == selectedUID }
    }
}
