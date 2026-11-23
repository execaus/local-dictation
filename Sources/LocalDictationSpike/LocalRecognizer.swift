import Foundation
import whisper

enum RecognitionError: LocalizedError {
    case modelMissing
    case modelLoadFailed
    case inferenceFailed
    case emptyResult
    case noAudioSignal

    var errorDescription: String? {
        switch self {
        case .modelMissing: "Локальная модель распознавания не найдена в приложении."
        case .modelLoadFailed: "Не удалось загрузить локальную модель."
        case .inferenceFailed: "Не удалось распознать запись."
        case .emptyResult: "Речь не обнаружена."
        case .noAudioSignal: "Микрофон почти не передал звук. Проверьте выбранный вход в настройках звука macOS и попробуйте запись ещё раз."
        }
    }
}

final class LocalRecognizer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.dictation.recognition", qos: .userInitiated)
    private var context: OpaquePointer?
    private let overrideModelURL: URL?

    init(modelURL: URL? = nil) {
        overrideModelURL = modelURL
    }

    func transcribe(_ samples: [Float], prompt: String = "", completion: @escaping @Sendable (Result<String, RecognitionError>) -> Void) {
        queue.async {
            let result = self.transcribeOnQueue(samples, prompt: prompt)
            DispatchQueue.main.async { completion(result) }
        }
    }

    func smokeTest() -> Bool {
        let tone = (0..<32_000).map { index in
            Float(0.02 * sin(2 * Double.pi * 440 * Double(index) / 16_000))
        }
        switch transcribeOnQueue(tone, prompt: "") {
        case .success, .failure(.emptyResult): return true
        case .failure: return false
        }
    }

    func transcribeSynchronously(_ samples: [Float], prompt: String = "") -> Result<String, RecognitionError> {
        transcribeOnQueue(samples, prompt: prompt)
    }

    private func transcribeOnQueue(_ samples: [Float], prompt: String) -> Result<String, RecognitionError> {
        guard let modelURL = overrideModelURL ?? Bundle.main.url(forResource: "ggml-large-v3-turbo-q5_0", withExtension: "bin") else {
            return .failure(.modelMissing)
        }
        if context == nil {
            let parameters = whisper_context_default_params()
            context = modelURL.path.withCString { whisper_init_from_file_with_params($0, parameters) }
        }
        guard let context else { return .failure(.modelLoadFailed) }

        var combined = ""
        var hadSignal = false
        for range in AudioChunkPlan.ranges(sampleCount: samples.count) {
            let chunk = Array(samples[range])
            // Quiet stretches between spoken phrases are normal in a long recording.
            if !AudioChunkPlan.hasSignal(chunk) { continue }
            hadSignal = true
            var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            parameters.n_threads = Int32(min(8, ProcessInfo.processInfo.activeProcessorCount))
            parameters.translate = false
            parameters.no_context = true
            parameters.no_timestamps = true
            parameters.print_progress = false
            parameters.print_realtime = false
            parameters.print_timestamps = false
            let language = Array("ru".utf8CString)
            let promptBytes = Array(prompt.utf8CString)
            let status = language.withUnsafeBufferPointer { languageBuffer in
                parameters.language = languageBuffer.baseAddress
                return promptBytes.withUnsafeBufferPointer { promptBuffer in
                    parameters.initial_prompt = prompt.isEmpty ? nil : promptBuffer.baseAddress
                    return chunk.withUnsafeBufferPointer { sampleBuffer in
                        whisper_full(context, parameters, sampleBuffer.baseAddress, Int32(sampleBuffer.count))
                    }
                }
            }
            guard status == 0 else { return .failure(.inferenceFailed) }
            let count = whisper_full_n_segments(context)
            let text = (0..<count).compactMap { index -> String? in
                guard let pointer = whisper_full_get_segment_text(context, index) else { return nil }
                return String(cString: pointer)
            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            combined = AudioChunkPlan.join(combined, text)
        }
        guard hadSignal else { return .failure(.noAudioSignal) }
        guard !combined.isEmpty else { return .failure(.emptyResult) }
        return .success(combined)
    }
}

enum AudioChunkPlan {
    static let sampleRate = 16_000
    static let chunkSize = sampleRate * 25
    static let overlap = sampleRate

    static func hasSignal(_ samples: [Float]) -> Bool {
        for start in stride(from: 0, to: samples.count, by: sampleRate) {
            let end = min(start + sampleRate, samples.count)
            var peak: Float = 0
            var sum = 0.0
            for sample in samples[start..<end] {
                peak = max(peak, abs(sample))
                sum += Double(sample) * Double(sample)
            }
            if peak >= 0.005 && sqrt(sum / Double(end - start)) >= 0.0008 {
                return true
            }
        }
        return false
    }

    static func ranges(sampleCount: Int) -> [Range<Int>] {
        guard sampleCount > 0 else { return [] }
        var result: [Range<Int>] = []
        var start = 0
        while start < sampleCount {
            let end = min(start + chunkSize, sampleCount)
            result.append(start..<end)
            if end == sampleCount { break }
            start = end - overlap
        }
        return result
    }

    static func join(_ previous: String, _ next: String) -> String {
        guard !next.isEmpty else { return previous }
        guard !previous.isEmpty else { return next }
        let left = previous.split(whereSeparator: \.isWhitespace)
        let right = next.split(whereSeparator: \.isWhitespace)
        let limit = min(12, left.count, right.count)
        var duplicate = 0
        if limit > 0 {
            for count in 2...max(2, limit) where count <= limit {
                let a = left.suffix(count).map(normalize)
                let b = right.prefix(count).map(normalize)
                if a == b { duplicate = count }
            }
        }
        let remainder = right.dropFirst(duplicate).joined(separator: " ")
        return remainder.isEmpty ? previous : previous + " " + remainder
    }

    private static func normalize(_ word: Substring) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
