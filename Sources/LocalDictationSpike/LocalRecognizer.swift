import Foundation
import whisper

enum RecognitionError: LocalizedError {
    case modelMissing
    case modelLoadFailed
    case inferenceFailed
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .modelMissing: "Локальная модель распознавания не найдена в приложении."
        case .modelLoadFailed: "Не удалось загрузить локальную модель."
        case .inferenceFailed: "Не удалось распознать запись."
        case .emptyResult: "Речь не обнаружена."
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
        switch transcribeOnQueue([Float](repeating: 0, count: 32_000), prompt: "") {
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
                return samples.withUnsafeBufferPointer { sampleBuffer in
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
        guard !text.isEmpty else { return .failure(.emptyResult) }
        return .success(text)
    }
}
