import AVFoundation
import Foundation

enum RecordingError: LocalizedError {
    case microphoneDenied
    case microphoneUnavailable
    case tooShort
    case invalidAudioFile

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Разрешите приложению доступ к микрофону в системных настройках."
        case .microphoneUnavailable: "Не удалось запустить микрофон."
        case .tooShort: "Запись слишком короткая для распознавания."
        case .invalidAudioFile: "Не удалось прочитать тестовый аудиофайл."
        }
    }
}

final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 0
    private var isRecording = false

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecordingError.microphoneUnavailable
        }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        sampleRate = format.sampleRate
        isRecording = true
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            guard count > 0, channelCount > 0 else { return }
            var mono = [Float](repeating: 0, count: count)
            for channel in 0..<channelCount {
                let data = channels[channel]
                for frame in 0..<count { mono[frame] += data[frame] }
            }
            if channelCount > 1 {
                let scale = Float(1.0 / Double(channelCount))
                for frame in 0..<count { mono[frame] *= scale }
            }
            self.lock.lock()
            if self.isRecording { self.samples.append(contentsOf: mono) }
            self.lock.unlock()
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.lock()
            isRecording = false
            samples.removeAll()
            lock.unlock()
            throw RecordingError.microphoneUnavailable
        }
    }

    func stop() throws -> [Float] {
        lock.lock()
        isRecording = false
        lock.unlock()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        let captured = samples
        let rate = sampleRate
        samples.removeAll()
        lock.unlock()
        guard rate > 0, captured.count >= Int(rate * 0.4) else { throw RecordingError.tooShort }
        return Self.resample(captured, from: rate, to: 16_000)
    }

    func cancel() {
        lock.lock()
        isRecording = false
        lock.unlock()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }

    static func resample(_ input: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        if sourceRate == targetRate { return input }
        let outputCount = Int(Double(input.count) * targetRate / sourceRate)
        let ratio = sourceRate / targetRate
        return (0..<outputCount).map { index in
            let position = Double(index) * ratio
            let lower = min(Int(position), input.count - 1)
            let upper = min(lower + 1, input.count - 1)
            let fraction = Float(position - Double(lower))
            return input[lower] * (1 - fraction) + input[upper] * fraction
        }
    }
}

enum AudioFileLoader {
    static func load16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let capacity = AVAudioFrameCount(file.length)
        guard capacity > 0, capacity < 16_000_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw RecordingError.invalidAudioFile
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { throw RecordingError.invalidAudioFile }
        let count = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<channelCount {
            for frame in 0..<count { mono[frame] += channels[channel][frame] }
        }
        if channelCount > 1 {
            let scale = Float(1.0 / Double(channelCount))
            for frame in 0..<count { mono[frame] *= scale }
        }
        return AudioRecorder.resample(mono, from: format.sampleRate, to: 16_000)
    }
}
