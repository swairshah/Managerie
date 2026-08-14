import Foundation
import AppKit
import Speech

/// Transcribes dictated audio to text using Apple's on-device Speech
/// recognizer. Deliberately local-only: no API keys, no network, nothing to
/// configure.
final class SpeechToText {
    
    struct TranscriptionResult {
        let success: Bool
        let text: String?
        let error: String?
    }

    /// Owns the Apple recognition task until it completes. The task callback
    /// retains this object, and `finish` breaks that cycle. This is important for
    /// longer recordings, whose final result arrives after `transcribe` returns.
    private final class AppleOnDeviceTranscription {
        private let recognizer: SFSpeechRecognizer
        private let recordingURL: URL
        private let completion: (TranscriptionResult) -> Void
        private var task: SFSpeechRecognitionTask?
        private var latestText = ""
        private var completed = false

        init(
            recognizer: SFSpeechRecognizer,
            recordingURL: URL,
            completion: @escaping (TranscriptionResult) -> Void
        ) {
            self.recognizer = recognizer
            self.recordingURL = recordingURL
            self.completion = completion
        }

        func start() {
            let request = SFSpeechURLRecognitionRequest(url: recordingURL)
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            request.taskHint = .dictation
            request.contextualStrings = ["Managerie", "Codex", "Claude", "Ghostty", "Herdr"]

            task = recognizer.recognitionTask(with: request) { [self] result, error in
                guard !completed else { return }

                if let result {
                    latestText = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        finish(error: latestText.isEmpty ? "No speech recognized" : nil)
                        return
                    }
                }

                if let error {
                    // Apple can return an error after already producing a useful
                    // partial transcript. Preserve that text instead of dropping it.
                    finish(error: latestText.isEmpty ? error.localizedDescription : nil)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self, !self.completed else { return }
                self.finish(error: self.latestText.isEmpty
                    ? "On-device transcription timed out"
                    : nil)
            }
        }

        private func finish(error: String?) {
            guard !completed else { return }
            completed = true

            task?.cancel()
            task = nil
            try? FileManager.default.removeItem(at: recordingURL)

            let text = latestText
            DispatchQueue.main.async { [completion] in
                completion(TranscriptionResult(
                    success: error == nil && !text.isEmpty,
                    text: error == nil && !text.isEmpty ? text : nil,
                    error: error
                ))
            }
        }
    }
    
    static func transcribe(audioData: Data, completion: @escaping (TranscriptionResult) -> Void) {
        transcribeWithAppleOnDevice(audioData: audioData, completion: completion)
    }

    // MARK: - Apple On-Device STT

    private static func transcribeWithAppleOnDevice(
        audioData: Data,
        completion: @escaping (TranscriptionResult) -> Void
    ) {
        let authorizationStatus = SFSpeechRecognizer.authorizationStatus()
        if authorizationStatus == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { status in
                guard status == .authorized else {
                    DispatchQueue.main.async {
                        completion(TranscriptionResult(
                            success: false,
                            text: nil,
                            error: "Speech recognition permission was not granted."
                        ))
                    }
                    return
                }
                transcribeWithAppleOnDevice(audioData: audioData, completion: completion)
            }
            return
        }

        guard authorizationStatus == .authorized else {
            completion(TranscriptionResult(
                success: false,
                text: nil,
                error: "Speech recognition permission is disabled in System Settings."
            ))
            return
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else {
            completion(TranscriptionResult(
                success: false,
                text: nil,
                error: "Apple Speech recognition is unavailable for the current language."
            ))
            return
        }

        guard recognizer.supportsOnDeviceRecognition else {
            completion(TranscriptionResult(
                success: false,
                text: nil,
                error: "On-device speech recognition is not installed for the current language."
            ))
            return
        }

        let recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("managerie-stt-\(UUID().uuidString).m4a")
        do {
            try audioData.write(to: recordingURL, options: .atomic)
        } catch {
            completion(TranscriptionResult(
                success: false,
                text: nil,
                error: "Could not prepare the recording for transcription."
            ))
            return
        }

        AppleOnDeviceTranscription(
            recognizer: recognizer,
            recordingURL: recordingURL,
            completion: completion
        ).start()
    }
}
