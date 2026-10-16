import Combine
import Foundation

struct MicrophoneOption: Identifiable, Equatable {
    let id: String
    let name: String
    let isBuiltIn: Bool
}

enum MicrophoneSelection {
    static func ranked(_ devices: [MicrophoneOption],
                       useCounts: [String: Int],
                       systemDefaultUID: String?) -> [MicrophoneOption] {
        devices.sorted { lhs, rhs in
            let lhsCount = useCounts[lhs.id, default: 0]
            let rhsCount = useCounts[rhs.id, default: 0]
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            let lhsIsDefault = lhs.id == systemDefaultUID
            let rhsIsDefault = rhs.id == systemDefaultUID
            if lhsIsDefault != rhsIsDefault { return lhsIsDefault }
            if lhs.isBuiltIn != rhs.isBuiltIn { return lhs.isBuiltIn }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

@MainActor final class MicrophoneStore: ObservableObject {
    @Published private(set) var devices: [MicrophoneOption] = []
    @Published var selectedUID: String? {
        didSet {
            if let selectedUID {
                UserDefaults.standard.set(selectedUID, forKey: "microphoneUID.v1")
            } else {
                UserDefaults.standard.removeObject(forKey: "microphoneUID.v1")
            }
        }
    }
    @Published private(set) var useCounts: [String: Int]
    private var knownDeviceIDs: Set<String>?

    init() {
        selectedUID = UserDefaults.standard.string(forKey: "microphoneUID.v1")
        if let data = UserDefaults.standard.data(forKey: "microphoneUseCounts.v1"),
           let saved = try? JSONDecoder().decode([String: Int].self, from: data) {
            useCounts = saved
        } else {
            useCounts = [:]
        }
        refresh()
    }

    func refresh() {
        let available = AudioInputDevices.available()
            .map { MicrophoneOption(id: $0.uid, name: $0.name, isBuiltIn: $0.isBuiltIn) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let ids = Set(available.map(\.id))
        let topologyChanged = knownDeviceIDs != ids
        devices = available
        knownDeviceIDs = ids
        if topologyChanged || selectedUID.map({ !ids.contains($0) }) == true {
            selectedUID = rankedDevices().first?.id
        }
    }

    func recordingCandidates() -> [String?] {
        refresh()
        let ranked = rankedDevices().map(\.id)
        var candidates: [String?] = []
        if let selectedUID, ranked.contains(selectedUID) {
            candidates.append(selectedUID)
        } else if selectedUID == nil {
            candidates.append(nil)
        }
        for uid in ranked where uid != selectedUID { candidates.append(uid) }
        if selectedUID != nil { candidates.append(nil) } // Final attempt with the current macOS default.
        return candidates
    }

    func recordUsage(of uid: String?) {
        guard let uid else { return }
        var updated = useCounts
        updated[uid, default: 0] += 1
        useCounts = updated
        if let data = try? JSONEncoder().encode(useCounts) {
            UserDefaults.standard.set(data, forKey: "microphoneUseCounts.v1")
        }
    }

    private func rankedDevices() -> [MicrophoneOption] {
        MicrophoneSelection.ranked(devices, useCounts: useCounts,
                                   systemDefaultUID: AudioInputDevices.defaultInputUID())
    }
}
