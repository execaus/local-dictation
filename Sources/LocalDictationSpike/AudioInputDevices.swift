import CoreAudio
import Foundation

struct AudioInputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBuiltIn: Bool
}

enum AudioInputDevices {
    static func available() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                       &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids.compactMap { id in
            guard isAlive(id), hasInput(id), let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name,
                                    isBuiltIn: uint32Property(id, kAudioDevicePropertyTransportType)
                                        == kAudioDeviceTransportTypeBuiltIn)
        }
    }

    static func defaultInputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return nil }
        return stringProperty(deviceID, kAudioDevicePropertyDeviceUID)
    }

    private static func isAlive(_ id: AudioDeviceID) -> Bool {
        uint32Property(id, kAudioDevicePropertyDeviceIsAlive) != 0
    }

    private static func uint32Property(_ id: AudioDeviceID,
                                       _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let allocatedSize = size
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr,
              size <= allocatedSize else { return false }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        let headerSize = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers) ?? 8
        let maxBuffers = (Int(size) - headerSize) / MemoryLayout<AudioBuffer>.stride
        guard Int(list.pointee.mNumberBuffers) <= maxBuffers else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(_ id: AudioDeviceID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
